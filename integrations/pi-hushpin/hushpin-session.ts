// Hushpin core consumer contract, read directly from the files the core publishes (no CLI subprocess):
// session.json is the authoritative snapshot and notification source; live-transcript.txt holds stable segments.
import { existsSync, readdirSync, readFileSync, watch, type FSWatcher } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export type CaptureState = "starting" | "recording" | "stopping" | "stopped" | "failed";
export type LiveState = "disabled" | "running" | "draining" | "complete" | "failed";
export type FinalState = "pending" | "running" | "complete" | "failed";

export interface StageError {
	message: string;
	retryable: boolean;
}

/** Mirrors `SessionSnapshot` in src/session-state.zig (schema_version 1). */
export interface SessionSnapshot {
	schema_version: number;
	revision: number;
	session_id: string;
	directory: string;
	owner_pid: number;
	capture: CaptureState;
	microphone: "available" | "unavailable";
	live: LiveState;
	final: FinalState;
	live_chunk_ms: number;
	live_transcript_revision: number;
	last_segment_id: number;
	processed_audio_end_ms: number;
	pending_audio_ms: number;
	artifacts: Record<string, string | null>;
	capture_error: StageError | null;
	live_error: StageError | null;
	final_error: StageError | null;
}

export interface Segment {
	id: number;
	startMs: number;
	endMs: number;
	text: string;
}

export function dataRoot(): string {
	return process.env.HUSHPIN_DATA_DIR ?? join(homedir(), ".local", "share", "hushpin");
}

/** Accepts a session id, a session directory, or nothing (the active capture, else the newest session). */
export function resolveSessionDirectory(session?: string): string {
	const root = dataRoot();
	let directory: string | undefined;
	if (session) directory = session.includes("/") ? resolve(session) : join(root, session);
	else directory = activeSession()?.directory ?? newestSession(root);
	if (!directory || !existsSync(join(directory, ".hushpin-owned"))) {
		throw new Error(session ? `Not a Hushpin session: ${session}` : `No Hushpin sessions in ${root}`);
	}
	return directory;
}

export function activeSession(): { session_id: string; directory: string; owner_pid: number } | undefined {
	try {
		const active = JSON.parse(readFileSync(join(dataRoot(), "active-session.json"), "utf8"));
		const snapshot: SessionSnapshot = JSON.parse(readFileSync(join(active.directory, "session.json"), "utf8"));
		return ["starting", "recording", "stopping"].includes(snapshot.capture) && ownerAlive(snapshot) ? active : undefined;
	} catch {
		return undefined;
	}
}

function newestSession(root: string): string | undefined {
	const names = existsSync(root) ? readdirSync(root).filter((name) => /^recording-\d+-\d+$/.test(name) && existsSync(join(root, name, ".hushpin-owned"))) : [];
	// Names embed the start time in nanoseconds; compare numerically.
	names.sort((a, b) => (BigInt(b.split("-")[1]) > BigInt(a.split("-")[1]) ? 1 : -1));
	return names.length ? join(root, names[0]) : undefined;
}

export async function readSnapshot(directory: string): Promise<SessionSnapshot> {
	return JSON.parse(await readFile(join(directory, "session.json"), "utf8"));
}

const segmentLine = /^\[(\d+) (\d+):(\d{2})\.(\d{3})–(\d+):(\d{2})\.(\d{3})\] (.*)$/;

export function parseLiveTranscript(text: string): { revision: number; segments: Segment[] } {
	const lines = text.split("\n");
	const revision = Number(/ revision=(\d+)$/.exec(lines[0] ?? "")?.[1] ?? 0);
	const segments: Segment[] = [];
	for (const line of lines.slice(1)) {
		const m = segmentLine.exec(line);
		if (!m) continue;
		const ms = (min: string, s: string, milli: string) => Number(min) * 60_000 + Number(s) * 1000 + Number(milli);
		segments.push({ id: Number(m[1]), startMs: ms(m[2], m[3], m[4]), endMs: ms(m[5], m[6], m[7]), text: m[8] });
	}
	return { revision, segments };
}

/** Reads a snapshot and the live transcript revision it names, retrying while the two files disagree. */
export async function readLiveTranscript(directory: string): Promise<{ snapshot: SessionSnapshot; segments: Segment[] }> {
	for (let attempt = 0; attempt < 50; attempt++) {
		const snapshot = await readSnapshot(directory);
		const text = await readFile(join(directory, "live-transcript.txt"), "utf8").catch((error: NodeJS.ErrnoException) => {
			if (error.code === "ENOENT") return "";
			throw error;
		});
		const parsed = parseLiveTranscript(text);
		if (parsed.revision === snapshot.live_transcript_revision) return { snapshot, segments: parsed.segments };
		await new Promise((r) => setTimeout(r, 20));
	}
	throw new Error("Hushpin live transcript and session.json stayed inconsistent; retry the query");
}

export function inProgress(s: SessionSnapshot): boolean {
	return ["starting", "recording", "stopping"].includes(s.capture) || s.live === "running" || s.live === "draining" || s.final === "running";
}

/** True while the recorded owner pid exists. ponytail: pid check, not the core's flock; pid reuse could mask a crash. */
export function ownerAlive(s: SessionSnapshot): boolean {
	if (!s.owner_pid) return false;
	try {
		process.kill(s.owner_pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

/**
 * Invokes `onSnapshot` once per new revision. kqueue (fs.watch) gives low latency; a slow poll covers missed events
 * and detects owner loss. Never mutates session files.
 */
export class SessionWatcher {
	private watcher?: FSWatcher;
	private timer?: NodeJS.Timeout;
	private lastRevision = -1;
	private reading = false;
	private dirty = false;
	private closed = false;
	private lostReported = false;
	private readonly directory: string;
	private readonly onSnapshot: (snapshot: SessionSnapshot) => void | Promise<void>;
	private readonly onOwnerLost: (snapshot: SessionSnapshot) => void;
	private readonly pollMs: number;

	constructor(
		directory: string,
		onSnapshot: (snapshot: SessionSnapshot) => void | Promise<void>,
		onOwnerLost: (snapshot: SessionSnapshot) => void,
		pollMs = 1000,
	) {
		this.directory = directory;
		this.onSnapshot = onSnapshot;
		this.onOwnerLost = onOwnerLost;
		this.pollMs = pollMs;
	}

	start(): void {
		this.watcher = watch(this.directory, (_event, file) => {
			if (!file || file === "session.json") this.check();
		});
		this.watcher.on("error", () => {}); // the poll keeps working
		this.timer = setInterval(() => this.check(true), this.pollMs);
		this.check();
	}

	close(): void {
		this.closed = true;
		this.watcher?.close();
		if (this.timer) clearInterval(this.timer);
	}

	private async check(liveness = false): Promise<void> {
		if (this.reading) {
			this.dirty = true;
			return;
		}
		this.reading = true;
		try {
			do {
				this.dirty = false;
				const snapshot = await readSnapshot(this.directory).catch(() => undefined);
				if (!snapshot || this.closed) continue;
				if (snapshot.revision !== this.lastRevision) {
					this.lastRevision = snapshot.revision;
					await this.onSnapshot(snapshot);
				} else if (liveness && inProgress(snapshot) && !ownerAlive(snapshot)) {
					if (!this.lostReported) this.onOwnerLost(snapshot);
					this.lostReported = true;
				} else if (ownerAlive(snapshot)) {
					this.lostReported = false;
				}
			} while (this.dirty && !this.closed);
		} finally {
			this.reading = false;
		}
	}
}

