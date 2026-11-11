#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HushpinCapture HushpinCapture;

enum HushpinCaptureState {
    HUSHPIN_CAPTURE_RECORDING = 0,
    HUSHPIN_CAPTURE_MICROPHONE_UNAVAILABLE = 1,
    HUSHPIN_CAPTURE_STOPPED = 2,
    HUSHPIN_CAPTURE_FAILED = 3,
};

/// Live chunks are 16 kHz mono float WAV files named chunk-NNNNNN-{system,microphone}.wav in live_chunk_dir,
/// sharing the archive's session-relative timeline. Pass NULL live_chunk_dir to disable live chunks.
HushpinCapture *hushpin_capture_start(const char *system_path, const char *microphone_path, const char *log_path,
                                      const char *live_chunk_dir, double live_chunk_seconds,
                                      char *error_buffer, size_t error_buffer_len);
/// Finalizes archive tracks and the last partial live chunk.
int hushpin_capture_stop(HushpinCapture *capture, char *error_buffer, size_t error_buffer_len);
int hushpin_capture_state(HushpinCapture *capture);
/// 1 when a microphone buffer arrived within the last two seconds.
int hushpin_capture_microphone_available(HushpinCapture *capture);
/// Number of finalized live chunks; chunks 1..N are complete on disk.
long long hushpin_capture_live_chunks_ready(HushpinCapture *capture);
/// 1 when a live chunk could not be written; archive capture continues.
int hushpin_capture_live_failed(HushpinCapture *capture);
void hushpin_capture_deinit(HushpinCapture *capture);

#ifdef __cplusplus
}
#endif
