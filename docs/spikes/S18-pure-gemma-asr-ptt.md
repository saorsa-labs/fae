# Spike S18 — Pure Gemma ASR + push-to-talk (chain simplification)

> **Status:** Executing (2026-06-11)
> **Owner mandate:** Speaker detect and barge-in are not working well — bypass
> both for now (rethink later). Interaction becomes deliberate: **click the
> orb to speak** (plus a configurable keyboard combo in Settings). Audio goes
> **directly to Gemma 4 E4B** via the daemon — no Qwen3-ASR. One model:
> ASR + reasoning + tool calling; only TTS remains separate.

## The simplified chain

```
click orb / hotkey ─→ mic capture (16 kHz) ─→ release/click-again or
silence endpoint ─→ WAV ─→ fae-daemon (Gemma 4 E4B audio-in, tools)
─→ { [heard] transcript line + response text | tool_calls }
─→ TTS (Kokoro) ─→ speaker
```

Bypassed in PTT mode (NOT deleted — flagged off, rethink later): continuous
VAD gating, speaker verification gate, wake word, echo suppression, barge-in,
keyword spotter. Voice-identity enrollment/UI remain; the *gate* is bypassed
because capture is now a deliberate physical act by the person at the machine.

## Engine (crates/) — APIs confirmed against the v0.8.3 checkout

- `ChatMessage` gains `audio_wav_base64: Option<String>` (None for normal
  text turns; protocol field `audio_wav_base64` on rich `messages[]` entries;
  `#[serde(default)]`-style optional in `parse_message`).
- mistral.rs mapping (all verified in the pinned ba2f7877 checkout):
  - `mistralrs::AudioInput::from_bytes(&[u8]) -> Result<Self>`
    (`mistralrs-audio/src/lib.rs:45`) — decode base64 → bytes → AudioInput,
    **no temp files**.
  - `RequestBuilder::add_audio_message(role, text, vec![clip])`
    (`mistralrs/src/messages.rs:287`) — replaces `add_message` for messages
    carrying audio. **Composes with `set_tools`/`ToolChoice::Auto`** — the
    S13 harness ran audio + tools in one request (`bench/mistralrs-eval/
    src/main.rs:138-149`).
- `build_request` in `fae-engine/src/mistralrs_adapter.rs`: when a message
  has audio, base64-decode (reject malformed → `EngineError::Inference`),
  `AudioInput::from_bytes`, `add_audio_message`; else `add_message` as today.
- Mock adapter echoes `[audio:<n> bytes]` for protocol tests; session tests
  cover the new payload field (valid, malformed base64, audio+tools).
- Payload size: WAV at 16 kHz mono 16-bit ≈ 32 KB/s; a 30 s utterance ≈
  1 MB → ~1.3 MB base64. **Raise the daemon's NDJSON frame limit** (currently
  sub-kilobyte control frames, `transport.rs` MAX frame const) to 8 MB for
  authenticated `conversation.inject_text` frames only.

## Execution order (next session)

1. Engine: `ChatMessage.audio_wav_base64` + adapter mapping + frame-limit
   bump + tests (`cargo nextest run` in crates/).
2. Standalone proof: extend `/tmp/fae_toolcall_test.py` pattern — record or
   synthesize a short WAV ("what is on my calendar today?"), send via rich
   payload, assert `[heard]:` transcript line + calendar tool call.
3. Swift agent task: PTT mode + orb click + hotkey + [heard] handling (spec
   below).
4. `just run-dev` live test: click orb, speak, hear answer; commit per phase.

## Empirical findings (standalone proof, 2026-06-11)

Proven live (`/tmp/s18_audio_test.py`, daemon + Gemma 4 E4B Metal): one
request carrying WAV audio + tool schemas returns the `[heard]:` verbatim
transcription line **and** a native calendar tool call with the correct ISO
date, in 2.7–5.9 s/turn. Two gotchas found and fixed:

1. **The audio user message must have EMPTY text content.** Any placeholder
   text ("(audio message)", instructions, anything) wins over the audio —
   Gemma transcribes the text instead of listening. The `[heard]`
   instruction lives in the system prompt only.
2. **mistral.rs prefix cache corrupts audio turns.** Cache hits across
   consecutive multimodal prompts produced "heard nothing"/instant-empty
   replies. Disabled via `with_prefix_cache_n(None)` in both adapter load
   paths (correct over fast).
3. Gemma leaks raw tool-call markup (`<|tool_call>call:...`) into the text
   channel alongside the parsed `tool_calls` array — Swift must drop
   everything from the first tool-call marker before TTS.

## Transcript contract (the design wrinkle, decided)

Audio-direct means Gemma answers without separately emitting the user's
words, but memory capture, the transcript panel, and correction learning all
consume user text. **V1 contract:** the system prompt instructs Gemma to
begin every audio-turn reply with one line:

```
[heard]: <verbatim transcription of the user's speech>
```

Swift strips that line: it becomes the user-turn transcript (memory capture,
panel) and is never spoken. The remainder is the reply. Cheap, robust enough
for v1; revisit if transcription fidelity needs a dedicated pass.

## Swift (agent-executed)

1. Config: `voice.pushToTalkOnly: Bool` (v1 default **true** in dev),
   `voice.pttHotkey: String?` (Settings: recordable combo via
   GlobalHotkeyManager, which already has PTT machinery).
2. PTT capture mode in PipelineCoordinator: between talk-start and endpoint
   (click again, hotkey release, or 1.2 s silence via existing VAD as a plain
   endpointer), buffer mic audio; skip speaker gate, wake word, echo
   suppressor, barge-in. Generate via daemon rich payload with
   `audio_wav_base64` on the user message — **content must be the empty
   string** (see Empirical findings); the [heard] instruction goes in the
   system prompt.
3. Orb host: left-click on orb body = talk toggle (emits
   `{"type":"menu","action":"talk_toggle"}` bridge event; messages bead hit
   keeps its panel). Window move becomes **Option+drag**. Orb shows listening
   state while capturing (mode=listening over the existing state bridge).
4. Transcript: strip `[heard]:` line → user message in ConversationController
   + memory capture path; speak only the remainder; tool calls unchanged.
5. MLX/Qwen3-ASR stays in the codebase (fallback when daemon lane is off).

## Post-S18 consolidation queue (the bypassed-stack kill-list)

PTT + Gemma-4-direct makes a slice of the Swift MLX perception stack
historic. For the always-on rethink (queued behind daemon streaming +
cancel):

- **Qwen3-ASR** — redundant in the PTT path; survives only as MLX-lane
  fallback.
- **SmartTurn** — endpointing is now click/release/1.2 s silence; never runs.
- **Keyword spotter (1D-CNN)** — served acoustic barge-in, which is bypassed;
  if the rethink lands on a button/key interrupt it never returns.
- **Speaker ID (WeSpeaker)** — gray zone: locally PTT collapses identity to
  physical access, but channels/guest flows still reference voice identity.
  Decide at the rethink, don't auto-delete.
- **SmolVLM2-500M (deep)** — consolidation bait: on-demand analysis is
  exactly the daemon's request shape; route deep vision through Gemma 4 and
  delete.
- **SmolVLM2-256M (fast)** — KEEP for now: always-on presence triage at
  19–30 s cadence is a power/thermal budget the 256M model exists to fit,
  and the daemon is single-lane (perception would queue behind turns).
- **Kokoro TTS / Hash-384 embedding** — keep; no Gemma replacement.

## Acceptance

- Click orb → speak → answer spoken, with correct [heard] transcript stored.
- Tool-call-by-voice: "what's on my calendar today?" spoken → calendar tool
  call through the daemon.
- Keyboard combo works after being set in Settings.
- `just build` zero errors; suite stays green (bypassed components' tests
  untouched); daemon tests green; smoke test via run-dev.
