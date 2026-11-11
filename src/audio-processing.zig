//! Shared ffmpeg mixing, whisper.cpp transcription, subprocess, and atomic file helpers for live and batch processing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Identifies the separately captured system and microphone tracks for mixing.
pub const AudioTracks = struct {
    system_path: []const u8,
    microphone_path: []const u8,
    /// Positive means microphone audio begins after system audio.
    microphone_offset_ns: i64 = 0,
};

const mix_filter = "[0:a]aresample=48000:async=1000:first_pts=0,volume=0.85[system];[1:a]aresample=48000:async=1000:first_pts=0,volume=1.00[microphone];[system][microphone]amix=inputs=2:duration=longest:normalize=1[a]";
const aac_output = [_][]const u8{ "-ar", "48000", "-c:a", "aac", "-b:a", "192k" };
const whisper_input_output = [_][]const u8{ "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le" };

/// Mixes system and microphone tracks with their requested relative offset into AAC audio.
pub fn mixRecording(gpa: Allocator, io: Io, tracks: AudioTracks, output_path: []const u8) !void {
    try ensureDistinctOutput(io, output_path, &.{ tracks.system_path, tracks.microphone_path });
    const temporary_path = try temporaryPathWithExtension(gpa, io, output_path, "mix", ".m4a");
    defer gpa.free(temporary_path);
    defer deleteIfPresent(io, temporary_path);
    try runMix(gpa, io, tracks, &aac_output, temporary_path);
    try requireNonemptyFile(io, temporary_path);
    try publishNewFile(io, temporary_path, output_path);
}

/// Runs local whisper.cpp and atomically publishes a nonempty transcript.
pub fn transcribeRecording(gpa: Allocator, io: Io, audio_path: []const u8, model_path: []const u8, transcript_path: []const u8) !void {
    try ensureDistinctOutput(io, transcript_path, &.{ audio_path, model_path });
    try requireNonemptyFile(io, audio_path);
    if (!isNonemptyFile(io, model_path)) return error.ModelNotFound; // models are often symlinked
    const wav_path = try temporaryPathWithExtension(gpa, io, transcript_path, "whisper-input", ".wav");
    defer gpa.free(wav_path);
    defer deleteIfPresent(io, wav_path);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "ffmpeg", "-nostdin", "-y", "-i", audio_path });
    try argv.appendSlice(gpa, &whisper_input_output);
    try argv.append(gpa, wav_path);
    try runCommand(gpa, io, argv.items);
    const generated = try runWhisper(gpa, io, model_path, wav_path, transcript_path, true);
    defer gpa.free(generated);
    try requireNonemptyFile(io, generated);
    try publishNewFile(io, generated, transcript_path);
}

/// Mixes one live chunk pair straight to whisper input (no AAC step) and returns its text, possibly empty for silence.
pub fn transcribeLiveChunk(gpa: Allocator, io: Io, tracks: AudioTracks, model_path: []const u8, scratch_path: []const u8) ![]u8 {
    const wav_path = try temporaryPathWithExtension(gpa, io, scratch_path, "live-input", ".wav");
    defer gpa.free(wav_path);
    defer deleteIfPresent(io, wav_path);
    try runMix(gpa, io, tracks, &whisper_input_output, wav_path);
    const generated = try runWhisper(gpa, io, model_path, wav_path, scratch_path, false);
    defer gpa.free(generated);
    defer deleteIfPresent(io, generated);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, generated, gpa, .limited(1024 * 1024));
    defer gpa.free(text);
    return cleanWhisperText(gpa, text);
}

/// Joins whisper's output lines into one line, dropping non-speech markers such as `[BLANK_AUDIO]` or `(soft music)`.
pub fn cleanWhisperText(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if ((line[0] == '[' and line[line.len - 1] == ']') or (line[0] == '(' and line[line.len - 1] == ')')) continue;
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn runMix(gpa: Allocator, io: Io, tracks: AudioTracks, output_args: []const []const u8, output_path: []const u8) !void {
    const offset_seconds = @as(f64, @floatFromInt(@abs(tracks.microphone_offset_ns))) / std.time.ns_per_s;
    const offset_arg = try std.fmt.allocPrint(gpa, "{d:.9}", .{offset_seconds});
    defer gpa.free(offset_arg);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    if (tracks.microphone_offset_ns >= 0)
        try argv.appendSlice(gpa, &.{ "ffmpeg", "-nostdin", "-y", "-i", tracks.system_path, "-itsoffset", offset_arg, "-i", tracks.microphone_path })
    else
        try argv.appendSlice(gpa, &.{ "ffmpeg", "-nostdin", "-y", "-itsoffset", offset_arg, "-i", tracks.system_path, "-i", tracks.microphone_path });
    try argv.appendSlice(gpa, &.{ "-filter_complex", mix_filter, "-map", "[a]" });
    try argv.appendSlice(gpa, output_args);
    try argv.append(gpa, output_path);
    try runCommand(gpa, io, argv.items);
}

/// Runs whisper-cli on 16 kHz WAV input; final transcripts retain session timestamps for time-window queries.
fn runWhisper(gpa: Allocator, io: Io, model_path: []const u8, wav_path: []const u8, output_near: []const u8, timestamped: bool) ![]u8 {
    const prefix = try temporarySiblingPath(gpa, io, output_near, "whisper-output");
    defer gpa.free(prefix);
    const generated = try std.fmt.allocPrint(gpa, "{s}.txt", .{prefix});
    errdefer gpa.free(generated);
    errdefer deleteIfPresent(io, generated);
    if (timestamped) {
        const output = try runCommandOutput(gpa, io, &.{ "whisper-cli", "-np", "-m", model_path, "-f", wav_path });
        defer gpa.free(output);
        try writeFileAtomically(gpa, io, generated, output, false);
    } else {
        try runCommand(gpa, io, &.{ "whisper-cli", "-np", "-m", model_path, "-f", wav_path, "-otxt", "-of", prefix });
    }
    return generated;
}

/// Runs a processing command, discarding successful stdout.
pub fn runCommand(gpa: Allocator, io: Io, argv: []const []const u8) !void {
    gpa.free(try runCommandOutput(gpa, io, argv));
}

fn runCommandOutput(gpa: Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    errdefer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("hushpin processing command {s} failed:\n{s}\n", .{ argv[0], result.stderr });
        return error.ProcessingCommandFailed;
    }
    return result.stdout;
}

pub fn ensureDistinctOutput(io: Io, output: []const u8, inputs: []const []const u8) !void {
    for (inputs) |input| if (std.mem.eql(u8, output, input)) return error.OutputMatchesInput;
    if (pathExists(io, output)) return error.OutputAlreadyExists;
}

pub fn temporarySiblingPath(gpa: Allocator, io: Io, output: []const u8, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.{s}.{d}.tmp", .{ output, label, Io.Clock.real.now(io).nanoseconds });
}

fn temporaryPathWithExtension(gpa: Allocator, io: Io, output: []const u8, label: []const u8, extension: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.{s}.{d}.tmp{s}", .{ output, label, Io.Clock.real.now(io).nanoseconds, extension });
}

pub fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

pub fn isNonemptyFile(io: Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file and stat.size > 0;
}

pub fn requireNonemptyFile(io: Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    if (try file.length(io) == 0) return error.EmptyOutput;
}

pub fn deleteIfPresent(io: Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Writes owner-only bytes and renames them into place, replacing `destination` only when `replace` is set.
pub fn writeFileAtomically(gpa: Allocator, io: Io, destination: []const u8, bytes: []const u8, replace: bool) !void {
    if (!replace and pathExists(io, destination)) return error.OutputAlreadyExists;
    const temporary_path = try temporarySiblingPath(gpa, io, destination, "write");
    defer gpa.free(temporary_path);
    defer deleteIfPresent(io, temporary_path);
    var file = try std.Io.Dir.cwd().createFile(io, temporary_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temporary_path, .cwd(), destination, io);
}

fn publishNewFile(io: Io, temporary_path: []const u8, destination: []const u8) !void {
    if (pathExists(io, destination)) return error.OutputAlreadyExists;
    try std.Io.Dir.cwd().rename(temporary_path, .cwd(), destination, io);
}

test "whisper text joins speech lines and drops non-speech markers" {
    const gpa = std.testing.allocator;
    const text = try cleanWhisperText(gpa, " Does the recorder support\n audio export?\n\n [BLANK_AUDIO]\n (soft music)\n");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Does the recorder support audio export?", text);
    const silence = try cleanWhisperText(gpa, "\n [BLANK_AUDIO]\n");
    defer gpa.free(silence);
    try std.testing.expectEqual(@as(usize, 0), silence.len);
}

test "mix publishes new output and refuses to replace it" {
    const io = std.testing.io; // carries the environment, so ffmpeg resolves through PATH
    const gpa = std.testing.allocator;
    const dir = ".zig-cache/hushpin-mix-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const system = dir ++ "/system.wav";
    const microphone = dir ++ "/microphone.wav";
    runCommand(gpa, io, &.{ "ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", system }) catch return error.SkipZigTest;
    try runCommand(gpa, io, &.{ "ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=220:duration=1", microphone });
    const output = dir ++ "/mixed.m4a";
    try mixRecording(gpa, io, .{ .system_path = system, .microphone_path = microphone }, output);
    try std.testing.expect(isNonemptyFile(io, output));
    try std.testing.expectError(error.OutputAlreadyExists, mixRecording(gpa, io, .{ .system_path = system, .microphone_path = microphone }, output));
}
