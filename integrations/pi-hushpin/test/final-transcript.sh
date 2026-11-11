#!/bin/bash
# Synthetic speech checks the built CLI's final transcript and the Pi reader, without capturing microphone or system audio.
set -euo pipefail
cd "$(dirname "$0")/../../.."
model=${1:-"$HOME/.local/share/whisper.cpp/ggml-base.en.bin"}
work=$(mktemp -d "${TMPDIR:-/tmp}/hushpin-final-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
say -o "$work/question.aiff" 'They use local files. What is the opening time for the museum?'
zig-out/Hushpin.app/Contents/MacOS/hushpin transcribe "$work/question.aiff" "$model" "$work/transcript.txt"
node --input-type=module - "$work" <<'JS'
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { queryHushpinTranscript } from './integrations/pi-hushpin/hushpin-transcript.ts';
const directory = process.argv[2];
writeFileSync(`${directory}/session.json`, JSON.stringify({
  session_id: 'synthetic-check', capture: 'stopped', live: 'disabled', final: 'complete', owner_pid: 0,
  processed_audio_end_ms: 0, pending_audio_ms: 0, capture_error: null, live_error: null, final_error: null,
}));
const result = await queryHushpinTranscript(directory, { search: 'opening', context: 0 });
assert.equal(result.source, 'final');
assert.equal(result.lines.length, 1);
assert.match(result.lines[0], /^\[0:00\].*opening/i);
assert.notEqual(result.transcript_through, '0:00');
assert.deepEqual(result.warnings, []);
console.log('PASS: built CLI preserves final timestamps; Pi tool searches and cites them.');
JS
