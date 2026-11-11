import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { after, test } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import hushpin from "../index.ts";
import { parseLiveTranscript, readLiveTranscript, resolveSessionDirectory, SessionWatcher, type SessionSnapshot } from "../hushpin-session.ts";
import { formatTranscriptTimestamp, queryHushpinTranscript } from "../hushpin-transcript.ts";

const root = mkdtempSync(join(tmpdir(), "pi-hushpin-"));
after(() => rmSync(root, { recursive: true, force: true }));
let nextId = 0;
const transcript = (revision: number, lines: string[]) => `# session=recording-1-0 revision=${revision}\n${lines.join("\n")}\n`;
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function session(): string {
	const directory = join(root, `recording-${++nextId}-0`);
	mkdirSync(directory);
	writeFileSync(join(directory, ".hushpin-owned"), "hushpin recording\n");
	return directory;
}

function publish(directory: string, name: string, bytes: string): void {
	writeFileSync(join(directory, `${name}.tmp`), bytes);
	renameSync(join(directory, `${name}.tmp`), join(directory, name));
}

function snapshot(directory: string, fields: Partial<SessionSnapshot> = {}): void {
	publish(directory, "session.json", JSON.stringify({ schema_version: 1, session_id: basename(directory), directory,
		revision: 1, live_transcript_revision: 0, capture: "recording", microphone: "available", live: "running", final: "pending",
		owner_pid: process.pid, live_chunk_ms: 5000, last_segment_id: 0, processed_audio_end_ms: 0, pending_audio_ms: 0,
		artifacts: {}, capture_error: null, live_error: null, final_error: null, ...fields }));
}

function liveFixture(): string {
	const directory = session();
	const texts = ["They arrived early.", "They use local files.", "What is the opening time for the museum?", "For the weekend.", "We will check.", "Another question.", "More context.", "Later speech.", "Another opening time question.", "The recording continues.", "Last words."];
	publish(directory, "live-transcript.txt", transcript(1, texts.map((text, i) => `[${i + 1} ${String(i).padStart(2, "0")}:00.000–${String(i).padStart(2, "0")}:05.000] ${text}`)));
	snapshot(directory, { live_transcript_revision: 1, processed_audio_end_ms: 605_000, pending_audio_ms: 6250 });
	return directory;
}

test("parses the core's live transcript format", () => {
	const parsed = parseLiveTranscript(transcript(2, ["[1 00:00.000–00:05.000] One", "[2 61:05.000–61:07.250] Two"]));
	assert.equal(parsed.revision, 2);
	assert.deepEqual(parsed.segments[1], { id: 2, startMs: 3665_000, endMs: 3667_250, text: "Two" });
	assert.equal(formatTranscriptTimestamp(3665_000), "1:01:05");
});

test("reader retries mismatched revisions, including unpublished first transcript", async () => {
	for (const initialRevision of [0, 1]) {
		const directory = session();
		snapshot(directory, { revision: 4, live_transcript_revision: initialRevision });
		publish(directory, "live-transcript.txt", transcript(2, ["[1 00:00.000–00:05.000] one", "[2 00:05.000–00:10.000] two"]));
		const timer = setTimeout(() => snapshot(directory, { revision: 5, live_transcript_revision: 2 }), 60);
		try {
			const { snapshot: read, segments } = await readLiveTranscript(directory);
			assert.equal(read.revision, 5);
			assert.deepEqual(segments.map((s) => s.text), ["one", "two"]);
		} finally { clearTimeout(timer); }
	}
});

test("reader rejects a permanently inconsistent transcript", async () => {
	const directory = session();
	snapshot(directory, { live_transcript_revision: 1 });
	publish(directory, "live-transcript.txt", transcript(2, []));
	await assert.rejects(readLiveTranscript(directory), /stayed inconsistent/);
});

test("queries search context, merged windows, time ranges, and default/recent windows", async () => {
	const directory = liveFixture();
	const result = await queryHushpinTranscript(directory, { search: "OPENING time" });
	assert.equal(result.source, "live");
	assert.equal(result.transcript_through, "10:05");
	assert.equal(result.lag_s, 6.25);
	assert.equal(result.lines.length, 11); // overlapping contexts merge
	assert.equal(new Set(result.lines).size, result.lines.length);
	assert.equal((await queryHushpinTranscript(directory, { search: "opening", context: 0 })).lines.length, 2);
	assert.equal((await queryHushpinTranscript(directory)).lines[0], "[5:00] Another question.");
	assert.equal((await queryHushpinTranscript(directory, { last_minutes: 1 })).lines[0], "[9:00] The recording continues.");
	assert.deepEqual((await queryHushpinTranscript(directory, { from: "0:01:00", to: "2:00" })).lines,
		["[1:00] They use local files.", "[2:00] What is the opening time for the museum?"]);
	assert.equal((await queryHushpinTranscript(directory, { search: "no match" })).lines.length, 0);
	assert.equal((await queryHushpinTranscript(directory, { search: "opening", from: "1:00", to: "3:00" })).lines.length, 3);
});

test("caps line count and long lines, asking for a narrower query", async () => {
	const directory = session();
	publish(directory, "live-transcript.txt", transcript(1, Array.from({ length: 220 }, (_, i) => `[${i + 1} 00:00.000–00:05.000] word ${i}`)));
	snapshot(directory, { live_transcript_revision: 1, processed_audio_end_ms: 5000 });
	const result = await queryHushpinTranscript(directory);
	assert.equal(result.lines.length, 200);
	assert.equal(result.truncated, true);
	assert.match(result.warnings.join(" "), /narrow/);
	publish(directory, "live-transcript.txt", transcript(1, [`[1 00:00.000–00:05.000] ${"x".repeat(40_000)}`]));
	const long = await queryHushpinTranscript(directory);
	assert.equal(long.truncated, true);
	assert.equal(long.lines[0].length, 30_000);
});

test("reports live and owner failures and sees fresh speech on later queries", async () => {
	const directory = liveFixture();
	snapshot(directory, { live: "failed", live_error: { message: "model missing", retryable: true }, owner_pid: 2 ** 22 + 12345,
		live_transcript_revision: 1, processed_audio_end_ms: 605_000, pending_audio_ms: 12_000 });
	const result = await queryHushpinTranscript(directory);
	assert.equal(result.live_error?.message, "model missing");
	assert.equal(result.owner_alive, false);
	assert.equal(result.lag_s, 12);
	assert.match(result.warnings.join(" "), /owner exited/);
	publish(directory, "live-transcript.txt", transcript(2, ["[1 12:00.000–12:05.000] New speech"]));
	snapshot(directory, { revision: 2, live_transcript_revision: 2, processed_audio_end_ms: 725_000 });
	assert.deepEqual((await queryHushpinTranscript(directory)).lines, ["[12:00] New speech"]);
});

test("uses final only when complete, including when live files are inconsistent", async () => {
	const directory = liveFixture();
	publish(directory, "transcript.txt", "[00:01:00.000 --> 00:01:05.250] Corrected local files.\n[01:02:00.000 --> 01:02:06.000] Final answer.\n");
	assert.equal((await queryHushpinTranscript(directory)).source, "live");
	snapshot(directory, { capture: "stopped", live: "complete", final: "complete", live_transcript_revision: 99 });
	const result = await queryHushpinTranscript(directory);
	assert.equal(result.source, "final");
	assert.equal(result.transcript_through, "1:02:06");
	assert.equal(result.lag_s, 0);
	assert.deepEqual(result.lines, ["[1:02:00] Final answer."]);
	assert.deepEqual((await queryHushpinTranscript(directory, { search: "local files", context: 0 })).lines, ["[1:00] Corrected local files."]);
	assert.deepEqual((await queryHushpinTranscript(directory, { from: "1:02:00" })).lines, ["[1:02:00] Final answer."]);
});

test("older untimed finals never invent timestamps", async () => {
	const directory = session();
	publish(directory, "transcript.txt", "An older final answer.\n");
	snapshot(directory, { capture: "stopped", live: "disabled", final: "complete" });
	const result = await queryHushpinTranscript(directory);
	assert.equal(result.transcript_through, null);
	assert.deepEqual(result.lines, ["[untimed] An older final answer."]);
	assert.match(result.warnings.join(" "), /no reliable timestamps/);
	await assert.rejects(queryHushpinTranscript(directory, { last_minutes: 5 }), /no timestamps/);
});

test("validates query inputs and handles empty live transcripts", async () => {
	const directory = session();
	snapshot(directory, { live: "disabled" });
	assert.deepEqual((await queryHushpinTranscript(directory)).lines, []);
	for (const query of [{ from: "bad" }, { from: "1:99" }, { from: "1:60:00" }, { from: "2:00", to: "1:00" }, { last_minutes: -1 }, { last_minutes: Infinity }, { context: -1 }, { context: 0.5 }, { search: " " }, { from: "1:00", last_minutes: 2 }]) {
		await assert.rejects(queryHushpinTranscript(directory, query), /Hushpin/);
	}
});

test("auto-attach prefers active capture over newest and ignores stale active owners", async () => {
	const oldRoot = process.env.HUSHPIN_DATA_DIR;
	process.env.HUSHPIN_DATA_DIR = root;
	try {
		const active = session();
		const newest = session();
		snapshot(active);
		snapshot(newest, { capture: "stopped" });
		publish(root, "active-session.json", JSON.stringify({ directory: active, owner_pid: process.pid }));
		assert.equal(resolveSessionDirectory(), active);
		assert.equal(resolveSessionDirectory(basename(newest)), newest);
		snapshot(active, { owner_pid: 2 ** 22 + 12345 });
		assert.equal(resolveSessionDirectory(), newest);
	} finally {
		if (oldRoot === undefined) delete process.env.HUSHPIN_DATA_DIR;
		else process.env.HUSHPIN_DATA_DIR = oldRoot;
	}
});

test("watcher receives atomic file replacements and detects owner loss without writing state", async () => {
	const directory = session();
	snapshot(directory);
	const seen: number[] = [];
	const watcher = new SessionWatcher(directory, (s) => void seen.push(s.revision), () => {}, 10_000);
	try {
		watcher.start();
		await delay(50);
		snapshot(directory, { revision: 2 });
		await delay(200);
		assert.deepEqual(seen, [1, 2]);
	} finally { watcher.close(); }
	snapshot(directory, { revision: 3, owner_pid: 2 ** 22 + 12345 });
	let lost = 0;
	const dead = new SessionWatcher(directory, () => {}, () => { lost++; }, 20);
	try { dead.start(); await delay(150); } finally { dead.close(); }
	assert.equal(lost, 1);
	assert.equal((await queryHushpinTranscript(directory)).capture, "recording");
});

test("extension attaches without starting turns, restores attachment, and detaches without affecting capture", async () => {
	const directory = liveFixture();
	const oldRoot = process.env.HUSHPIN_DATA_DIR;
	process.env.HUSHPIN_DATA_DIR = root;
	publish(root, "active-session.json", JSON.stringify({ directory, owner_pid: process.pid }));
	const hooks = new Map<string, (event: never, ctx: ExtensionContext) => unknown>();
	const entries: { type: "custom"; customType: string; data: unknown }[] = [];
	const messages: { customType: string; content: string }[] = [];
	const statuses: (string | undefined)[] = [];
	const warnings: string[] = [];
	let command!: Parameters<ExtensionAPI["registerCommand"]>[1];
	let tool!: Parameters<ExtensionAPI["registerTool"]>[0];
	const pi = {
		registerCommand: (_name: string, definition: typeof command) => { command = definition; },
		registerTool: (definition: typeof tool) => { tool = definition; },
		on: (name: string, handler: (event: never, ctx: ExtensionContext) => unknown) => { hooks.set(name, handler); },
		appendEntry: (customType: string, data: unknown) => { entries.push({ type: "custom", customType, data }); },
		sendMessage: (message: typeof messages[number], options: { triggerTurn: boolean }) => { assert.equal(options.triggerTurn, false); messages.push(message); },
	} as unknown as ExtensionAPI;
	const ctx = { ui: { setStatus: (_key: string, status: string | undefined) => statuses.push(status), notify: (message: string) => warnings.push(message) },
		sessionManager: { getBranch: () => entries } } as unknown as ExtensionCommandContext;
	const invoke = (name: string, event: unknown = {}) => hooks.get(name)!(event as never, ctx);
	const context = async () => await invoke("context", { messages: messages.map((message) => ({ role: "custom", ...message })) }) as { messages: unknown[] };
	try {
		hushpin(pi);
		await command.handler("", ctx);
		assert.equal(messages.length, 1);
		assert.equal((await context()).messages.length, 1);
		assert.match(statuses.at(-1)!, /hushpin recording.*live 10:05.*lag 6s/);
		assert.equal(tool.name, "hushpin_transcript");
		const result = await tool.execute("test", { search: "opening", context: 0 }, undefined, undefined, ctx);
		assert.match(JSON.stringify(result.content), /the museum/);
		await invoke("session_shutdown");
		assert.equal((await context()).messages.length, 0);
		await invoke("session_start");
		assert.equal((await context()).messages.length, 1);
		assert.equal(entries.length, 1); // restoration persists no extra state
		await command.handler("detach", ctx);
		assert.equal((await context()).messages.length, 0);
		assert.equal(statuses.at(-1), undefined);
		await assert.rejects(tool.execute("test", {}, undefined, undefined, ctx), /not attached/);
		await invoke("session_start");
		assert.equal((await context()).messages.length, 0);
		assert.equal((await queryHushpinTranscript(directory)).capture, "recording");
		assert.equal(process.kill(process.pid, 0), true);
	} finally {
		await invoke("session_shutdown");
		if (oldRoot === undefined) delete process.env.HUSHPIN_DATA_DIR;
		else process.env.HUSHPIN_DATA_DIR = oldRoot;
	}
});
