const std = @import("std");
const core = @import("hushpin_core");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("time.h");
});

const Cli = struct {
    rc: *core.RecordingCore,
    io: std.Io,
    /// Process-lifetime scratch for argument rewriting.
    arena: std.mem.Allocator,
    home: []const u8,
    args: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    _ = c.umask(0o077); // recordings and transcripts are private, including files AVAssetWriter creates
    const all_args = try init.minimal.args.toSlice(init.arena.allocator());
    if (all_args.len < 2) return usage();
    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    const data_dir = if (init.environ_map.get("HUSHPIN_DATA_DIR")) |dir| try gpa.dupe(u8, dir) else try std.fs.path.join(gpa, &.{ home, ".local", "share", "hushpin" });
    defer gpa.free(data_dir);
    var recording_core = try core.initRecordingCore(gpa, init.io, data_dir);
    defer core.deinitRecordingCore(&recording_core);
    var cli: Cli = .{ .rc = &recording_core, .io = init.io, .arena = init.arena.allocator(), .home = home, .args = all_args[2..] };
    run(&cli, all_args[1]) catch |err| explainAndExit(&cli, err);
}

fn run(cli: *Cli, command: []const u8) !void {
    const commands = .{
        .{ "record", record },     .{ "capture", capture },       .{ "list", list },
        .{ "watch", watch },       .{ "finish", finish },         .{ "cleanup", cleanup },
        .{ "mix", mix },           .{ "transcribe", transcribe },
    };
    inline for (commands) |entry| if (std.mem.eql(u8, command, entry[0])) return entry[1](cli);
    return usage();
}

fn explainAndExit(cli: *Cli, err: anyerror) noreturn {
    switch (err) {
        error.ModelNotFound => fail("Whisper model not found. Download it to {s}/.local/share/whisper.cpp/ (live: {s}, final: {s}) or pass --live-model/--model PATH. Hushpin never downloads models.\n", .{ cli.home, core.default_live_model_file, core.default_batch_model_file }),
        error.CaptureActive => fail("That session is still capturing. Stop it in its recording process first.\n", .{}),
        error.SessionActive => fail("That session is still owned by a capture or processing process.\n", .{}),
        error.SessionNotFound => fail("No such session. Run hushpin list.\n", .{}),
        error.UnownedSessionDirectory => fail("Not a Hushpin-owned session under {s}.\n", .{cli.rc.data_dir}),
        error.CaptureStartFailed => fail("Capture did not start. Check microphone and screen-recording permission.\n", .{}),
        error.Usage => {
            usage() catch {};
            std.process.exit(2);
        },
        else => fail("hushpin: {s}\n", .{@errorName(err)}),
    }
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

/// Removes `--name VALUE` from args and returns VALUE.
fn takeOption(cli: *Cli, names: []const []const u8) !?[]const u8 {
    for (cli.args, 0..) |arg, index| for (names) |name| if (std.mem.eql(u8, arg, name)) {
        if (index + 1 >= cli.args.len) return error.Usage;
        const value = cli.args[index + 1];
        cli.args = try std.mem.concat(cli.arena, []const u8, &.{ cli.args[0..index], cli.args[index + 2 ..] });
        return value;
    };
    return null;
}

/// Removes a `--flag` from args and reports whether it was present.
fn takeFlag(cli: *Cli, name: []const u8) !bool {
    for (cli.args, 0..) |arg, index| if (std.mem.eql(u8, arg, name)) {
        cli.args = try std.mem.concat(cli.arena, []const u8, &.{ cli.args[0..index], cli.args[index + 1 ..] });
        return true;
    };
    return false;
}

fn noMoreArgs(cli: *Cli) !void {
    if (cli.args.len != 0) return error.Usage;
}

/// Resolves `-s N` (from `hushpin list`), a session id, or a session path; caller owns the directory.
fn takeSession(cli: *Cli) ![]u8 {
    if (try takeOption(cli, &.{ "-s", "--select" })) |value| {
        const number = std.fmt.parseInt(usize, value, 10) catch 0;
        const recordings = try core.getRecentRecordings(cli.rc);
        defer core.deinitRecordings(cli.rc, recordings);
        if (number == 0 or number > recordings.len) fail("No recording {d}. Run hushpin list.\n", .{number});
        return cli.rc.allocator.dupe(u8, recordings[number - 1].directory);
    }
    if (cli.args.len == 0) return error.Usage;
    const session = cli.args[0];
    cli.args = cli.args[1..];
    return core.resolveSessionDirectory(cli.rc, session);
}

fn modelPath(cli: *Cli, option: ?[]const u8, default_file: []const u8) ![]u8 {
    if (option) |path| return cli.rc.allocator.dupe(u8, path);
    return core.defaultModelPath(cli.rc.allocator, cli.home, default_file);
}

fn writeJsonLine(io: std.Io, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(value, .{}, &stdout.interface);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

var interrupted = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

/// SIGINT/SIGTERM interrupt the blocking stdin read (no SA_RESTART) so the owner stops gracefully.
fn installStopSignals() void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn startOwnedSession(cli: *Cli, options: core.SessionOptions) !*core.Session {
    switch (try core.startSession(cli.rc, options)) {
        .started => |session| return session,
        .already_active => |active| {
            defer active.deinit();
            try writeJsonLine(cli.io, active.value);
            fail("A capture is already active: {s} (pid {d}). Attach with: hushpin watch {s} --json\n", .{ active.value.session_id, active.value.owner_pid, active.value.session_id });
        },
    }
}

fn record(cli: *Cli) !void {
    const live = try takeFlag(cli, "--live");
    const chunk_option = try takeOption(cli, &.{"--chunk-seconds"});
    const model_option = try takeOption(cli, &.{"--live-model"});
    try noMoreArgs(cli);
    const chunk_seconds = if (chunk_option) |value| std.fmt.parseFloat(f64, value) catch return error.Usage else 5;
    if (!(chunk_seconds > 0)) return error.Usage;
    const model = try modelPath(cli, model_option, core.default_live_model_file);
    defer cli.rc.allocator.free(model);
    const session = try startOwnedSession(cli, .{ .live = live, .live_chunk_ms = @intFromFloat(chunk_seconds * 1000), .live_model_path = if (live) model else null });
    defer core.deinitSession(session);
    installStopSignals();
    try writeJsonLine(cli.io, session.descriptor());
    std.debug.print("Recording to {s}.\nPress Return or Ctrl-C to stop.{s}\nAttach elsewhere with: hushpin watch {s} --json\n", .{ session.directory, if (live) " Type retry and Return to retry failed live transcription." else "", session.sessionId() });
    var line: [256]u8 = undefined;
    while (!interrupted.load(.acquire)) {
        if (c.fgets(&line, line.len, c.stdin()) == null) {
            // stdin closed (e.g. a background owner): keep recording until a stop signal.
            if (c.feof(c.stdin()) != 0) while (!interrupted.load(.acquire)) {
                _ = c.pause();
            };
            c.clearerr(c.stdin());
            continue;
        }
        const text = std.mem.trim(u8, std.mem.sliceTo(&line, 0), " \t\r\n");
        if (text.len == 0) break;
        if (std.mem.eql(u8, text, "retry")) {
            const state = try core.retryLiveTranscription(session);
            std.debug.print("live: {s}{s}\n", .{ @tagName(state), if (state == .failed) "; retrying" else "" });
        }
    }
    std.debug.print("Stopping{s}...\n", .{if (live) " and draining live transcription" else ""});
    const result = try core.stopSession(session);
    std.debug.print("capture: {s}\nlive: {s}\nsystem: {s}\nmicrophone: {s}\nNext: hushpin finish {s}\n", .{ @tagName(result.capture), @tagName(result.live), result.tracks.system_path, result.tracks.microphone_path, session.sessionId() });
    if (result.capture == .failed) std.process.exit(1);
}

fn capture(cli: *Cli) !void {
    const seconds: u64 = if (cli.args.len > 0) std.fmt.parseInt(u64, cli.args[0], 10) catch return error.Usage else 5;
    if (cli.args.len > 1) return error.Usage;
    const session = try startOwnedSession(cli, .{});
    defer core.deinitSession(session);
    std.debug.print("recording {s} for {d}s\n", .{ session.directory, seconds });
    _ = c.sleep(@intCast(seconds));
    const result = try core.stopSession(session);
    std.debug.print("capture: {s}\nsystem: {s}\nmicrophone: {s}\n", .{ @tagName(result.capture), result.tracks.system_path, result.tracks.microphone_path });
}

fn list(cli: *Cli) !void {
    try noMoreArgs(cli);
    const recordings = try core.getRecentRecordings(cli.rc);
    defer core.deinitRecordings(cli.rc, recordings);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(cli.io, &buffer);
    const out = &stdout.interface;
    if (recordings.len == 0) try out.print("No recordings in {s}\n", .{cli.rc.data_dir});
    const now_ns = std.Io.Clock.real.now(cli.io).nanoseconds;
    for (recordings, 1..) |files, number| try writeRecordingLine(out, number, files, now_ns);
    try out.flush();
}

/// Emits newline-delimited snapshots, initially and on each revision. Exits 2 if the owner dies mid-stage.
fn watch(cli: *Cli) !void {
    _ = try takeFlag(cli, "--json"); // JSON is the only output format
    const directory = try takeSession(cli);
    defer cli.rc.allocator.free(directory);
    try noMoreArgs(cli);
    var subscription = core.subscribeSession(cli.rc, directory);
    while (subscription.next() catch |err| {
        if (err != error.OwnerLost) return err;
        std.debug.print("hushpin watch: the session owner exited while a stage was in progress; capture or processing was interrupted. The last snapshot is unchanged.\n", .{});
        std.process.exit(2);
    }) |snapshot| {
        defer snapshot.deinit();
        try writeJsonLine(cli.io, snapshot.value);
    }
}

/// Takes an optional output path relative to the command directory, defaulting to a session artifact.
fn takeOutputPath(cli: *Cli, directory: []const u8, default_name: []const u8) ![]const u8 {
    if (cli.args.len > 1) return error.Usage;
    if (cli.args.len == 1) {
        const output = cli.args[0];
        cli.args = cli.args[1..];
        return output;
    }
    return std.fs.path.join(cli.arena, &.{ directory, default_name });
}

fn hasSessionSelection(cli: *const Cli) bool {
    for (cli.args) |arg| if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--select")) return true;
    return false;
}

/// Mixes and transcribes into the session, then optionally exports the completed transcript.
fn finish(cli: *Cli) !void {
    const model = try modelPath(cli, try takeOption(cli, &.{"--model"}), core.default_batch_model_file);
    defer cli.rc.allocator.free(model);
    const directory = try takeSession(cli);
    defer cli.rc.allocator.free(directory);
    const output = try takeOutputPath(cli, directory, "transcript.txt");
    const canonical = try std.fs.path.join(cli.arena, &.{ directory, "transcript.txt" });
    const exporting = !std.mem.eql(u8, output, canonical);
    if (exporting) try core.processing.ensureDistinctOutput(cli.io, output, &.{});
    const transcript = try core.finalizeTranscript(cli.rc, directory, .{ .model_path = model });
    defer cli.rc.allocator.free(transcript);
    if (exporting) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(cli.io, transcript, cli.rc.allocator, .limited(64 * 1024 * 1024));
        defer cli.rc.allocator.free(bytes);
        try core.processing.writeFileAtomically(cli.rc.allocator, cli.io, output, bytes, false);
    }
    std.debug.print("transcript: {s}\n", .{output});
}

fn cleanup(cli: *Cli) !void {
    const directory = try takeSession(cli);
    defer cli.rc.allocator.free(directory);
    try noMoreArgs(cli);
    try core.cleanupSessionAudio(cli.rc, directory);
    std.debug.print("removed audio from {s}; transcripts are kept\n", .{directory});
}

fn mix(cli: *Cli) !void {
    const allocator = cli.rc.allocator;
    if (hasSessionSelection(cli)) {
        const directory = try takeSession(cli);
        defer allocator.free(directory);
        const output = try takeOutputPath(cli, directory, "audio/mixed.m4a");
        const system = try std.fs.path.join(allocator, &.{ directory, "audio", "system.caf" });
        defer allocator.free(system);
        const microphone = try std.fs.path.join(allocator, &.{ directory, "audio", "microphone.caf" });
        defer allocator.free(microphone);
        try core.mixRecording(cli.rc, .{ .system_path = system, .microphone_path = microphone }, output);
        std.debug.print("mixed: {s}\n", .{output});
        return;
    }
    if (cli.args.len < 3 or cli.args.len > 4) return error.Usage;
    const offset: i64 = if (cli.args.len == 4) std.fmt.parseInt(i64, cli.args[3], 10) catch return error.Usage else 0;
    try core.mixRecording(cli.rc, .{ .system_path = cli.args[1], .microphone_path = cli.args[0], .microphone_offset_ns = offset }, cli.args[2]);
    std.debug.print("mixed: {s}\n", .{cli.args[2]});
}

fn transcribe(cli: *Cli) !void {
    const allocator = cli.rc.allocator;
    if (hasSessionSelection(cli)) {
        const model = try modelPath(cli, try takeOption(cli, &.{"--model"}), core.default_batch_model_file);
        defer allocator.free(model);
        const directory = try takeSession(cli);
        defer allocator.free(directory);
        const output = try takeOutputPath(cli, directory, "transcript.txt");
        const audio = try std.fs.path.join(allocator, &.{ directory, "audio", "mixed.m4a" });
        defer allocator.free(audio);
        if (!core.processing.isNonemptyFile(cli.io, audio)) fail("{s} has no mixed audio. Run hushpin mix first.\n", .{directory});
        if (!core.processing.isNonemptyFile(cli.io, model)) return error.ModelNotFound;
        try core.transcribeRecording(cli.rc, audio, model, output);
        std.debug.print("transcript: {s}\n", .{output});
        return;
    }
    if (cli.args.len != 3) return error.Usage;
    try core.transcribeRecording(cli.rc, cli.args[0], cli.args[1], cli.args[2]);
    std.debug.print("transcript: {s}\n", .{cli.args[2]});
}

fn localTime(ns: i96) c.struct_tm {
    const seconds: c.time_t = @intCast(@divFloor(ns, std.time.ns_per_s));
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&seconds, &tm);
    return tm;
}

/// Writes one `hushpin list` line, e.g. `1. Today, 12:17pm - system-audio + mic (30m ago)`.
fn writeRecordingLine(out: *std.Io.Writer, number: usize, files: core.RecordingFiles, now_ns: i96) !void {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const started = localTime(files.started_at_ns);
    const now = localTime(now_ns);
    var yesterday = now;
    yesterday.tm_mday -= 1;
    yesterday.tm_hour = 12; // ponytail: noon avoids DST edges when normalizing
    yesterday.tm_isdst = -1;
    _ = c.mktime(&yesterday);
    try out.print("{d}. ", .{number});
    if (started.tm_year == now.tm_year and started.tm_yday == now.tm_yday) {
        try out.writeAll("Today");
    } else if (started.tm_year == yesterday.tm_year and started.tm_yday == yesterday.tm_yday) {
        try out.writeAll("Yesterday");
    } else {
        try out.print("{s} {d}", .{ months[@intCast(started.tm_mon)], started.tm_mday });
        if (started.tm_year != now.tm_year) try out.print(", {d}", .{started.tm_year + 1900});
    }
    const hour12 = if (@mod(started.tm_hour, 12) == 0) 12 else @mod(started.tm_hour, 12);
    try out.print(", {d}:{d:0>2}{s} - ", .{ hour12, @as(u32, @intCast(started.tm_min)), if (started.tm_hour < 12) "am" else "pm" });

    const labels = [_]struct { []const u8, ?[]u8 }{
        .{ "system-audio", files.system_path },
        .{ "mic", files.microphone_path },
        .{ "mixed-audio", files.mixed_path },
        .{ "live-transcript", files.live_transcript_path },
        .{ "transcript", files.transcript_path },
    };
    var any = false;
    for (labels) |label| if (label[1] != null) {
        if (any) try out.writeAll(" + ");
        try out.writeAll(label[0]);
        any = true;
    };
    if (!any) try out.writeAll("empty");

    const age: u64 = @intCast(@max(0, @divFloor(now_ns - files.started_at_ns, std.time.ns_per_s)));
    if (age < 60) try out.print(" ({d}s ago)\n", .{age})
    else if (age < 60 * 60) try out.print(" ({d}m ago)\n", .{age / 60})
    else if (age < 24 * 60 * 60) try out.print(" ({d}h ago)\n", .{age / 3600})
    else try out.print(" ({d}d ago)\n", .{age / 86400});
}

fn usage() !void {
    std.debug.print(
        \\Usage:
        \\  hushpin record [--live] [--chunk-seconds N] [--live-model PATH]
        \\                                         own one capture; prints the session descriptor
        \\  hushpin watch SESSION|-s N [--json]    newline-delimited session snapshots; no audio capture
        \\  hushpin finish SESSION|-s N [OUTPUT] [--model PATH]
        \\                                         mix + transcribe; optionally export the transcript
        \\  hushpin cleanup SESSION|-s N           delete a stopped session's audio; keep text
        \\  hushpin list
        \\  hushpin capture [seconds]
        \\  hushpin mix -s N [OUTPUT] | mix MIC SYSTEM OUTPUT [MIC_OFFSET_NS]
        \\  hushpin transcribe -s N [OUTPUT] [--model PATH] | transcribe AUDIO MODEL OUTPUT
        \\SESSION is a session id (recording-...) or directory; N is a number from hushpin list.
        \\Selected outputs default to the session; explicit paths are relative to this directory.
        \\finish produces a transcript. Existing outputs are not overwritten.
        \\
    , .{});
}

fn localNs(year: c_int, month: c_int, day: c_int, hour: c_int, minute: c_int) i96 {
    var tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    tm.tm_hour = hour;
    tm.tm_min = minute;
    tm.tm_isdst = -1;
    return @as(i96, c.mktime(&tm)) * std.time.ns_per_s;
}

fn expectLine(expected: []const u8, files: core.RecordingFiles, now_ns: i96) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeRecordingLine(&out, 1, files, now_ns);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "list line dates, files, and ages" {
    var directory = "dir".*;
    var path = "p".*;
    const now = localNs(2025, 9, 28, 12, 47);
    var files: core.RecordingFiles = .{ .directory = &directory, .started_at_ns = localNs(2025, 9, 28, 12, 17), .system_path = &path, .microphone_path = &path };
    try expectLine("1. Today, 12:17pm - system-audio + mic (30m ago)\n", files, now);
    files = .{ .directory = &directory, .started_at_ns = localNs(2025, 9, 27, 13, 0), .mixed_path = &path };
    try expectLine("1. Yesterday, 1:00pm - mixed-audio (23h ago)\n", files, now);
    files = .{ .directory = &directory, .started_at_ns = localNs(2025, 9, 18, 15, 0), .transcript_path = &path };
    try expectLine("1. Sep 18, 3:00pm - transcript (9d ago)\n", files, now);
    files = .{ .directory = &directory, .started_at_ns = localNs(2024, 12, 31, 0, 5) };
    try expectLine("1. Dec 31, 2024, 12:05am - empty (271d ago)\n", files, now);
    // Yesterday across a year boundary.
    try expectLine("1. Yesterday, 12:05am - empty (1d ago)\n", files, localNs(2025, 1, 1, 9, 0));

    files = .{ .directory = &directory, .started_at_ns = now };
    const cases = [_]struct { i96, []const u8 }{
        .{ 59, "59s" }, .{ 60, "1m" }, .{ 59 * 60, "59m" }, .{ 60 * 60, "1h" },
        .{ 23 * 3600, "23h" }, .{ 24 * 3600, "1d" }, .{ 3 * 86400, "3d" },
    };
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try writeRecordingLine(&out, 1, files, now + case[0] * std.time.ns_per_s);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "({s} ago)\n", .{case[1]});
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.endsWith(u8, out.buffered(), expected));
    }
}
