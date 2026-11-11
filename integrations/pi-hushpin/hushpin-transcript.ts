import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { inProgress, ownerAlive, readLiveTranscript, readSnapshot, type Segment } from "./hushpin-session.ts";

/** Transcript query times are relative to the recording, not wall-clock time. */
export interface TranscriptQuery {
	search?: string;
	from?: string;
	to?: string;
	last_minutes?: number;
	context?: number;
}

/** Formats session-relative milliseconds for timestamp citations. */
export function formatTranscriptTimestamp(ms: number): string {
	const seconds = Math.floor(ms / 1000);
	const minutes = Math.floor(seconds / 60);
	return minutes < 60 ? `${minutes}:${String(seconds % 60).padStart(2, "0")}`
		: `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

function parseQueryTime(value: string): number {
	if (!/^(?:\d+:)?\d+:\d{2}$/.test(value)) throw new Error("Hushpin query time must be m:ss or h:mm:ss");
	const parts = value.split(":").map(Number);
	if (parts.at(-1)! >= 60 || (parts.length === 3 && parts[1] >= 60)) throw new Error("Hushpin query time has invalid minutes or seconds");
	const ms = parts.reduce((total, part) => total * 60 + part, 0) * 1000;
	if (!Number.isSafeInteger(ms)) throw new Error("Hushpin query time is too large");
	return ms;
}

// New final transcripts retain whisper's timestamped stdout. Also accept compact timestamped fixtures.
function parseFinalTranscript(text: string): { segments: Segment[]; timed: boolean } {
	const segments: Segment[] = [];
	let timed = true;
	for (const line of text.split(/\r?\n/).filter((line) => line.trim())) {
		const match = /^\[((?:\d+:)?\d+:\d{2})(?:[.,](\d{3}))?(?:\s*-->\s*((?:\d+:)?\d+:\d{2})[.,](\d{3}))?\]\s*(.*)$/.exec(line);
		if (match) {
			const startMs = parseQueryTime(match[1]) + Number(match[2] ?? 0);
			const endMs = match[3] ? parseQueryTime(match[3]) + Number(match[4]) : startMs;
			segments.push({ id: segments.length + 1, startMs, endMs, text: match[5] });
		} else {
			timed = false;
			segments.push({ id: segments.length + 1, startMs: 0, endMs: 0, text: line.trim() });
		}
	}
	return { segments, timed };
}

/** Reads fresh transcript files on every query; mismatched live revisions are never returned. */
export async function queryHushpinTranscript(directory: string, query: TranscriptQuery = {}) {
	const { search, from, to, last_minutes, context = 3 } = query;
	if (!Number.isInteger(context) || context < 0 || context > 100) throw new Error("Hushpin context must be an integer from 0 to 100");
	if (search !== undefined && !search.trim()) throw new Error("Hushpin search must contain keywords");
	if (last_minutes !== undefined && (!Number.isFinite(last_minutes) || last_minutes <= 0)) throw new Error("Hushpin last_minutes must be positive and finite");
	if (last_minutes !== undefined && (from !== undefined || to !== undefined)) throw new Error("Hushpin use last_minutes or from/to, not both");
	let start = from === undefined ? 0 : parseQueryTime(from);
	const end = to === undefined ? Infinity : parseQueryTime(to);
	if (start > end) throw new Error("Hushpin from must not be after to");

	let snapshot = await readSnapshot(directory);
	let segments: Segment[];
	let timed = true;
	segments = [];
	if (snapshot.final !== "complete") ({ snapshot, segments } = await readLiveTranscript(directory));
	const source = snapshot.final === "complete" ? "final" : "live";
	if (source === "final") ({ segments, timed } = parseFinalTranscript(await readFile(join(directory, "transcript.txt"), "utf8")));
	const throughMs = source === "live" ? snapshot.processed_audio_end_ms : segments.reduce((end, segment) => Math.max(end, segment.endMs), 0);
	const warnings: string[] = [];
	if (!timed) {
		warnings.push("This older final transcript has no reliable timestamps. Do not invent timestamp citations; time windows are unavailable.");
		if (from !== undefined || to !== undefined || last_minutes !== undefined) throw new Error("Hushpin final transcript has no timestamps; use a keyword search instead of a time window");
	}
	const recent = last_minutes ?? (search === undefined && from === undefined && to === undefined ? 5 : undefined);
	if (timed && recent !== undefined) start = Math.max(0, throughMs - recent * 60_000);
	const keywords = search?.toLowerCase().trim().split(/\s+/);
	const selected = new Set<number>();
	for (let i = 0; i < segments.length; i++) {
		const segment = segments[i];
		if (timed && (segment.endMs < start || segment.startMs > end)) continue;
		if (keywords && !keywords.every((word) => segment.text.toLowerCase().includes(word))) continue;
		for (let j = Math.max(0, i - (keywords ? context : 0)); j <= Math.min(segments.length - 1, i + (keywords ? context : 0)); j++) {
			if (!timed || (segments[j].endMs >= start && segments[j].startMs <= end)) selected.add(j);
		}
	}
	const lines: string[] = [];
	let characters = 0;
	let truncated = false;
	for (const index of [...selected].sort((a, b) => a - b)) {
		const segment = segments[index];
		const line = `[${timed ? formatTranscriptTimestamp(segment.startMs) : "untimed"}] ${segment.text}`;
		// Bound long speech segments as well as line count; no unbounded tool results.
		const remaining = 30_000 - characters;
		if (lines.length === 200 || remaining <= 0) { truncated = true; break; }
		lines.push(line.slice(0, remaining));
		characters += line.length + 1;
		if (line.length > remaining) { truncated = true; break; }
	}
	if (truncated) warnings.push("Transcript output truncated; narrow the keyword search or time window.");
	const owner_alive = ownerAlive(snapshot);
	if (inProgress(snapshot) && !owner_alive) warnings.push("The session owner exited mid-stage; transcript coverage is incomplete.");
	for (const stage of ["capture", "live", "final"] as const) {
		if (snapshot[stage] === "failed") warnings.push(`${stage} failed: ${snapshot[`${stage}_error`]?.message ?? "unknown error"}`);
	}
	if (source === "live" && snapshot.live === "disabled") warnings.push("Live transcription is disabled; run hushpin finish outside Pi after capture stops.");
	return {
		session: snapshot.session_id, capture: snapshot.capture, live: snapshot.live, source,
		transcript_through: timed ? formatTranscriptTimestamp(throughMs) : null,
		lag_s: source === "final" ? 0 : snapshot.pending_audio_ms / 1000,
		owner_alive, capture_error: snapshot.capture_error, live_error: snapshot.live_error, final_error: snapshot.final_error,
		lines, truncated, warnings,
	};
}
