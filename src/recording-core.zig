//! Hushpin core facade: one capture owner per data root, live chunk transcription, final transcription, and cleanup.
//! Consumers in other processes attach through `session.json`; they never open audio devices.
const std = @import("std");
pub const processing = @import("audio-processing.zig");
pub const state = @import("session-state.zig");
const c = @cImport({
    @cInclude("mac-audio-capture.h");
});

pub const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const AudioTracks = processing.AudioTracks;
pub const SessionSnapshot = state.SessionSnapshot;
pub const SessionDescriptor = state.SessionDescriptor;
pub const CaptureState = state.CaptureState;
pub const LiveState = state.LiveState;
pub const FinalState = state.FinalState;
pub const Segment = state.Segment;
pub const Subscription = state.Subscription;
pub const readConsistentLiveTranscript = state.readConsistentLiveTranscript;

pub const default_live_model_file = "ggml-tiny.en.bin";
pub const default_batch_model_file = "ggml-base.en.bin";

/// Returns `~/.local/share/whisper.cpp/<model_file>`; caller owns the path.
pub fn defaultModelPath(gpa: Allocator, home: []const u8, model_file: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "whisper.cpp", model_file });
}

pub const SessionOptions = struct {
    live: bool = false,
    live_chunk_ms: u64 = 5000,
    /// Required when `live` is set; Hushpin never downloads models.
    live_model_path: ?[]const u8 = null,
};

pub const FinalizeOptions = struct {
    model_path: []const u8,
};

pub const StartResult = union(enum) {
    /// This process now owns capture; stop with `stopSession` and release with `deinitSession`.
    started: *Session,
    /// Another process owns the data root's capture. Existing sessions are never reconfigured.
    already_active: std.json.Parsed(SessionDescriptor),
};

pub const CaptureResult = struct {
    tracks: AudioTracks,
    capture: CaptureState,
    live: LiveState,
};

/// Owns the Hushpin data root, allocator, and I/O implementation shared by operations.
pub const RecordingCore = struct {
    allocator: Allocator,
    io: Io,
    /// Absolute.
    data_dir: []u8,
};

/// Initializes an independent Hushpin data root.
pub fn initRecordingCore(allocator: Allocator, io: Io, data_dir: []const u8) !RecordingCore {
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, data_dir, allocator);
    defer allocator.free(absolute);
    return .{ .allocator = allocator, .io = io, .data_dir = try allocator.dupe(u8, absolute) };
}

pub fn deinitRecordingCore(core: *RecordingCore) void {
    core.allocator.free(core.data_dir);
    core.* = undefined;
}

/// Starts one native capture with optional live chunks, or reports the data root's active session.
pub fn startSession(core: *RecordingCore, options: SessionOptions) !StartResult {
    const gpa = core.allocator;
    const io = core.io;
    if (options.live) {
        const model = options.live_model_path orelse return error.LiveModelRequired;
        if (!processing.isNonemptyFile(io, model)) return error.ModelNotFound;
        if (options.live_chunk_ms == 0) return error.InvalidChunkDuration;
    }

    const root_lock_path = try std.fs.path.join(gpa, &.{ core.data_dir, "capture.lock" });
    defer gpa.free(root_lock_path);
    const active_path = try std.fs.path.join(gpa, &.{ core.data_dir, "active-session.json" });
    defer gpa.free(active_path);
    var root_lock = try std.Io.Dir.cwd().createFile(io, root_lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    if (!try root_lock.tryLock(io, .exclusive)) {
        root_lock.close(io);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, active_path, gpa, .limited(64 * 1024)) catch return error.CaptureActive;
        defer gpa.free(bytes);
        return .{ .already_active = try std.json.parseFromSlice(SessionDescriptor, gpa, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) };
    }
    errdefer {
        processing.deleteIfPresent(io, active_path);
        root_lock.unlock(io);
        root_lock.close(io);
    }

    const session = try gpa.create(Session);
    errdefer gpa.destroy(session);
    session.* = .{ .core = core, .directory = try createSessionDirectory(core) };
    errdefer gpa.free(session.directory);
    session.owner_lock = try state.acquireOwnerLock(gpa, io, session.directory, false);
    errdefer session.owner_lock.release(io);
    const marker = try std.fs.path.join(gpa, &.{ session.directory, ".hushpin-owned" });
    defer gpa.free(marker);
    try processing.writeFileAtomically(gpa, io, marker, "hushpin recording\n", false);
    const audio_dir = try std.fs.path.join(gpa, &.{ session.directory, "audio" });
    defer gpa.free(audio_dir);
    try std.Io.Dir.cwd().createDir(io, audio_dir, .fromMode(0o700));
    session.system_path = try std.fs.path.join(gpa, &.{ audio_dir, "system.caf" });
    errdefer gpa.free(session.system_path);
    session.microphone_path = try std.fs.path.join(gpa, &.{ audio_dir, "microphone.caf" });
    errdefer gpa.free(session.microphone_path);
    const log_path = try std.fs.path.join(gpa, &.{ session.directory, "recording.log" });
    defer gpa.free(log_path);
    var live_dir: ?[:0]u8 = null;
    defer if (live_dir) |path| gpa.free(path);
    if (options.live) {
        live_dir = try std.fs.path.joinZ(gpa, &.{ audio_dir, "live" });
        try std.Io.Dir.cwd().createDir(io, live_dir.?, .fromMode(0o700));
        session.live = try LiveProcessor.init(gpa, io, session.directory, live_dir.?, options.live_chunk_ms, options.live_model_path.?);
    }
    errdefer if (session.live) |*live| live.deinit();

    const descriptor: SessionDescriptor = .{ .session_id = session.sessionId(), .directory = session.directory, .owner_pid = std.c.getpid() };
    const descriptor_json = try std.json.Stringify.valueAlloc(gpa, descriptor, .{});
    defer gpa.free(descriptor_json);
    try processing.writeFileAtomically(gpa, io, active_path, descriptor_json, true);
    {
        var edit = try state.beginEdit(gpa, io, session.directory);
        defer edit.deinit();
        const snapshot = edit.snapshot();
        snapshot.owner_pid = descriptor.owner_pid;
        snapshot.capture = .starting;
        snapshot.live = if (options.live) .running else .disabled;
        snapshot.live_chunk_ms = if (options.live) options.live_chunk_ms else 0;
        snapshot.live_model = options.live_model_path;
        try edit.commit();
    }

    var error_buffer: [512:0]u8 = @splat(0);
    const seconds = @as(f64, @floatFromInt(options.live_chunk_ms)) / 1000;
    const system_z = try gpa.dupeZ(u8, session.system_path);
    defer gpa.free(system_z);
    const microphone_z = try gpa.dupeZ(u8, session.microphone_path);
    defer gpa.free(microphone_z);
    const log_z = try gpa.dupeZ(u8, log_path);
    defer gpa.free(log_z);
    session.capture = c.hushpin_capture_start(system_z, microphone_z, log_z, if (live_dir) |path| path.ptr else null, seconds, &error_buffer, error_buffer.len) orelse {
        const message = std.mem.sliceTo(&error_buffer, 0);
        std.debug.print("hushpin capture failed to start: {s}\n", .{message});
        var edit = try state.beginEdit(gpa, io, session.directory);
        defer edit.deinit();
        edit.snapshot().capture = .failed;
        edit.snapshot().live = if (options.live) .failed else .disabled;
        edit.snapshot().capture_error = .{ .message = message, .retryable = true };
        try edit.commit();
        return error.CaptureStartFailed;
    };
    errdefer c.hushpin_capture_deinit(session.capture);
    {
        var edit = try state.beginEdit(gpa, io, session.directory);
        defer edit.deinit();
        edit.snapshot().capture = .recording;
        edit.snapshot().artifacts.system_audio = session.system_path;
        edit.snapshot().artifacts.microphone_audio = session.microphone_path;
        edit.snapshot().artifacts.log = log_path;
        try edit.commit();
    }
    session.root_lock = root_lock;
    session.monitor_thread = try std.Thread.spawn(.{}, Session.monitorLoop, .{session});
    if (session.live != null) session.live_thread = std.Thread.spawn(.{}, Session.liveLoop, .{session}) catch |err| {
        session.monitor_stop.store(true, .release);
        session.monitor_thread.?.join();
        return err;
    };
    return .{ .started = session };
}

/// Stops capture, publishes `capture=stopped` (or failed), then drains live chunks before releasing ownership.
pub fn stopSession(session: *Session) !CaptureResult {
    const gpa = session.core.allocator;
    const io = session.core.io;
    if (session.result) |result| return result;
    try session.editCapture(.stopping, null);
    var error_buffer: [512:0]u8 = @splat(0);
    if (!session.native_stopped) session.stop_failed = c.hushpin_capture_stop(session.capture, &error_buffer, error_buffer.len) != 0;
    session.native_stopped = true;
    const stop_failed = session.stop_failed;
    session.monitor_stop.store(true, .release);
    if (session.monitor_thread) |thread| thread.join();
    session.monitor_thread = null;
    {
        var edit = try state.beginEdit(gpa, io, session.directory);
        defer edit.deinit();
        const snapshot = edit.snapshot();
        snapshot.capture = if (stop_failed) .failed else .stopped;
        if (stop_failed) snapshot.capture_error = .{ .message = std.mem.sliceTo(&error_buffer, 0), .retryable = false };
        snapshot.microphone = .unavailable;
        if (snapshot.live == .running) snapshot.live = .draining;
        try state.refreshArtifacts(edit.arena(), io, snapshot);
        try edit.commit();
    }
    session.releaseRootLock();
    session.capture_closed.store(true, .release);
    if (session.live_thread) |thread| thread.join();
    session.live_thread = null;
    var snapshot = try state.readSnapshot(gpa, io, session.directory);
    defer snapshot.deinit();
    session.owner_lock.release(io);
    session.owner_released = true;
    session.result = .{ .tracks = .{ .system_path = session.system_path, .microphone_path = session.microphone_path }, .capture = snapshot.value.capture, .live = snapshot.value.live };
    return session.result.?;
}

/// Asks the live worker to resume after a failure, starting at the first unpublished chunk. Returns the current state.
pub fn retryLiveTranscription(session: *Session) !LiveState {
    var snapshot = try state.readSnapshot(session.core.allocator, session.core.io, session.directory);
    defer snapshot.deinit();
    if (snapshot.value.live == .failed and (snapshot.value.live_error == null or snapshot.value.live_error.?.retryable)) session.retry_requested.store(true, .release);
    return snapshot.value.live;
}

/// Stops capture if needed and frees the owner handle. Saved files are preserved.
pub fn deinitSession(session: *Session) void {
    const gpa = session.core.allocator;
    _ = stopSession(session) catch {};
    session.monitor_stop.store(true, .release);
    session.capture_closed.store(true, .release);
    if (session.monitor_thread) |thread| thread.join();
    if (session.live_thread) |thread| thread.join();
    session.releaseRootLock();
    if (!session.owner_released) session.owner_lock.release(session.core.io);
    c.hushpin_capture_deinit(session.capture);
    if (session.live) |*live| live.deinit();
    gpa.free(session.system_path);
    gpa.free(session.microphone_path);
    gpa.free(session.directory);
    gpa.destroy(session);
}

/// Owner handle for one capture. Only the owner can stop capture; attaching consumers read published files.
pub const Session = struct {
    core: *RecordingCore,
    directory: []u8,
    capture: *c.HushpinCapture = undefined,
    system_path: []u8 = &.{},
    microphone_path: []u8 = &.{},
    root_lock: ?std.Io.File = null,
    owner_lock: state.OwnerLock = undefined,
    owner_released: bool = false,
    native_stopped: bool = false,
    stop_failed: bool = false,
    live: ?LiveProcessor = null,
    monitor_thread: ?std.Thread = null,
    live_thread: ?std.Thread = null,
    monitor_stop: std.atomic.Value(bool) = .init(false),
    capture_closed: std.atomic.Value(bool) = .init(false),
    retry_requested: std.atomic.Value(bool) = .init(false),
    result: ?CaptureResult = null,

    pub fn sessionId(session: *const Session) []const u8 {
        return std.fs.path.basename(session.directory);
    }

    pub fn descriptor(session: *const Session) SessionDescriptor {
        return .{ .session_id = session.sessionId(), .directory = session.directory, .owner_pid = std.c.getpid() };
    }

    fn releaseRootLock(session: *Session) void {
        const lock = session.root_lock orelse return;
        const active_path = std.fs.path.join(session.core.allocator, &.{ session.core.data_dir, "active-session.json" }) catch null;
        if (active_path) |path| {
            processing.deleteIfPresent(session.core.io, path);
            session.core.allocator.free(path);
        }
        lock.unlock(session.core.io);
        lock.close(session.core.io);
        session.root_lock = null;
    }

    fn editCapture(session: *Session, capture: CaptureState, capture_error: ?state.StageError) !void {
        var edit = try state.beginEdit(session.core.allocator, session.core.io, session.directory);
        defer edit.deinit();
        edit.snapshot().capture = capture;
        if (capture_error) |value| edit.snapshot().capture_error = value;
        try edit.commit();
    }

    fn editLive(session: *Session, live: LiveState, live_error: ?state.StageError) void {
        var edit = state.beginEdit(session.core.allocator, session.core.io, session.directory) catch |err| return reportPublishError(err);
        defer edit.deinit();
        edit.snapshot().live = live;
        edit.snapshot().live_error = live_error;
        edit.commit() catch |err| reportPublishError(err);
    }

    /// Publishes microphone availability, capture failure, and live lag. Never runs inside audio callbacks.
    fn monitorLoop(session: *Session) void {
        const io = session.core.io;
        var last_microphone: ?state.MicrophoneState = null;
        var last_pending: ?u64 = null;
        var failure_reported = false;
        while (!session.monitor_stop.load(.acquire)) : (io.sleep(.fromMilliseconds(250), .awake) catch {}) {
            const microphone: state.MicrophoneState = if (c.hushpin_capture_microphone_available(session.capture) != 0) .available else .unavailable;
            const capture_failed = c.hushpin_capture_state(session.capture) == c.HUSHPIN_CAPTURE_FAILED;
            const pending: ?u64 = if (session.live) |*live| live.pendingMs(@intCast(c.hushpin_capture_live_chunks_ready(session.capture))) else null;
            const report_failure = capture_failed and !failure_reported;
            if (microphone == last_microphone and std.meta.eql(pending, last_pending) and !report_failure) continue;
            var edit = state.beginEdit(session.core.allocator, io, session.directory) catch |err| {
                reportPublishError(err);
                continue;
            };
            defer edit.deinit();
            const snapshot = edit.snapshot();
            snapshot.microphone = microphone;
            if (pending) |value| snapshot.pending_audio_ms = value;
            if (report_failure and snapshot.capture == .recording) {
                snapshot.capture = .failed;
                snapshot.capture_error = .{ .message = "native capture stopped unexpectedly; see recording.log", .retryable = false };
                std.debug.print("hushpin: capture failed; see recording.log. Stop the session to finalize retained audio.\n", .{});
            }
            edit.commit() catch |err| {
                reportPublishError(err);
                continue;
            };
            last_microphone = microphone;
            last_pending = pending;
            if (report_failure) failure_reported = true;
        }
    }

    /// Transcribes finalized chunks in order. On failure keeps capture running and waits for `retryLiveTranscription`.
    fn liveLoop(session: *Session) void {
        const io = session.core.io;
        const live = &session.live.?;
        while (true) {
            if (c.hushpin_capture_live_failed(session.capture) != 0) {
                session.editLive(.failed, .{ .message = "a live chunk could not be written; see recording.log. Durable audio is intact.", .retryable = false });
                return;
            }
            const closed = session.capture_closed.load(.acquire); // read before the count so the final chunk is included
            const ready: u64 = @intCast(c.hushpin_capture_live_chunks_ready(session.capture));
            live.processReady(ready) catch |err| {
                session.editLive(.failed, .{ .message = @errorName(err), .retryable = true });
                while (!session.retry_requested.swap(false, .acq_rel)) {
                    if (session.capture_closed.load(.acquire)) return;
                    io.sleep(.fromMilliseconds(100), .awake) catch {};
                }
                session.editLive(if (session.capture_closed.load(.acquire)) .draining else .running, null);
                continue;
            };
            if (closed) {
                session.editLive(.complete, null);
                return;
            }
            io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }
};

fn reportPublishError(err: anyerror) void {
    std.debug.print("hushpin: cannot publish session.json: {s}\n", .{@errorName(err)});
}

/// Turns finalized chunk pairs into ordered live segments. Each chunk is published at most once.
pub const LiveProcessor = struct {
    gpa: Allocator,
    io: Io,
    /// Borrowed session directory.
    directory: []const u8,
    chunk_dir: []u8,
    chunk_ms: u64,
    model_path: []u8,
    transcribe: *const fn (live: *LiveProcessor, tracks: AudioTracks, scratch_path: []const u8) anyerror![]u8 = transcribeWithWhisper,
    segments: std.ArrayList(Segment) = .empty,
    processed: std.atomic.Value(u64) = .init(0),
    transcript_revision: u64 = 0,

    pub fn init(gpa: Allocator, io: Io, directory: []const u8, chunk_dir: []const u8, chunk_ms: u64, model_path: []const u8) !LiveProcessor {
        const owned_chunk_dir = try gpa.dupe(u8, chunk_dir);
        errdefer gpa.free(owned_chunk_dir);
        return .{ .gpa = gpa, .io = io, .directory = directory, .chunk_dir = owned_chunk_dir, .chunk_ms = chunk_ms, .model_path = try gpa.dupe(u8, model_path) };
    }

    pub fn deinit(live: *LiveProcessor) void {
        for (live.segments.items) |segment| live.gpa.free(segment.text);
        live.segments.deinit(live.gpa);
        live.gpa.free(live.chunk_dir);
        live.gpa.free(live.model_path);
    }

    pub fn pendingMs(live: *LiveProcessor, ready: u64) u64 {
        return (ready -| live.processed.load(.acquire)) * live.chunk_ms;
    }

    /// Processes chunks after the last published one through `ready`. A failure leaves later chunks on disk for retry.
    pub fn processReady(live: *LiveProcessor, ready: u64) !void {
        while (live.processed.load(.acquire) < ready) try live.processChunk(live.processed.load(.acquire) + 1, ready);
    }

    fn chunkPath(live: *LiveProcessor, chunk: u64, track: []const u8) ![]u8 {
        return std.fmt.allocPrint(live.gpa, "{s}/chunk-{d:0>6}-{s}.wav", .{ live.chunk_dir, chunk, track });
    }

    fn processChunk(live: *LiveProcessor, chunk: u64, ready: u64) !void {
        const gpa = live.gpa;
        const system = try live.chunkPath(chunk, "system");
        defer gpa.free(system);
        const microphone = try live.chunkPath(chunk, "microphone");
        defer gpa.free(microphone);
        const scratch = try std.fmt.allocPrint(gpa, "{s}/chunk-{d:0>6}", .{ live.chunk_dir, chunk });
        defer gpa.free(scratch);
        const stat = try std.Io.Dir.cwd().statFile(live.io, system, .{});
        const start_ms = (chunk - 1) * live.chunk_ms;
        const end_ms = start_ms + liveChunkDurationMs(stat.size);

        const text = try live.transcribe(live, .{ .system_path = system, .microphone_path = microphone }, scratch);
        if (text.len == 0) {
            gpa.free(text); // silence: no segment, not an error
        } else {
            errdefer gpa.free(text);
            try live.segments.append(gpa, .{ .id = live.segments.items.len + 1, .start_ms = start_ms, .end_ms = end_ms, .text = text });
            live.transcript_revision += 1;
            live.writeTranscript() catch |err| {
                _ = live.segments.pop();
                live.transcript_revision -= 1;
                return err;
            };
        }
        // The chunk is now part of the in-memory transcript; a retry after a failed snapshot write skips it.
        live.processed.store(chunk, .release);
        var edit = try state.beginEdit(gpa, live.io, live.directory);
        defer edit.deinit();
        const snapshot = edit.snapshot();
        snapshot.live_transcript_revision = live.transcript_revision;
        snapshot.last_segment_id = live.segments.items.len;
        snapshot.live_chunks_processed = chunk;
        snapshot.processed_audio_end_ms = end_ms;
        snapshot.pending_audio_ms = (ready -| chunk) * live.chunk_ms;
        if (live.transcript_revision > 0) snapshot.artifacts.live_transcript = try state.sessionFile(edit.arena(), live.directory, "live-transcript.txt");
        try edit.commit();
        processing.deleteIfPresent(live.io, system);
        processing.deleteIfPresent(live.io, microphone);
    }

    fn writeTranscript(live: *LiveProcessor) !void {
        var out: std.Io.Writer.Allocating = .init(live.gpa);
        defer out.deinit();
        try state.writeLiveTranscript(&out.writer, std.fs.path.basename(live.directory), live.transcript_revision, live.segments.items);
        const path = try state.sessionFile(live.gpa, live.directory, "live-transcript.txt");
        defer live.gpa.free(path);
        try processing.writeFileAtomically(live.gpa, live.io, path, out.written(), true);
    }

    fn transcribeWithWhisper(live: *LiveProcessor, tracks: AudioTracks, scratch_path: []const u8) ![]u8 {
        return processing.transcribeLiveChunk(live.gpa, live.io, tracks, live.model_path, scratch_path);
    }
};

/// Live chunks are 16 kHz mono float32 WAV with a 44-byte header.
fn liveChunkDurationMs(file_size: u64) u64 {
    return (file_size -| 44) / 4 / 16;
}

/// Accepts a session id (`recording-…`) or path and returns its absolute directory after verifying Hushpin owns it.
pub fn resolveSessionDirectory(core: *RecordingCore, session: []const u8) ![]u8 {
    const gpa = core.allocator;
    const joined = if (std.mem.indexOfScalar(u8, session, '/') == null) try std.fs.path.join(gpa, &.{ core.data_dir, session }) else try gpa.dupe(u8, session);
    defer gpa.free(joined);
    const absolute = std.Io.Dir.cwd().realPathFileAlloc(core.io, joined, gpa) catch return error.SessionNotFound;
    defer gpa.free(absolute);
    if (!isChildPath(core.data_dir, absolute) or std.mem.indexOfScalar(u8, absolute[core.data_dir.len + 1 ..], '/') != null) return error.UnownedSessionDirectory;
    if (parseRecordingDirectoryName(std.fs.path.basename(absolute)) == null) return error.UnownedSessionDirectory;
    const marker = try std.fs.path.join(gpa, &.{ absolute, ".hushpin-owned" });
    defer gpa.free(marker);
    processing.requireNonemptyFile(core.io, marker) catch return error.UnownedSessionDirectory;
    return gpa.dupe(u8, absolute);
}

/// Reads the published snapshot for a resolved session directory.
pub fn getSession(core: *RecordingCore, directory: []const u8) !std.json.Parsed(SessionSnapshot) {
    return state.readSnapshot(core.allocator, core.io, directory);
}

pub fn subscribeSession(core: *RecordingCore, directory: []const u8) Subscription {
    return state.subscribeSession(core.allocator, core.io, directory);
}

pub fn mixRecording(core: *RecordingCore, tracks: AudioTracks, output_path: []const u8) !void {
    return processing.mixRecording(core.allocator, core.io, tracks, output_path);
}

pub fn transcribeRecording(core: *RecordingCore, audio_path: []const u8, model_path: []const u8, transcript_path: []const u8) !void {
    return processing.transcribeRecording(core.allocator, core.io, audio_path, model_path, transcript_path);
}

/// Mixes and transcribes the complete retained recording, reusing stages that already completed.
/// Waits for a draining capture owner; refuses while capture is still recording. Returns the transcript path.
pub fn finalizeTranscript(core: *RecordingCore, directory: []const u8, options: FinalizeOptions) ![]u8 {
    const gpa = core.allocator;
    const io = core.io;
    if (!processing.isNonemptyFile(io, options.model_path)) return error.ModelNotFound;
    {
        var snapshot = try state.readSnapshot(gpa, io, directory);
        defer snapshot.deinit();
        const capturing = switch (snapshot.value.capture) { .starting, .recording, .stopping => true, else => false };
        if (capturing and try state.ownerAlive(gpa, io, directory)) return error.CaptureActive;
    }
    var owner_lock = try state.acquireOwnerLock(gpa, io, directory, true);
    defer owner_lock.release(io);
    {
        var edit = try state.beginEdit(gpa, io, directory);
        defer edit.deinit();
        edit.snapshot().final = .running;
        edit.snapshot().final_error = null;
        edit.snapshot().owner_pid = std.c.getpid();
        try edit.commit();
    }
    const transcript = try std.fs.path.join(gpa, &.{ directory, "transcript.txt" });
    errdefer gpa.free(transcript);
    runFinalStages(core, directory, options.model_path, transcript) catch |err| {
        var edit = try state.beginEdit(gpa, io, directory);
        defer edit.deinit();
        edit.snapshot().final = .failed;
        edit.snapshot().final_error = .{ .message = @errorName(err), .retryable = true };
        try state.refreshArtifacts(edit.arena(), io, edit.snapshot());
        try edit.commit();
        return err;
    };
    var edit = try state.beginEdit(gpa, io, directory);
    defer edit.deinit();
    edit.snapshot().final = .complete;
    try state.refreshArtifacts(edit.arena(), io, edit.snapshot());
    try edit.commit();
    return transcript;
}

fn runFinalStages(core: *RecordingCore, directory: []const u8, model_path: []const u8, transcript: []const u8) !void {
    const gpa = core.allocator;
    const system = try std.fs.path.join(gpa, &.{ directory, "audio", "system.caf" });
    defer gpa.free(system);
    const microphone = try std.fs.path.join(gpa, &.{ directory, "audio", "microphone.caf" });
    defer gpa.free(microphone);
    const mixed = try std.fs.path.join(gpa, &.{ directory, "audio", "mixed.m4a" });
    defer gpa.free(mixed);
    if (processing.isNonemptyFile(core.io, transcript)) return;
    if (!processing.isNonemptyFile(core.io, mixed)) try mixRecording(core, .{ .system_path = system, .microphone_path = microphone }, mixed);
    try transcribeRecording(core, mixed, model_path, transcript);
}

/// Deletes a session's `audio/` after capture and processing release it. Text artifacts are preserved.
pub fn cleanupSessionAudio(core: *RecordingCore, directory: []const u8) !void {
    const gpa = core.allocator;
    const io = core.io;
    const owned = try resolveSessionDirectory(core, directory);
    defer gpa.free(owned);
    var owner_lock = state.acquireOwnerLock(gpa, io, owned, false) catch |err| return if (err == error.SessionBusy) error.SessionActive else err;
    defer owner_lock.release(io);
    {
        var snapshot = try state.readSnapshot(gpa, io, owned);
        defer snapshot.deinit();
        if (snapshot.value.final == .running) return error.SessionActive; // a finalizer exited mid-run; finish it first
    }
    const audio = try std.fs.path.join(gpa, &.{ owned, "audio" });
    defer gpa.free(audio);
    try std.Io.Dir.cwd().deleteTree(io, audio);
    var edit = try state.beginEdit(gpa, io, owned);
    defer edit.deinit();
    try state.refreshArtifacts(edit.arena(), io, edit.snapshot());
    try edit.commit();
}

/// Files found in one recording directory. Missing or empty files are null.
pub const RecordingFiles = struct {
    directory: []u8,
    /// Parsed from the `recording-<ns>-<attempt>` directory name.
    started_at_ns: i96,
    system_path: ?[]u8 = null,
    microphone_path: ?[]u8 = null,
    mixed_path: ?[]u8 = null,
    live_transcript_path: ?[]u8 = null,
    transcript_path: ?[]u8 = null,

    const path_fields = .{ "system_path", "microphone_path", "mixed_path", "live_transcript_path", "transcript_path" };

    fn deinit(files: *RecordingFiles, allocator: Allocator) void {
        allocator.free(files.directory);
        inline for (path_fields) |field| {
            if (@field(files, field)) |path| allocator.free(path);
        }
    }
};

/// Returns Hushpin-owned recordings under data_dir, newest first, with absolute stage file paths.
pub fn getRecentRecordings(core: *RecordingCore) ![]RecordingFiles {
    var dir = try std.Io.Dir.cwd().openDir(core.io, core.data_dir, .{ .iterate = true });
    defer dir.close(core.io);
    var recordings: std.ArrayList(RecordingFiles) = .empty;
    errdefer deinitRecordings(core, recordings.items);
    defer recordings.deinit(core.allocator);
    var iterator = dir.iterate();
    while (try iterator.next(core.io)) |entry| {
        if (entry.kind != .directory) continue;
        const started_at_ns = parseRecordingDirectoryName(entry.name) orelse continue;
        const directory = try std.fs.path.join(core.allocator, &.{ core.data_dir, entry.name });
        errdefer core.allocator.free(directory);
        const marker = try std.fs.path.join(core.allocator, &.{ directory, ".hushpin-owned" });
        defer core.allocator.free(marker);
        if (!processing.pathExists(core.io, marker)) {
            core.allocator.free(directory);
            continue;
        }
        var files: RecordingFiles = .{ .directory = directory, .started_at_ns = started_at_ns };
        errdefer files.deinit(core.allocator);
        const locations = .{ "audio/system.caf", "audio/microphone.caf", "audio/mixed.m4a", "live-transcript.txt", "transcript.txt" };
        inline for (RecordingFiles.path_fields, locations) |field, location| {
            const path = try std.fs.path.join(core.allocator, &.{ directory, location });
            if (processing.isNonemptyFile(core.io, path)) @field(files, field) = path else core.allocator.free(path);
        }
        try recordings.append(core.allocator, files);
    }
    std.mem.sort(RecordingFiles, recordings.items, {}, struct {
        fn newerFirst(_: void, a: RecordingFiles, b: RecordingFiles) bool {
            return a.started_at_ns > b.started_at_ns;
        }
    }.newerFirst);
    return recordings.toOwnedSlice(core.allocator);
}

pub fn deinitRecordings(core: *RecordingCore, recordings: []RecordingFiles) void {
    for (recordings) |*files| files.deinit(core.allocator);
    core.allocator.free(recordings);
}

fn createSessionDirectory(core: *RecordingCore) ![]u8 {
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        const name = try std.fmt.allocPrint(core.allocator, "recording-{d}-{d}", .{ Io.Clock.real.now(core.io).nanoseconds, attempt });
        defer core.allocator.free(name);
        const path = try std.fs.path.join(core.allocator, &.{ core.data_dir, name });
        std.Io.Dir.cwd().createDir(core.io, path, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                core.allocator.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.RecordingDirectoryUnavailable;
}

fn parseRecordingDirectoryName(name: []const u8) ?i96 {
    if (!std.mem.startsWith(u8, name, "recording-")) return null;
    const rest = name["recording-".len..];
    const dash = std.mem.lastIndexOfScalar(u8, rest, '-') orelse return null;
    _ = std.fmt.parseInt(u32, rest[dash + 1 ..], 10) catch return null;
    return std.fmt.parseInt(i96, rest[0..dash], 10) catch null;
}

fn isChildPath(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and std.fs.path.isSep(child[parent.len]);
}

test {
    _ = processing;
    _ = state;
}

const testing = std.testing;

fn testWriteFiles(io: Io, root: []const u8, files: []const [2][]const u8) !void {
    for (files) |file| {
        const path = try std.fs.path.join(testing.allocator, &.{ root, file[0] });
        defer testing.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file[1] });
    }
}

fn testCore(threaded: *std.Io.Threaded, data_dir: []const u8) !RecordingCore {
    std.Io.Dir.cwd().deleteTree(threaded.io(), data_dir) catch {};
    return initRecordingCore(testing.allocator, threaded.io(), data_dir);
}

fn testSession(core: *RecordingCore, name: []const u8) ![]u8 {
    const directory = try std.fs.path.join(testing.allocator, &.{ core.data_dir, name });
    errdefer testing.allocator.free(directory);
    try testWriteFiles(core.io, directory, &.{.{ ".hushpin-owned", "hushpin recording\n" }});
    return directory;
}

fn testSilentWav(gpa: Allocator, ms: u64) ![]u8 {
    const bytes = try gpa.alloc(u8, 44 + ms * 16 * 4);
    @memset(bytes, 0);
    return bytes;
}

const FakeTranscriber = struct {
    var attempts: [5]u32 = @splat(0);

    fn transcribe(_: *LiveProcessor, tracks: AudioTracks, _: []const u8) anyerror![]u8 {
        const name = std.fs.path.basename(tracks.system_path);
        const chunk = try std.fmt.parseInt(usize, name["chunk-".len .. "chunk-".len + 6], 10);
        attempts[chunk] += 1;
        if (chunk == 3 and attempts[chunk] == 1) return error.SimulatedWhisperFailure;
        const texts = [_][]const u8{ "", "hello", "", "third", "last" };
        return testing.allocator.dupe(u8, texts[chunk]);
    }
};

test "live processing publishes ordered segments, skips silence, retries without duplicates, and drains a partial chunk" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-live-test");
    defer deinitRecordingCore(&core);
    const gpa = testing.allocator;
    const io = core.io;
    const directory = try testSession(&core, "recording-1-0");
    defer gpa.free(directory);
    const chunk_dir = try std.fs.path.join(gpa, &.{ directory, "audio", "live" });
    defer gpa.free(chunk_dir);
    const full = try testSilentWav(gpa, 5000);
    defer gpa.free(full);
    const partial = try testSilentWav(gpa, 2500);
    defer gpa.free(partial);
    try testWriteFiles(io, chunk_dir, &.{
        .{ "chunk-000001-system.wav", full },    .{ "chunk-000001-microphone.wav", full },
        .{ "chunk-000002-system.wav", full },    .{ "chunk-000002-microphone.wav", full },
        .{ "chunk-000003-system.wav", full },    .{ "chunk-000003-microphone.wav", full },
        .{ "chunk-000004-system.wav", partial }, .{ "chunk-000004-microphone.wav", partial },
    });

    var live = try LiveProcessor.init(gpa, io, directory, chunk_dir, 5000, "unused-model");
    defer live.deinit();
    live.transcribe = FakeTranscriber.transcribe;
    FakeTranscriber.attempts = @splat(0);

    try testing.expectError(error.SimulatedWhisperFailure, live.processReady(4));
    {
        var snapshot = try getSession(&core, directory);
        defer snapshot.deinit();
        try testing.expectEqual(@as(u64, 2), snapshot.value.live_chunks_processed);
        try testing.expectEqual(@as(u64, 1), snapshot.value.last_segment_id);
        try testing.expectEqual(@as(u64, 10_000), snapshot.value.processed_audio_end_ms);
        try testing.expectEqual(@as(u64, 10_000), snapshot.value.pending_audio_ms);
    }
    try testing.expectEqual(@as(u64, 10_000), live.pendingMs(4));
    const kept = try std.fs.path.join(gpa, &.{ chunk_dir, "chunk-000003-system.wav" });
    defer gpa.free(kept);
    try testing.expect(processing.pathExists(io, kept)); // pending chunks stay on disk for retry

    try live.processReady(4);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, 2, 1 }, &FakeTranscriber.attempts);
    try testing.expect(!processing.pathExists(io, kept));

    var published = try readConsistentLiveTranscript(gpa, io, directory);
    defer published.deinit(gpa);
    try testing.expectEqualStrings(
        \\# session=recording-1-0 revision=3
        \\[1 00:00.000–00:05.000] hello
        \\[2 00:10.000–00:15.000] third
        \\[3 00:15.000–00:17.500] last
        \\
    , published.transcript);
    try testing.expectEqual(@as(u64, 3), published.snapshot.value.last_segment_id);
    try testing.expectEqual(@as(u64, 17_500), published.snapshot.value.processed_audio_end_ms);
    try testing.expectEqual(@as(u64, 0), published.snapshot.value.pending_audio_ms);
    try testing.expect(published.snapshot.value.artifacts.live_transcript != null);

    // A transcript newer than session.json is not accepted as consistent.
    try testWriteFiles(io, directory, &.{.{ "live-transcript.txt", "# session=recording-1-0 revision=4\n" }});
    try testing.expectError(error.LiveTranscriptInconsistent, readConsistentLiveTranscript(gpa, io, directory));
}

test "subscription reports owner loss without synthesizing completion" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-watch-test");
    defer deinitRecordingCore(&core);
    const gpa = testing.allocator;
    const directory = try testSession(&core, "recording-2-0");
    defer gpa.free(directory);
    {
        var edit = try state.beginEdit(gpa, core.io, directory);
        defer edit.deinit();
        edit.snapshot().capture = .recording;
        try edit.commit();
    }
    var lost = subscribeSession(&core, directory);
    lost.poll_ms = 5;
    var first = (try lost.next()).?;
    first.deinit();
    try testing.expectError(error.OwnerLost, lost.next());
    var after = try getSession(&core, directory);
    defer after.deinit();
    try testing.expectEqual(CaptureState.recording, after.value.capture); // the reader never mutates the snapshot

    var owner = try state.acquireOwnerLock(gpa, core.io, directory, false);
    try testing.expect(try state.ownerAlive(gpa, core.io, directory));
    var watch = subscribeSession(&core, directory);
    watch.poll_ms = 5;
    var initial = (try watch.next()).?;
    initial.deinit();
    {
        var edit = try state.beginEdit(gpa, core.io, directory);
        defer edit.deinit();
        edit.snapshot().capture = .stopped;
        edit.snapshot().final = .complete;
        try edit.commit();
    }
    var stopped = (try watch.next()).?;
    try testing.expectEqual(CaptureState.stopped, stopped.value.capture);
    stopped.deinit();
    owner.release(core.io);
    try testing.expect(!try state.ownerAlive(gpa, core.io, directory));
    try testing.expect(try watch.next() == null);
}

test "second start returns the active session descriptor without capturing" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-active-test");
    defer deinitRecordingCore(&core);
    try testWriteFiles(core.io, core.data_dir, &.{.{ "active-session.json", "{\"session_id\":\"recording-3-0\",\"directory\":\"/x/recording-3-0\",\"owner_pid\":42}" }});
    const lock_path = try std.fs.path.join(testing.allocator, &.{ core.data_dir, "capture.lock" });
    defer testing.allocator.free(lock_path);
    var lock = try std.Io.Dir.cwd().createFile(core.io, lock_path, .{ .lock = .exclusive });
    defer lock.close(core.io);
    var result = try startSession(&core, .{});
    try testing.expect(result == .already_active);
    defer result.already_active.deinit();
    try testing.expectEqualStrings("recording-3-0", result.already_active.value.session_id);
    try testing.expectEqual(@as(i32, 42), result.already_active.value.owner_pid);
    try testing.expectError(error.ModelNotFound, startSession(&core, .{ .live = true, .live_model_path = "missing.bin" }));
}

test "finalize reuses completed stages after a live failure" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-finalize-test");
    defer deinitRecordingCore(&core);
    const gpa = testing.allocator;
    const directory = try testSession(&core, "recording-4-0");
    defer gpa.free(directory);
    try testWriteFiles(core.io, directory, &.{ .{ "transcript.txt", "final words\n" }, .{ "model.bin", "m" } });
    {
        var edit = try state.beginEdit(gpa, core.io, directory);
        defer edit.deinit();
        edit.snapshot().capture = .stopped;
        edit.snapshot().live = .failed;
        edit.snapshot().live_error = .{ .message = "SimulatedWhisperFailure", .retryable = true };
        try edit.commit();
    }
    const model = try std.fs.path.join(gpa, &.{ directory, "model.bin" });
    defer gpa.free(model);
    try testing.expectError(error.ModelNotFound, finalizeTranscript(&core, directory, .{ .model_path = "missing.bin" }));
    const transcript = try finalizeTranscript(&core, directory, .{ .model_path = model });
    defer gpa.free(transcript);
    var snapshot = try getSession(&core, directory);
    defer snapshot.deinit();
    try testing.expectEqual(FinalState.complete, snapshot.value.final);
    try testing.expectEqual(LiveState.failed, snapshot.value.live); // independent stages
    try testing.expectEqualStrings(transcript, snapshot.value.artifacts.transcript.?);
}

test "finalize refuses while the owner is still capturing" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-finalize-active-test");
    defer deinitRecordingCore(&core);
    const gpa = testing.allocator;
    const directory = try testSession(&core, "recording-5-0");
    defer gpa.free(directory);
    try testWriteFiles(core.io, directory, &.{.{ "model.bin", "m" }});
    var owner = try state.acquireOwnerLock(gpa, core.io, directory, false);
    defer owner.release(core.io);
    {
        var edit = try state.beginEdit(gpa, core.io, directory);
        defer edit.deinit();
        edit.snapshot().capture = .recording;
        try edit.commit();
    }
    const model = try std.fs.path.join(gpa, &.{ directory, "model.bin" });
    defer gpa.free(model);
    try testing.expectError(error.CaptureActive, finalizeTranscript(&core, directory, .{ .model_path = model }));
}

test "cleanup refuses active and unowned sessions and preserves text artifacts" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-cleanup-test");
    defer deinitRecordingCore(&core);
    const gpa = testing.allocator;
    const io = core.io;
    const directory = try testSession(&core, "recording-6-0");
    defer gpa.free(directory);
    try testWriteFiles(io, directory, &.{ .{ "audio/system.caf", "a" }, .{ "transcript.txt", "t" }, .{ "metadata.json", "{}" } });
    try testWriteFiles(io, core.data_dir, &.{.{ "recording-7-0/audio/system.caf", "a" }});

    var owner = try state.acquireOwnerLock(gpa, io, directory, false);
    try testing.expectError(error.SessionActive, cleanupSessionAudio(&core, directory));
    owner.release(io);
    try testing.expectError(error.UnownedSessionDirectory, cleanupSessionAudio(&core, "recording-7-0"));
    try testing.expectError(error.SessionNotFound, cleanupSessionAudio(&core, "recording-8-0"));
    try testing.expectError(error.UnownedSessionDirectory, cleanupSessionAudio(&core, ".zig-cache/"));

    try cleanupSessionAudio(&core, "recording-6-0");
    const audio = try std.fs.path.join(gpa, &.{ directory, "audio" });
    defer gpa.free(audio);
    try testing.expect(!processing.pathExists(io, audio));
    for ([_][]const u8{ "transcript.txt", "metadata.json" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ directory, name });
        defer gpa.free(path);
        try testing.expect(processing.pathExists(io, path));
    }
}

test "recent recordings are owned, newest first, with only nonempty files" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var core = try testCore(&threaded, ".zig-cache/hushpin-list-test");
    defer deinitRecordingCore(&core);
    try std.Io.Dir.cwd().createDirPath(core.io, ".zig-cache/hushpin-list-test/recording-400-0");
    try testWriteFiles(core.io, core.data_dir, &.{
        .{ "recording-100-0/.hushpin-owned", "x" },
        .{ "recording-100-0/audio/system.caf", "x" },
        .{ "recording-100-0/audio/microphone.caf", "" },
        .{ "recording-300-0/.hushpin-owned", "x" },
        .{ "recording-300-0/transcript.txt", "x" },
        .{ "recording-300-0/live-transcript.txt", "x" },
        .{ "recording-200-1/.hushpin-owned", "x" },
        .{ "recording-bad-0/.hushpin-owned", "x" },
        .{ "unowned/.hushpin-owned", "x" },
    });
    const recordings = try getRecentRecordings(&core);
    defer deinitRecordings(&core, recordings);
    try testing.expectEqual(@as(usize, 3), recordings.len);
    try testing.expectEqual(@as(i96, 300), recordings[0].started_at_ns);
    try testing.expectEqual(@as(i96, 200), recordings[1].started_at_ns);
    try testing.expectEqual(@as(i96, 100), recordings[2].started_at_ns);
    try testing.expect(std.fs.path.isAbsolute(recordings[0].directory));
    try testing.expect(std.mem.endsWith(u8, recordings[0].transcript_path.?, "/recording-300-0/transcript.txt"));
    try testing.expect(recordings[0].live_transcript_path != null);
    try testing.expect(recordings[0].mixed_path == null);
    try testing.expect(recordings[1].system_path == null);
    try testing.expect(recordings[2].system_path != null);
    try testing.expect(recordings[2].microphone_path == null);
}
