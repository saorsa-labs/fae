# Mega-prompt — voice spine V3: daemon-owned TTS playback + barge-in (handoff 2026-06-16)

Paste into a fresh session. Self-contained, but **verify every claim against the repo and real
command output** — dev-agents on this project have fabricated completion reports (0 tool calls,
invented diffs). The main session that wrote this is the REVIEWER and will gate each part on
**verbatim evidence** (diff-stat, test tails, live socket transcripts). No "done" without it.

---

## Objective

Make the **daemon own TTS playback** so the orb can ride Fae's voice **in Rust** (cross-platform),
not via the Swift adapter. This is gap **D5 / voice-spine V3** in
`docs/architecture/open-gaps-2026-06-16.md`. Owner decision (2026-06-16): the macOS cutover ships
**behind a flag** (`FAE_DAEMON_PLAYBACK`) — the existing Swift playback path stays the default until
V3 proves out.

Split into two parts; **V3a is the primary deliverable** (pure Rust, no macOS hot-path risk, fully
verifiable). V3b is the gated macOS cutover (HIGH risk — barge-in + pipeline state).

---

## Where we are (branch `llamacpp-serving-adapter`, pushed)

V1 + V2 of the voice spine are landed, verified, committed, pushed.

- **V1 (commit 06f000a1) — level-emitting playback.** `crates/fae-audio/src/lib.rs`:
  `AudioManager::play_wav_streaming(wav, level: std::sync::mpsc::Sender<f32>) -> AudioResult<u64>`.
  The cpal output callback feeds a windowed `RmsMeter` (~50 ms) and streams the playback RMS
  envelope (0.0–1.0) on `level`. **It is BLOCKING** (`play_wav_inner` loops `while !done { sleep }`,
  ~line 416) and runs on the single-threaded `AudioWorker` (~line 162) — so a play blocks the worker
  (can't capture or stop mid-clip). `play_wav` is the no-level path. Example:
  `crates/fae-audio/examples/play_level.rs`.
- **V2 (commit 086f8024) — server-push event channel.** `crates/fae-daemon/src/events.rs`:
  `EventBus` (`subscribe(Weak<dyn EventSink>, HashSet<Scope>)`, `publish(event, required: Scope,
  payload)`, Weak-ref auto-prune, per-event scope filter); `ConnSink` = a per-connection **writer
  task** through which ALL outbound bytes serialize (no mid-frame interleave). control-plane
  `Event { v, event, payload }` wire type (demuxable from `Response` by the `event` key).
  `conversation.subscribe` (ConversationRead) is implemented in `session.rs` dispatch; the transport
  registers the connection's sink on a successful subscribe (`transport.rs` handle_connection).
  **`EventBus::publish` is `#[allow(dead_code)]` until V3 wires the first producer** — removing that
  annotation when you call it is the V3a tell.

The `EventBus` is created in `main.rs` and passed to `serve_unix`. It is NOT yet in
`SessionBackends` (`session.rs` ~line 30: `{ engine, tts, audio }`) — V3a must thread it there so
the dispatch can publish.

Full status: `docs/architecture/open-gaps-2026-06-16.md` §D5 (the V1–V5 staging table). Memory:
`reference_orb_static_when_finished`.

---

## Current TTS / playback / orb flow (what V3b changes)

Today, per `CLAUDE.md`:
1. Swift LLM turn → answer text → `ML/DaemonTTSEngine.swift` calls daemon **`tts.synthesize`**
   (`session.rs` `synthesize_tts` ~line 508 → `tts.synthesize` → returns 24 kHz 16-bit PCM WAV).
   DaemonTTSEngine uses a **second socket connection** (TTS must not queue behind minutes-long LLM
   turns).
2. Swift plays the returned PCM via **`Audio/AudioPlaybackManager.swift`** (emits `.level(rms:)` →
   `pipeline.audio_level` → `.faeAudioLevel`).
3. `OrbStateBridgeController.handleSpeakingAudioLevel` sets the orb `.speaking` from that RMS;
   `PipelineCoordinator` logs "playback finished" and transitions state; `pttStart` stops playback
   on barge-in.
4. The orb host (`native/rust/fae-ui-shell`) supports a `state.audio` field (→ `bridge_audio`) but
   Swift never sends it — so the orb uses a synthetic breath while speaking, not the real voice.
   (That last hop is **V4**, not V3.)

The daemon ALSO has a dormant **`audio.play {wav}`** command (`session.rs` `audio_play` ~line 474 →
`AudioManager::play_wav`, BLOCKING, no level, AudioPlayback scope) — unused on the macOS path.

---

## V3a — daemon-side playback + level events (primary, pure Rust, verifiable)

Make the daemon play TTS audio and publish its level envelope on the V2 bus. No Swift changes.

### Tasks

1. **Non-blocking, interruptible, level-emitting playback in `fae-audio`.** The current blocking
   `play_wav_streaming` can't support barge-in or concurrent capture. Mirror the **capture pattern**
   (the worker holds active capture streams in a `HashMap` and returns immediately):
   - Add `AudioRequest::PlayStart { wav, level: mpsc::Sender<f32>, reply: Sender<AudioResult<PlaybackId>> }`
     and `AudioRequest::PlayStop { id, reply }`.
   - The worker builds the cpal output stream, stores it in a `playbacks: HashMap<PlaybackId, ...>`
     (like `captures`), returns the id **immediately** (non-blocking). The cpal callback streams RMS
     on `level` (reuse `RmsMeter`) and sets a `done` flag at end-of-samples.
   - `PlayStop` drops the stored stream (stops playback promptly). Reap finished playbacks on the
     worker tick (like `reap_captures`); dropping the stream closes the `level` channel.
   - Public: `AudioManager::play_start(wav, level) -> AudioResult<PlaybackId>` +
     `AudioManager::play_stop(id) -> AudioResult<()>`. Keep `play_wav`/`play_wav_streaming`
     (blocking) for callers that want them.
   - **Tests:** the realtime/window logic stays unit-testable (RmsMeter already is); add a
     hardware example (extend `play_level.rs` or a new one) proving non-blocking start returns
     immediately, levels stream, and `play_stop` halts mid-clip.

2. **Thread `EventBus` into the producer path.** Add `events: &EventBus` to `SessionBackends`
   (`session.rs`); construct it in `transport.rs` `handle_connection` (it already has `&EventBus`).
   This lets `dispatch` publish. (handle_frame stays otherwise pure; the bus is a backend like
   `audio`.)

3. **`tts.speak` command** — synthesize + play in the daemon, **non-blocking**:
   - `payload: { text, voice?, speed? }` → `tts.synthesize` (await) → `audio.play_start(wav,
     level_tx)` → return `ok { playback_id }` immediately (do NOT block on playback).
   - Spawn a task draining `level_rx`: for each RMS, `events.publish("audio.level",
     Scope::AudioPlayback, json!({ "rms": rms, "playback_id": id }))`. When the channel closes,
     `events.publish("audio.playback_ended", Scope::AudioPlayback, json!({ "playback_id": id,
     "reason": "completed" | "interrupted" }))`.
   - Scope: `AudioPlayback` (add `tts.speak` to `required_scopes` in `control-plane`, alongside
     `tts.synthesize`).
4. **`audio.stop` command** (barge-in) — `payload: { playback_id? }` → `audio.play_stop(id)` (or stop
   all) → the drain task emits `audio.playback_ended { reason: "interrupted" }`. Scope:
   `AudioPlayback`. Add to `required_scopes`.

### Done-criteria (V3a) — the E2E V2 couldn't do

A **subscribed test client** receives the live `audio.level` envelope during a real `tts.speak`:
- Run the daemon (real Kokoro TTS on macOS, or `FAE_TTS=mock` won't produce audio — use the real
  TTS for the level test). Connect, authenticate, `conversation.subscribe`, then on a second frame
  `tts.speak { text: "three quick words" }`. Assert: an `ok { playback_id }` response, then a
  stream of `audio.level` event frames with varying `rms`, then `audio.playback_ended {
  reason: "completed" }`. Then repeat with an `audio.stop` mid-clip → assert `reason: "interrupted"`
  and that levels stop. **Show the verbatim socket transcript.** (Pattern: the V2 live smoke in the
  V2 commit message / `/tmp/daemon_client.py`.)

---

## V3b — macOS cutover behind `FAE_DAEMON_PLAYBACK` (HIGH risk, gated)

Only after V3a is green. **Release-validation contract applies** (TTS/playback change):
`docs/checklists/app-release-validation.md`.

### Tasks

- New config/env flag `FAE_DAEMON_PLAYBACK` (default OFF). When ON:
  - `ML/DaemonTTSEngine.swift` (or the pipeline) routes TTS via **`tts.speak`** instead of
    `tts.synthesize` + local playback. Swift does **not** play the PCM through
    `AudioPlaybackManager`.
  - Swift opens a `conversation.subscribe` stream (it never subscribes today — see the V2 frame
    contract; demux `Event` by the `event` key, do NOT decode events as `Response`) and consumes
    `audio.level` + `audio.playback_ended`.
  - **Barge-in:** a new capture (`pttStart`) sends `audio.stop` to the daemon instead of stopping
    local playback.
  - **Pipeline state:** "playback finished" transitions fire on the `audio.playback_ended` event,
    not on local `AudioPlaybackManager` completion.
- When OFF: the current path is byte-for-byte unchanged (verify no regression).

### Done-criteria (V3b)

Dev app with `FAE_DAEMON_PLAYBACK=1`: a real turn speaks via the daemon (audible), barge-in
(hold ⌥ / new capture) cuts speech promptly, the pipeline returns to idle correctly, and there is
**no dual audio** (Swift not also playing). With the flag OFF, behaviour is identical to today.
Capture a live transcript + the release-validation checklist run.

> **V4 (separate, after V3):** drive the orb's `state.audio` from `audio.level` — on macOS via the
> Swift relay (`RustUiShellController`), on Linux via the orb host subscribing to the daemon
> directly. That is when the orb visibly rides the voice. Do NOT fold V4 into V3.

---

## Gotchas (verified this session — trust these)

- **`env -u RUSTFLAGS`** for ALL crate builds/clippy/tests — vendored candle's unused import breaks
  `-D warnings` (goes away with mistral.rs retirement, gap B4). Validate per crate:
  `cd crates && env -u RUSTFLAGS cargo fmt -p <c> -- --check && cargo clippy -p <c> --all-targets --
  -D warnings && cargo nextest run -p <c>`.
- **`AudioWorker` is single-threaded** (one worker thread, 100 ms tick). A BLOCKING play freezes it
  — hence V3a's non-blocking, stream-holding design (mirror `captures`).
- **`EventBus::publish` scope filter:** a subscriber only receives an event whose `required` scope
  it holds. `audio.level` is `AudioPlayback`; the `SwiftFrontend` grant has both `ConversationRead`
  (to subscribe) and `AudioPlayback` (to receive) — see `ClientClass::default_scopes` in
  control-plane. A client missing `AudioPlayback` subscribes but gets no levels (by design).
- **`Event` vs `Response` demux:** events are `{v, event, payload}` (no `ok`/`request_id`);
  `Response` has `deny_unknown_fields`, so decoding an event as a response FAILS. Branch on the
  `event` key first. The Swift client must do this once it subscribes (V3b) — today it never
  subscribes, so V2 is non-breaking.
- **DaemonTTSEngine uses a second socket connection** — keep TTS off the LLM connection. For V3b the
  event subscription likely wants its own connection too (don't block the subscribe stream behind a
  blocking call).
- **MLX ops crash under `swift test`; QUIT the dev app before local `swift test`.** Rust crate tests
  are fast + safe. The Swift suite is heavy.
- **Verify against `git diff` + real output.** Gate every claim on verbatim evidence.

---

## Files

- `crates/fae-audio/src/lib.rs` (+ `examples/`) — non-blocking play_start/play_stop + level stream.
- `crates/fae-daemon/src/{session.rs, transport.rs, main.rs}` — `tts.speak`/`audio.stop` dispatch,
  `EventBus` into `SessionBackends`, the level→publish drain task.
- `crates/fae-daemon/src/events.rs` — remove the `#[allow(dead_code)]` on `publish` once wired.
- `crates/fae-control-plane/src/lib.rs` — `required_scopes` for `tts.speak` + `audio.stop`.
- (V3b) `native/macos/Fae/Sources/Fae/ML/DaemonTTSEngine.swift`,
  `Pipeline/PipelineCoordinator.swift`, `Audio/AudioPlaybackManager.swift`, config for the flag.

---

## Suggested order

1. V3a fae-audio non-blocking playback (+ example) — verify start/stop/levels.
2. V3a `EventBus` into `SessionBackends` + `tts.speak`/`audio.stop` + the publish drain task.
3. V3a live socket E2E (subscribe → tts.speak → audio.level stream → playback_ended; + interrupt).
   **Commit V3a; this is the natural milestone.**
4. V3b macOS cutover behind `FAE_DAEMON_PLAYBACK` + release-validation. Commit separately.
5. Update `open-gaps-2026-06-16.md` §D5, memory (`reference_orb_static_when_finished`), Obsidian.

Done (V3) when: a daemon `tts.speak` plays audio and streams `audio.level` to a subscriber, with
`audio.stop` barge-in (V3a, verbatim transcript), and the macOS app speaks via the daemon behind
`FAE_DAEMON_PLAYBACK` with working barge-in and no dual audio (V3b). Then the orb is one hop (V4)
from riding the real voice.
