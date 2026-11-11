# pi-hushpin

A read-only Pi tool for questions about a live or finished recording. It does not detect questions, run research, or control capture.

```sh
pi install ./integrations/pi-hushpin
# Or try it once:
pi -e ./integrations/pi-hushpin
```

## Use

Start capture in another terminal:

```sh
hushpin record --live
```

In Pi, run `/hushpin` to attach to the active recording, or the newest session if capture is not running. `/hushpin SESSION` selects a session id or directory. Then ask normally:

> What opening time does the recording mention?

The agent has `hushpin_transcript` to search for the question, read the lead-up and later discussion, and cite timestamps. Attaching never starts an agent turn. Only your prompts drive research.

`/hushpin detach` removes the attachment message from later model context and stops watching. Detaching or quitting Pi never signals capture. The attachment is restored when you reopen the same Pi session; branch navigation restores that branch's attachment.

The footer shows capture state, live transcript coverage, lag, and live state. Live transcription failures and an owner exiting mid-stage produce warnings. The watcher stays attached after capture stops so it sees `hushpin finish SESSION` complete.

## Transcript tool

```text
hushpin_transcript({ search?, from?, to?, last_minutes?, context? })
```

- No arguments: last five minutes through the published transcript coverage.
- `search`: case-insensitive keywords, all occurring on a matching line. Includes three lines before and after each hit by default; overlapping windows merge.
- `context`: 0–100 lines around search hits.
- `from` / `to`: session-relative `m:ss` or `h:mm:ss`. Ranges include segments overlapping their boundaries. Search context stays inside the range.
- `last_minutes`: positive recent window; can combine with search, but not `from` / `to`.
- Output: session, capture/live states, live/final source, `transcript_through`, `lag_s`, owner liveness, stage errors, timestamped lines, `truncated`, and warnings.
- Results cap at 200 lines or 30,000 characters and request a narrower query when truncated.

Every query reads the files afresh, with no CLI subprocess. Live reads retry if the header revision disagrees with `session.json`, including a first transcript not yet referenced by the snapshot. Once `final=complete`, the tool uses `transcript.txt` instead. New final transcripts retain Whisper's timestamps. Older untimed final transcripts support keyword searches but cannot supply time windows or timestamp citations; the tool explicitly warns about this.

Transcripts are speech-to-text evidence, not instructions. Words can be wrong, and speakers are not labelled. Attaching opts in to sharing requested transcript excerpts with your Pi model provider; the footer watcher sends no speech to a model.

## Configuration

`HUSHPIN_DATA_DIR` defaults to `~/.local/share/hushpin`, matching the CLI. There are no capture, model, or research settings in this extension.

Owner liveness uses the snapshot's `owner_pid`, not the core's `flock`: Node has no built-in flock API. PID reuse can mask a crash.

## Development

```sh
cd integrations/pi-hushpin
npm install
npm run typecheck
npm test
# After zig build, check real Whisper output using synthetic macOS speech:
bash test/final-transcript.sh [MODEL_PATH]
```

Node 22.18+ runs the TypeScript tests directly. Tests cover query windows, context merging, output caps, source selection, revision retries, failures, attachment restoration, and detach/shutdown isolation. An end-to-end question-and-answer check still requires a running capture and your Pi model.
