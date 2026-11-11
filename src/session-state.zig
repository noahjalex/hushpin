//! Session publication: `session.json` snapshots, owner liveness, and the live transcript file contract.
const std = @import("std");
const processing = @import("audio-processing.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const schema_version = 1;

pub const CaptureState = enum { starting, recording, stopping, stopped, failed };
pub const MicrophoneState = enum { available, unavailable };
pub const LiveState = enum { disabled, running, draining, complete, failed };
pub const FinalState = enum { pending, running, complete, failed };

pub const StageError = struct {
    message: []const u8,
    retryable: bool,
};

/// Absolute artifact paths, null until the artifact exists.
pub const Artifacts = struct {
    system_audio: ?[]const u8 = null,
    microphone_audio: ?[]const u8 = null,
    mixed_audio: ?[]const u8 = null,
    live_transcript: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
    log: ?[]const u8 = null,
};

/// Identifies a session and the process that owns its capture or processing.
pub const SessionDescriptor = struct {
    session_id: []const u8,
    /// Absolute session directory.
    directory: []const u8,
    /// Process that last owned capture or processing. Liveness is checked with the `owner.lock` flock, not the pid.
    owner_pid: i32 = 0,
};

/// The authoritative published state in `session.json`. Stage states are independent of each other.
pub const SessionSnapshot = struct {
    schema_version: u32 = schema_version,
    revision: u64 = 0,
    session_id: []const u8,
    directory: []const u8,
    owner_pid: i32 = 0,
    capture: CaptureState = .starting,
    microphone: MicrophoneState = .unavailable,
    live: LiveState = .disabled,
    final: FinalState = .pending,
    live_chunk_ms: u64 = 0,
    live_model: ?[]const u8 = null,
    live_transcript_revision: u64 = 0,
    last_segment_id: u64 = 0,
    live_chunks_processed: u64 = 0,
    processed_audio_end_ms: u64 = 0,
    pending_audio_ms: u64 = 0,
    artifacts: Artifacts = .{},
    capture_error: ?StageError = null,
    live_error: ?StageError = null,
    final_error: ?StageError = null,

    pub fn descriptor(snapshot: SessionSnapshot) SessionDescriptor {
        return .{ .session_id = snapshot.session_id, .directory = snapshot.directory, .owner_pid = snapshot.owner_pid };
    }

    /// True while some stage claims to be making progress; an owner must be alive to finish it.
    pub fn inProgress(snapshot: SessionSnapshot) bool {
        return switch (snapshot.capture) { .starting, .recording, .stopping => true, else => false } or
            snapshot.live == .running or snapshot.live == .draining or snapshot.final == .running;
    }
};

pub fn sessionFile(gpa: Allocator, directory: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ directory, name });
}

/// Reads `session.json`. Older Hushpin recordings without one get a synthesized stopped snapshot.
pub fn readSnapshot(gpa: Allocator, io: Io, directory: []const u8) !std.json.Parsed(SessionSnapshot) {
    const path = try sessionFile(gpa, directory, "session.json");
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return legacySnapshot(gpa, io, directory),
        else => return err,
    };
    defer gpa.free(bytes);
    return std.json.parseFromSlice(SessionSnapshot, gpa, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

fn legacySnapshot(gpa: Allocator, io: Io, directory: []const u8) !std.json.Parsed(SessionSnapshot) {
    const marker = try sessionFile(gpa, directory, ".hushpin-owned");
    defer gpa.free(marker);
    if (!processing.pathExists(io, marker)) return error.SessionNotFound;
    var parsed: std.json.Parsed(SessionSnapshot) = .{ .arena = try gpa.create(std.heap.ArenaAllocator), .value = undefined };
    errdefer gpa.destroy(parsed.arena);
    parsed.arena.* = .init(gpa);
    errdefer parsed.arena.deinit();
    const arena = parsed.arena.allocator();
    parsed.value = .{ .session_id = try arena.dupe(u8, std.fs.path.basename(directory)), .directory = try arena.dupe(u8, directory), .capture = .stopped };
    try refreshArtifacts(arena, io, &parsed.value);
    if (parsed.value.artifacts.transcript != null) parsed.value.final = .complete;
    return parsed;
}

/// Sets artifact paths to the files that currently exist and are nonempty.
pub fn refreshArtifacts(arena: Allocator, io: Io, snapshot: *SessionSnapshot) !void {
    const fields = .{
        .{ "system_audio", "audio/system.caf" },   .{ "microphone_audio", "audio/microphone.caf" },
        .{ "mixed_audio", "audio/mixed.m4a" },     .{ "live_transcript", "live-transcript.txt" },
        .{ "transcript", "transcript.txt" },       .{ "log", "recording.log" },
    };
    inline for (fields) |field| {
        const path = try std.fs.path.join(arena, &.{ snapshot.directory, field[1] });
        @field(snapshot.artifacts, field[0]) = if (processing.isNonemptyFile(io, path)) path else null;
    }
}

/// A locked read-modify-write of `session.json`. Edits from threads and processes serialize on `session.lock`.
pub const SnapshotEdit = struct {
    gpa: Allocator,
    io: Io,
    parsed: std.json.Parsed(SessionSnapshot),
    lock_file: std.Io.File,

    pub fn snapshot(edit: *SnapshotEdit) *SessionSnapshot {
        return &edit.parsed.value;
    }

    /// Arena for strings stored in the snapshot during this edit.
    pub fn arena(edit: *SnapshotEdit) Allocator {
        return edit.parsed.arena.allocator();
    }

    /// Increments the revision and atomically replaces `session.json`. Notification happens through this file change.
    pub fn commit(edit: *SnapshotEdit) !void {
        edit.parsed.value.revision += 1;
        const bytes = try std.json.Stringify.valueAlloc(edit.gpa, edit.parsed.value, .{ .whitespace = .indent_2 });
        defer edit.gpa.free(bytes);
        const path = try sessionFile(edit.gpa, edit.parsed.value.directory, "session.json");
        defer edit.gpa.free(path);
        try processing.writeFileAtomically(edit.gpa, edit.io, path, bytes, true);
    }

    pub fn deinit(edit: *SnapshotEdit) void {
        edit.lock_file.unlock(edit.io);
        edit.lock_file.close(edit.io);
        edit.parsed.deinit();
        edit.* = undefined;
    }
};

pub fn beginEdit(gpa: Allocator, io: Io, directory: []const u8) !SnapshotEdit {
    const lock_path = try sessionFile(gpa, directory, "session.lock");
    defer gpa.free(lock_path);
    var lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer lock_file.close(io);
    try lock_file.lock(io, .exclusive);
    errdefer lock_file.unlock(io);
    return .{ .gpa = gpa, .io = io, .parsed = try readSnapshot(gpa, io, directory), .lock_file = lock_file };
}

/// Holds `owner.lock` exclusively. The kernel drops it when the owner exits, which is how readers detect owner loss.
pub const OwnerLock = struct {
    file: std.Io.File,

    pub fn release(lock: *OwnerLock, io: Io) void {
        lock.file.unlock(io);
        lock.file.close(io);
        lock.* = undefined;
    }
};

pub fn acquireOwnerLock(gpa: Allocator, io: Io, directory: []const u8, wait: bool) !OwnerLock {
    const path = try sessionFile(gpa, directory, "owner.lock");
    defer gpa.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    if (wait) try file.lock(io, .exclusive) else if (!try file.tryLock(io, .exclusive)) return error.SessionBusy;
    return .{ .file = file };
}

/// True while some process holds the session's owner lock.
pub fn ownerAlive(gpa: Allocator, io: Io, directory: []const u8) !bool {
    const path = try sessionFile(gpa, directory, "owner.lock");
    defer gpa.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    if (!try file.tryLock(io, .shared)) return true;
    file.unlock(io);
    return false;
}

/// One published live segment. Times are session-relative milliseconds.
pub const Segment = struct {
    id: u64,
    start_ms: u64,
    end_ms: u64,
    text: []const u8,
};

/// Renders the complete live transcript, e.g. `[2 00:05.000–00:10.000] text`.
pub fn writeLiveTranscript(out: *std.Io.Writer, session_id: []const u8, revision: u64, segments: []const Segment) !void {
    try out.print("# session={s} revision={d}\n", .{ session_id, revision });
    for (segments) |segment| {
        try out.print("[{d} ", .{segment.id});
        try writeTimestamp(out, segment.start_ms);
        try out.writeAll("–");
        try writeTimestamp(out, segment.end_ms);
        try out.print("] {s}\n", .{segment.text});
    }
}

fn writeTimestamp(out: *std.Io.Writer, ms: u64) !void {
    try out.print("{d:0>2}:{d:0>2}.{d:0>3}", .{ ms / 60_000, ms / 1000 % 60, ms % 1000 });
}

/// Parses the `revision=N` from a live transcript header.
pub fn liveTranscriptRevision(bytes: []const u8) ?u64 {
    const line_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
    const header = bytes[0..line_end];
    const key = " revision=";
    const at = std.mem.lastIndexOf(u8, header, key) orelse return null;
    return std.fmt.parseInt(u64, header[at + key.len ..], 10) catch null;
}

pub const ConsistentLiveTranscript = struct {
    snapshot: std.json.Parsed(SessionSnapshot),
    transcript: []u8,

    pub fn deinit(value: *ConsistentLiveTranscript, gpa: Allocator) void {
        value.snapshot.deinit();
        gpa.free(value.transcript);
    }
};

/// Reads a snapshot and the live transcript revision it refers to, retrying while the two files disagree.
pub fn readConsistentLiveTranscript(gpa: Allocator, io: Io, directory: []const u8) !ConsistentLiveTranscript {
    const path = try sessionFile(gpa, directory, "live-transcript.txt");
    defer gpa.free(path);
    var attempt: u32 = 0;
    while (attempt < 50) : (attempt += 1) {
        var snapshot = try readSnapshot(gpa, io, directory);
        errdefer snapshot.deinit();
        const transcript = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try gpa.dupe(u8, ""),
            else => return err,
        };
        const revision = liveTranscriptRevision(transcript) orelse 0;
        if (revision == snapshot.value.live_transcript_revision) return .{ .snapshot = snapshot, .transcript = transcript };
        gpa.free(transcript);
        snapshot.deinit();
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    return error.LiveTranscriptInconsistent;
}

/// Delivers the current snapshot, then each later revision. Polls `session.json`; closing it never affects capture.
pub const Subscription = struct {
    gpa: Allocator,
    io: Io,
    directory: []const u8,
    last_revision: ?u64 = null,
    poll_ms: i64 = 200,

    /// Returns the next snapshot; null once final transcription completed or failed and no owner remains;
    /// `error.OwnerLost` when the owner exited mid-stage. Between stages (e.g. capture done, `finish` not yet run)
    /// it keeps waiting. Never synthesizes completion.
    pub fn next(sub: *Subscription) !?std.json.Parsed(SessionSnapshot) {
        while (true) {
            var snapshot = try readSnapshot(sub.gpa, sub.io, sub.directory);
            if (sub.last_revision == null or snapshot.value.revision != sub.last_revision.?) {
                sub.last_revision = snapshot.value.revision;
                return snapshot;
            }
            const in_progress = snapshot.value.inProgress();
            const final_done = snapshot.value.final == .complete or snapshot.value.final == .failed;
            snapshot.deinit();
            if ((in_progress or final_done) and !try ownerAlive(sub.gpa, sub.io, sub.directory)) {
                // Re-read: the owner may have published its last state just before exiting.
                var latest = try readSnapshot(sub.gpa, sub.io, sub.directory);
                if (latest.value.revision != sub.last_revision.?) {
                    sub.last_revision = latest.value.revision;
                    return latest;
                }
                latest.deinit();
                if (in_progress) return error.OwnerLost;
                return null;
            }
            sub.io.sleep(.fromMilliseconds(sub.poll_ms), .awake) catch {};
        }
    }
};

pub fn subscribeSession(gpa: Allocator, io: Io, directory: []const u8) Subscription {
    return .{ .gpa = gpa, .io = io, .directory = directory };
}

test "live transcript format round-trips its revision" {
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeLiveTranscript(&out, "recording-123", 2, &.{
        .{ .id = 1, .start_ms = 0, .end_ms = 5000, .text = "Does the recorder support audio export?" },
        .{ .id = 2, .start_ms = 65_000, .end_ms = 67_250, .text = "I'll send the draft tomorrow." },
    });
    try std.testing.expectEqualStrings(
        \\# session=recording-123 revision=2
        \\[1 00:00.000–00:05.000] Does the recorder support audio export?
        \\[2 01:05.000–01:07.250] I'll send the draft tomorrow.
        \\
    , out.buffered());
    try std.testing.expectEqual(@as(?u64, 2), liveTranscriptRevision(out.buffered()));
    try std.testing.expectEqual(@as(?u64, null), liveTranscriptRevision("no header"));
}
