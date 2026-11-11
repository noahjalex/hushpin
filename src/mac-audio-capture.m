#import "mac-audio-capture.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static OSStatus HushpinDefaultInputListener(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress addresses[], void *context);

static void set_error(char *buffer, size_t length, NSString *message) {
    if (buffer == NULL || length == 0) return;
    snprintf(buffer, length, "%s", message.UTF8String ?: "unknown capture error");
}

static const double kLiveSampleRate = 16000;
static const int kWavHeaderBytes = 44;

static void put16(uint8_t *at, uint16_t value) { value = OSSwapHostToLittleInt16(value); memcpy(at, &value, 2); }
static void put32(uint8_t *at, uint32_t value) { value = OSSwapHostToLittleInt32(value); memcpy(at, &value, 4); }

// 16 kHz mono IEEE-float WAV header.
static void live_wav_header(uint8_t header[kWavHeaderBytes], uint32_t data_bytes) {
    memcpy(header, "RIFF", 4); put32(header + 4, 36 + data_bytes); memcpy(header + 8, "WAVEfmt ", 8);
    put32(header + 16, 16); put16(header + 20, 3); put16(header + 22, 1); put32(header + 24, (uint32_t)kLiveSampleRate);
    put32(header + 28, (uint32_t)kLiveSampleRate * 4); put16(header + 32, 4); put16(header + 34, 32);
    memcpy(header + 36, "data", 4); put32(header + 40, data_bytes);
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Converts any capture buffer to mono float at one sample rate, rebuilding the converter after device format changes.
@interface HushpinConverter : NSObject
@property(nonatomic) AVAudioFormat *outputFormat;
@property(nonatomic) AVAudioConverter *converter;
@property(nonatomic) BOOL formatChanged;
@end

@implementation HushpinConverter
- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    _outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sampleRate channels:1 interleaved:NO];
    return self;
}

// Returns nil and names the failed step, or a buffer that may have zero frames while the resampler fills.
- (AVAudioPCMBuffer *)convert:(CMSampleBufferRef)sample step:(NSString **)step {
    AVAudioFormat *inputFormat = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:CMSampleBufferGetFormatDescription(sample)];
    _formatChanged = NO;
    if (_converter == nil || ![_converter.inputFormat isEqual:inputFormat]) {
        _converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:_outputFormat];
        _converter.downmix = YES;
        _formatChanged = YES;
    }
    if (_converter == nil) { *step = @"converter"; return nil; }
    AVAudioFrameCount frames = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sample);
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:frames];
    if (input == nil) { *step = @"buffer"; return nil; }
    input.frameLength = frames; // sizes mutableAudioBufferList for the copy
    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, 0, frames, input.mutableAudioBufferList) != noErr) { *step = @"copy"; return nil; }
    AVAudioFrameCount capacity = (AVAudioFrameCount)(frames * _outputFormat.sampleRate / inputFormat.sampleRate) + 256;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outputFormat frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [_converter convertToBuffer:output error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *inputStatus) {
        if (supplied) { *inputStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
        supplied = YES; *inputStatus = AVAudioConverterInputStatus_HaveData; return input;
    }];
    if (status == AVAudioConverterOutputStatus_Error) { *step = error.localizedDescription ?: @"convert"; return nil; }
    return output;
}
@end

// One track's open live chunk file.
@interface HushpinLiveTrack : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) HushpinConverter *converter;
@property(nonatomic) int fd;
@property(nonatomic) int64_t chunk;
@end

@implementation HushpinLiveTrack
- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    _name = name; _converter = [[HushpinConverter alloc] initWithSampleRate:kLiveSampleRate]; _fd = -1; _chunk = -1;
    return self;
}
- (void)closeChunk { if (_fd >= 0) close(_fd); _fd = -1; _chunk = -1; }
@end

@interface HushpinCaptureSession : NSObject <SCStreamOutput, SCStreamDelegate> {
    atomic_llong _liveChunksReady;
    atomic_int _liveFailed;
    atomic_ullong _lastMicrophoneSampleNs;
}
@property(nonatomic) SCStream *stream;
@property(nonatomic) SCStreamConfiguration *configuration;
@property(nonatomic) AVAssetWriter *systemWriter;
@property(nonatomic) AVAssetWriter *microphoneWriter;
@property(nonatomic) AVAssetWriterInput *systemInput;
@property(nonatomic) AVAssetWriterInput *microphoneInput;
@property(nonatomic) dispatch_queue_t writerQueue;
@property(nonatomic) CMSampleBufferRef pendingSystem;
@property(nonatomic) CMSampleBufferRef pendingMicrophone;
@property(nonatomic) NSFileHandle *logFile;
@property(nonatomic) atomic_int state;
@property(nonatomic) NSString *failure;
@property(nonatomic) BOOL writersStarted;
@property(nonatomic) HushpinConverter *microphoneConverter;
@property(nonatomic) BOOL microphoneConversionFailing;
@property(nonatomic) CMTime origin;
@property(nonatomic, copy) NSString *liveDirectory;
@property(nonatomic) int64_t liveChunkFrames;
@property(nonatomic) int64_t liveEndFrame;
@property(nonatomic) HushpinLiveTrack *liveSystem;
@property(nonatomic) HushpinLiveTrack *liveMicrophone;
@end

@implementation HushpinCaptureSession

- (instancetype)initWithSystemPath:(NSString *)systemPath microphonePath:(NSString *)microphonePath logPath:(NSString *)logPath liveDirectory:(NSString *)liveDirectory liveChunkSeconds:(double)liveChunkSeconds error:(NSString **)error {
    self = [super init];
    if (self == nil) return nil;
    _microphoneConverter = [[HushpinConverter alloc] initWithSampleRate:48000];
    if (liveDirectory != nil) {
        _liveDirectory = liveDirectory;
        _liveChunkFrames = (int64_t)llround(liveChunkSeconds * kLiveSampleRate);
        if (_liveChunkFrames <= 0) { *error = @"live chunk duration must be positive"; return nil; }
        _liveSystem = [[HushpinLiveTrack alloc] initWithName:@"system"];
        _liveMicrophone = [[HushpinLiveTrack alloc] initWithName:@"microphone"];
    }
    atomic_init(&_liveChunksReady, 0);
    atomic_init(&_liveFailed, 0);
    atomic_init(&_lastMicrophoneSampleNs, 0);
    _writerQueue = dispatch_queue_create("com.hushpin.capture.writer", DISPATCH_QUEUE_SERIAL);
    atomic_init(&_state, HUSHPIN_CAPTURE_RECORDING);
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:@{ NSFilePosixPermissions: @0600 }];
    _logFile = [NSFileHandle fileHandleForWritingAtPath:logPath];

    NSDictionary *systemSettings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2, AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO };
    NSDictionary *microphoneSettings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO };
    NSError *writerError = nil;
    _systemWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:systemPath] fileType:AVFileTypeCoreAudioFormat error:&writerError];
    if (_systemWriter == nil) { *error = writerError.localizedDescription; return nil; }
    _microphoneWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:microphonePath] fileType:AVFileTypeCoreAudioFormat error:&writerError];
    if (_microphoneWriter == nil) { *error = writerError.localizedDescription; return nil; }
    _systemInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:systemSettings];
    _microphoneInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:microphoneSettings];
    _systemInput.expectsMediaDataInRealTime = YES;
    _microphoneInput.expectsMediaDataInRealTime = YES;
    if (![_systemWriter canAddInput:_systemInput] || ![_microphoneWriter canAddInput:_microphoneInput]) {
        *error = @"cannot configure CAF audio writers";
        return nil;
    }
    [_systemWriter addInput:_systemInput];
    [_microphoneWriter addInput:_microphoneInput];
    if (![_systemWriter startWriting] || ![_microphoneWriter startWriting]) {
        *error = _systemWriter.error.localizedDescription ?: _microphoneWriter.error.localizedDescription ?: @"cannot start CAF writers";
        return nil;
    }
    return self;
}

- (void)log:(NSString *)line {
    @synchronized (self) {
        NSData *data = [[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding];
        [_logFile writeData:data error:nil];
    }
}

- (void)markFailure:(NSError *)error {
    atomic_store(&_state, HUSHPIN_CAPTURE_FAILED);
    self.failure = error.localizedDescription ?: @"ScreenCaptureKit failed";
    [self log:[NSString stringWithFormat:@"capture failure: %@", self.failure]];
}

- (void)startWritersIfReady {
    if (_writersStarted || _pendingSystem == NULL || _pendingMicrophone == NULL) return;
    CMTime systemTime = CMSampleBufferGetPresentationTimeStamp(_pendingSystem);
    CMTime microphoneTime = CMSampleBufferGetPresentationTimeStamp(_pendingMicrophone);
    CMTime origin = CMTimeCompare(systemTime, microphoneTime) <= 0 ? systemTime : microphoneTime;
    [_systemWriter startSessionAtSourceTime:origin];
    [_microphoneWriter startSessionAtSourceTime:origin];
    _origin = origin;
    _writersStarted = YES;
    [self append:_pendingSystem input:_systemInput writer:_systemWriter];
    [self append:_pendingMicrophone input:_microphoneInput writer:_microphoneWriter];
    [self appendLive:_pendingSystem track:_liveSystem];
    [self appendLive:_pendingMicrophone track:_liveMicrophone];
    CFRelease(_pendingSystem); _pendingSystem = NULL;
    CFRelease(_pendingMicrophone); _pendingMicrophone = NULL;
}

- (void)append:(CMSampleBufferRef)sample input:(AVAssetWriterInput *)input writer:(AVAssetWriter *)writer {
    if (writer.status != AVAssetWriterStatusWriting) { [self markFailure:writer.error]; return; }
    if (input.readyForMoreMediaData && ![input appendSampleBuffer:sample]) [self markFailure:writer.error];
}

// Microphones differ in sample rate and channels (AirPods 24 kHz, built-in 48 kHz). The writer locks onto the first
// format it sees, so convert every microphone buffer to 48 kHz mono float before it reaches the writer.
// Returns a +1 sample buffer, or NULL when conversion fails or yields no frames yet.
- (CMSampleBufferRef)copyNormalizedMicrophoneSample:(CMSampleBufferRef)sample {
    NSString *step = nil;
    AVAudioPCMBuffer *output = [_microphoneConverter convert:sample step:&step];
    if (_microphoneConverter.formatChanged) {
        AVAudioFormat *inputFormat = _microphoneConverter.converter.inputFormat;
        [self log:[NSString stringWithFormat:@"microphone format %.0f Hz, %u channel(s)", inputFormat.sampleRate, inputFormat.channelCount]];
    }
    if (output == nil) return [self microphoneConversionFailed:step];
    if (output.frameLength == 0) return NULL;
    AVAudioFormat *format = _microphoneConverter.outputFormat;
    CMSampleBufferRef normalized = NULL;
    if (CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault, NULL, false, NULL, NULL, format.formatDescription, output.frameLength, CMSampleBufferGetPresentationTimeStamp(sample), NULL, &normalized) != noErr) return [self microphoneConversionFailed:@"create"];
    if (CMSampleBufferSetDataBufferFromAudioBufferList(normalized, kCFAllocatorDefault, kCFAllocatorDefault, 0, output.audioBufferList) != noErr) { CFRelease(normalized); return [self microphoneConversionFailed:@"attach"]; }
    _microphoneConversionFailing = NO;
    return normalized;
}

- (NSString *)liveChunkPath:(int64_t)chunk track:(HushpinLiveTrack *)track partial:(BOOL)partial {
    NSString *name = [NSString stringWithFormat:@"chunk-%06lld-%@.wav%@", chunk + 1, track.name, partial ? @".partial" : @""];
    return [_liveDirectory stringByAppendingPathComponent:name];
}

- (void)failLive:(NSString *)step {
    if (atomic_exchange(&_liveFailed, 1) == 0) [self log:[NSString stringWithFormat:@"live chunk %@ failed: %s; archive capture continues", step, strerror(errno)]];
    [_liveSystem closeChunk]; [_liveMicrophone closeChunk];
}

// Writes the header, pads missing audio with silence, and renames both tracks' files so chunk is complete on disk.
- (BOOL)publishLiveChunk:(int64_t)chunk frames:(int64_t)frames {
    for (HushpinLiveTrack *track in @[_liveSystem, _liveMicrophone]) {
        if (track.chunk == chunk) [track closeChunk];
        NSString *partial = [self liveChunkPath:chunk track:track partial:YES];
        int fd = open(partial.fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
        if (fd < 0) { [self failLive:@"open"]; return NO; }
        uint8_t header[kWavHeaderBytes];
        live_wav_header(header, (uint32_t)(frames * 4));
        BOOL okay = ftruncate(fd, kWavHeaderBytes + frames * 4) == 0 && pwrite(fd, header, kWavHeaderBytes, 0) == kWavHeaderBytes;
        okay = close(fd) == 0 && okay;
        if (!okay || rename(partial.fileSystemRepresentation, [self liveChunkPath:chunk track:track partial:NO].fileSystemRepresentation) != 0) { [self failLive:@"publish"]; return NO; }
    }
    atomic_store(&_liveChunksReady, chunk + 1);
    return YES;
}

// Runs on the writer queue. Places frames by presentation time, so gaps become silence and both tracks share the timeline.
- (void)appendLive:(CMSampleBufferRef)sample track:(HushpinLiveTrack *)track {
    if (_liveDirectory == nil || atomic_load(&_liveFailed)) return;
    NSString *step = nil;
    AVAudioPCMBuffer *buffer = [track.converter convert:sample step:&step];
    if (buffer == nil) { [self log:[NSString stringWithFormat:@"dropping live %@ audio: %@ failed", track.name, step]]; return; }
    int64_t count = buffer.frameLength;
    if (count == 0) return;
    const float *data = buffer.floatChannelData[0];
    int64_t position = llround(CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), _origin)) * kLiveSampleRate);
    if (position < 0) { data -= position; count += position; position = 0; }
    int64_t published = atomic_load(&_liveChunksReady);
    while (count > 0) {
        int64_t chunk = position / _liveChunkFrames;
        int64_t offset = position - chunk * _liveChunkFrames;
        int64_t frames = MIN(count, _liveChunkFrames - offset);
        if (chunk >= published) { // frames for already published chunks arrived too late; the archive still has them
            if (track.chunk != chunk) {
                [track closeChunk];
                track.fd = open([self liveChunkPath:chunk track:track partial:YES].fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
                if (track.fd < 0) { [self failLive:@"open"]; return; }
                track.chunk = chunk;
            }
            if (pwrite(track.fd, data, (size_t)frames * 4, kWavHeaderBytes + offset * 4) != frames * 4) { [self failLive:@"write"]; return; }
            _liveEndFrame = MAX(_liveEndFrame, position + frames);
        }
        data += frames; count -= frames; position += frames;
    }
    // ponytail: fixed half-second grace for the lagging track; late frames only miss live text.
    int64_t grace = (int64_t)(kLiveSampleRate / 2);
    while ((published + 1) * _liveChunkFrames + grace <= _liveEndFrame) {
        if (![self publishLiveChunk:published frames:_liveChunkFrames]) return;
        published++;
    }
}

- (void)finishLive {
    if (_liveDirectory == nil) return;
    int64_t published = atomic_load(&_liveChunksReady);
    while (!atomic_load(&_liveFailed) && published * _liveChunkFrames < _liveEndFrame) {
        if (![self publishLiveChunk:published frames:MIN(_liveChunkFrames, _liveEndFrame - published * _liveChunkFrames)]) break;
        published++;
    }
    [_liveSystem closeChunk]; [_liveMicrophone closeChunk];
}

- (CMSampleBufferRef)microphoneConversionFailed:(NSString *)step {
    if (!_microphoneConversionFailing) [self log:[NSString stringWithFormat:@"dropping microphone audio: %@ failed", step]];
    _microphoneConversionFailing = YES;
    return NULL;
}

- (void)appendSample:(CMSampleBufferRef)sample type:(SCStreamOutputType)type {
    if (atomic_load(&_state) == HUSHPIN_CAPTURE_FAILED) return;
    if (type == SCStreamOutputTypeAudio) {
        if (!_writersStarted) { if (_pendingSystem == NULL) _pendingSystem = (CMSampleBufferRef)CFRetain(sample); [self startWritersIfReady]; }
        else { [self append:sample input:_systemInput writer:_systemWriter]; [self appendLive:sample track:_liveSystem]; }
    } else if (type == SCStreamOutputTypeMicrophone) {
        atomic_store(&_state, HUSHPIN_CAPTURE_RECORDING);
        atomic_store(&_lastMicrophoneSampleNs, now_ns());
        if (_writersStarted) [self appendLive:sample track:_liveMicrophone];
        CMSampleBufferRef normalized = [self copyNormalizedMicrophoneSample:sample];
        if (normalized == NULL) return;
        if (!_writersStarted) { if (_pendingMicrophone == NULL) _pendingMicrophone = (CMSampleBufferRef)CFRetain(normalized); [self startWritersIfReady]; }
        else [self append:normalized input:_microphoneInput writer:_microphoneWriter];
        CFRelease(normalized);
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!CMSampleBufferDataIsReady(sampleBuffer)) return;
    CFRetain(sampleBuffer);
    dispatch_async(_writerQueue, ^{
        [self appendSample:sampleBuffer type:type];
        CFRelease(sampleBuffer);
    });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { [self markFailure:error]; }

static NSString *default_input_property(AudioObjectPropertySelector selector) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr || device == kAudioObjectUnknown) return nil;
    CFStringRef value = NULL;
    size = sizeof(value);
    address.mSelector = selector;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr || value == NULL) return nil;
    return (__bridge_transfer NSString *)value;
}

// ScreenCaptureKit resolves "system default microphone" once at start, so pin the current default and re-pin on change.
- (void)defaultInputDidChange {
    NSString *uid = default_input_property(kAudioDevicePropertyDeviceUID);
    NSString *name = default_input_property(kAudioObjectPropertyName) ?: @"unknown";
    if (uid == nil || _stream == nil) { [self log:@"default microphone changed; new device unavailable"]; return; }
    _configuration.microphoneCaptureDeviceID = uid;
    [_stream updateConfiguration:_configuration completionHandler:^(NSError *error) {
        if (error) [self log:[NSString stringWithFormat:@"cannot switch microphone to %@: %@", name, error.localizedDescription]];
        else [self log:[NSString stringWithFormat:@"microphone switched to %@", name]];
    }];
}

- (BOOL)start:(NSString **)error {
    dispatch_semaphore_t contentReady = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *contentError = nil;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *value, NSError *valueError) {
        content = value; contentError = valueError; dispatch_semaphore_signal(contentReady);
    }];
    if (dispatch_semaphore_wait(contentReady, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0 || content == nil || content.displays.count == 0) {
        *error = contentError.localizedDescription ?: @"screen capture permission or a display is unavailable";
        return NO;
    }
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    configuration.capturesAudio = YES;
    configuration.captureMicrophone = YES;
    configuration.sampleRate = 48000;
    configuration.channelCount = 2;
    configuration.queueDepth = 5;
    configuration.showsCursor = NO;
    configuration.microphoneCaptureDeviceID = default_input_property(kAudioDevicePropertyDeviceUID);
    _configuration = configuration;
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject excludingWindows:@[]];
    _stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
    NSError *outputError = nil;
    if (![_stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) error:&outputError] ||
        ![_stream addStreamOutput:self type:SCStreamOutputTypeMicrophone sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) error:&outputError]) {
        *error = outputError.localizedDescription ?: @"cannot add audio capture outputs";
        return NO;
    }
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSError *startError = nil;
    [_stream startCaptureWithCompletionHandler:^(NSError *valueError) { startError = valueError; dispatch_semaphore_signal(started); }];
    if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0 || startError != nil) {
        *error = startError.localizedDescription ?: @"ScreenCaptureKit did not start capture";
        return NO;
    }
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &address, HushpinDefaultInputListener, (__bridge void *)self);
    [self log:[NSString stringWithFormat:@"capture started (system audio and microphone %@)", default_input_property(kAudioObjectPropertyName) ?: @"system default"]];
    return YES;
}

- (BOOL)stop:(NSString **)error {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &address, HushpinDefaultInputListener, (__bridge void *)self);
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [_stream stopCaptureWithCompletionHandler:^(NSError *valueError) { if (valueError) self.failure = valueError.localizedDescription; dispatch_semaphore_signal(stopped); }];
    if (dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) { *error = @"ScreenCaptureKit did not stop capture"; return NO; }
    dispatch_sync(_writerQueue, ^{ [self finishLive]; });
    if (!_writersStarted) {
        atomic_store(&_state, HUSHPIN_CAPTURE_MICROPHONE_UNAVAILABLE);
        [self log:@"microphone audio was unavailable before stop"];
    }
    [_systemInput markAsFinished]; [_microphoneInput markAsFinished];
    dispatch_group_t writersFinished = dispatch_group_create();
    dispatch_group_enter(writersFinished); [_systemWriter finishWritingWithCompletionHandler:^{ dispatch_group_leave(writersFinished); }];
    dispatch_group_enter(writersFinished); [_microphoneWriter finishWritingWithCompletionHandler:^{ dispatch_group_leave(writersFinished); }];
    dispatch_group_wait(writersFinished, DISPATCH_TIME_FOREVER);
    if (_systemWriter.status == AVAssetWriterStatusFailed || _microphoneWriter.status == AVAssetWriterStatusFailed || self.failure != nil) {
        *error = self.failure ?: _systemWriter.error.localizedDescription ?: _microphoneWriter.error.localizedDescription ?: @"audio writer failed";
        return NO;
    }
    atomic_store(&_state, HUSHPIN_CAPTURE_STOPPED);
    [self log:@"capture stopped and CAF writers closed"];
    return YES;
}

- (int)captureState { return atomic_load(&_state); }
- (int)microphoneAvailable { uint64_t last = atomic_load(&_lastMicrophoneSampleNs); return last != 0 && now_ns() - last < 2 * NSEC_PER_SEC; }
- (long long)liveChunksReady { return atomic_load(&_liveChunksReady); }
- (int)liveFailed { return atomic_load(&_liveFailed); }
- (void)dealloc { if (_pendingSystem) CFRelease(_pendingSystem); if (_pendingMicrophone) CFRelease(_pendingMicrophone); [_logFile closeFile]; }
@end

static OSStatus HushpinDefaultInputListener(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress addresses[], void *context) {
    [(__bridge HushpinCaptureSession *)context defaultInputDidChange];
    return noErr;
}

struct HushpinCapture { void *session; };

HushpinCapture *hushpin_capture_start(const char *system_path, const char *microphone_path, const char *log_path, const char *live_chunk_dir, double live_chunk_seconds, char *error_buffer, size_t error_buffer_len) {
    @autoreleasepool {
        NSString *error = nil;
        NSString *liveDirectory = live_chunk_dir ? [NSString stringWithUTF8String:live_chunk_dir] : nil;
        HushpinCaptureSession *session = [[HushpinCaptureSession alloc] initWithSystemPath:[NSString stringWithUTF8String:system_path] microphonePath:[NSString stringWithUTF8String:microphone_path] logPath:[NSString stringWithUTF8String:log_path] liveDirectory:liveDirectory liveChunkSeconds:live_chunk_seconds error:&error];
        if (session == nil || ![session start:&error]) { set_error(error_buffer, error_buffer_len, error ?: @"cannot start audio capture"); return NULL; }
        HushpinCapture *capture = calloc(1, sizeof(*capture));
        capture->session = CFBridgingRetain(session);
        return capture;
    }
}

int hushpin_capture_stop(HushpinCapture *capture, char *error_buffer, size_t error_buffer_len) {
    @autoreleasepool {
        NSString *error = nil;
        BOOL okay = [(__bridge HushpinCaptureSession *)capture->session stop:&error];
        if (!okay) set_error(error_buffer, error_buffer_len, error ?: @"cannot stop audio capture");
        return okay ? 0 : -1;
    }
}

int hushpin_capture_state(HushpinCapture *capture) { return [(__bridge HushpinCaptureSession *)capture->session captureState]; }
int hushpin_capture_microphone_available(HushpinCapture *capture) { return [(__bridge HushpinCaptureSession *)capture->session microphoneAvailable]; }
long long hushpin_capture_live_chunks_ready(HushpinCapture *capture) { return [(__bridge HushpinCaptureSession *)capture->session liveChunksReady]; }
int hushpin_capture_live_failed(HushpinCapture *capture) { return [(__bridge HushpinCaptureSession *)capture->session liveFailed]; }
void hushpin_capture_deinit(HushpinCapture *capture) { if (capture) { CFBridgingRelease(capture->session); free(capture); } }
