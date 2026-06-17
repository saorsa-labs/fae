# Mega-prompt — make daemon-owned TTS playback the DEFAULT (V3b cutover) (2026-06-17)

Paste into a fresh session. Self-contained; **verify every claim against the repo and live output** —
dev-agents have fabricated reports, and static-only review has already missed a release-blocking bug
on this exact feature.

---

## Workflow — read first

**You (the team) implement AND test this to completion, then HAND BACK for review. You do NOT commit
or push.** The owner's reviewer commits + publishes after review.

1. **Build it** per "The work" below, smallest-increment-first ("Suggested order").
2. **Test to completion** — every item in "Done criteria" must pass with **verbatim evidence you
   captured yourself**, not asserted:
   - `git diff --stat` of everything you changed.
   - `cd crates && env -u RUSTFLAGS cargo fmt -p <c> -- --check && cargo clippy -p <c> --all-targets --
     -D warnings && cargo nextest run -p <c>` tails for each touched crate; Swift `swift build` clean.
   - **Live runs** of the bundled dev app driving real turns via `POST http://127.0.0.1:7433/inject`
     (Python urllib — a hook intercepts curl). Capture the orb-host `ORB_MODE` trace + the TTS lane
     used (`tts.speak` vs `tts.synthesize`) from `/tmp/fae-dev.log`. See "Live-run recipe" below.
   - **This is a TTS/playback change → the release-validation contract applies.** Work through
     `docs/checklists/app-release-validation.md` and paste your results.
   - **Heed the BUNDLING TRAP** (gotchas): `just build` alone does NOT update the running app — your
     changes won't take effect until the bundle/embed/sign chain runs. Confirm LIVE behavior, not the
     source diff.
3. **Hand back a report** with all the above evidence + a short summary + any deviations/risks. Then
   STOP — the reviewer validates against the evidence, commits, and publishes. Flag anything you could
   not verify; do not paper over it.

---

## Objective (owner decision 2026-06-17)

Make **daemon-owned TTS playback** the **default on macOS** — flip `FAE_DAEMON_PLAYBACK` from opt-in
to default-on (an opt-OUT kill switch). This is the **V3b cutover** (open-gaps D2/D5,
`docs/architecture/open-gaps-2026-06-16.md`) and it is the **gate that lets the just-landed
orb-host-owns-state series (commit `908485a3`) work for default-config users.**

**Why it's the gate.** orb-host-owns-state retired the Swift orb speaking-driver; the orb host now
derives "speaking" from the daemon's `audio.level` events, which are emitted ONLY by daemon-owned
playback (`tts.speak`). On the current default lane (`tts.synthesize` + Swift-local
`AudioPlaybackManager`) the daemon emits no `audio.level`, so the orb shows **no Speaking**. Flipping
the default closes that gap. (Verified live 2026-06-17: with `FAE_DAEMON_PLAYBACK=1` the orb rides the
voice flicker-free; with it off, the turn went `Thinking → Quiescent` with no Speaking.)

**This is a HIGH-risk cutover** (real audio output path + barge-in). Correctness over speed.

---

## What already exists (build on it — DO NOT rebuild)

Branch `llamacpp-serving-adapter` (pushed through `19413f46`). All of V1–V4b + orb-host-owns-state are
**committed**. The daemon-owned playback path is **code-complete behind the flag** and was just
live-exercised — your job is the **default flip + the fallback-path correctness + release
validation**, not new plumbing.

- **`FAE_DAEMON_PLAYBACK` flag (Swift).** `PipelineCoordinator.readDaemonPlaybackFlag()` (~line 5439)
  reads the env; default **OFF** (`""` → false; ON for `1/true/yes/on`). `useDaemonPlayback` wraps it.
- **Runtime gating.** `daemonPlaybackActive == useDaemonPlayback && (ttsEngine is DaemonTTSEngine) &&
  eventSubscriber != nil` (~line 5450). When false the pipeline **falls back to local Swift playback**
  (so a missing daemon/subscriber never strands the speaking state).
- **Daemon-owned path (flag-ON).** `DaemonTTSEngine.speak(text,voice,speed)` → `tts.speak`;
  `stopPlayback`/PTT-start → `audio.stop`; `DaemonEventSubscriber` (its OWN daemon connection, distinct
  from the LLM/TTS round-trip conns) `conversation.subscribe`s and routes `audio.level`→orb/TTFA and
  `audio.playback_ended{completed|interrupted}`→speech-end. Multi-segment turns serialize via
  `awaitDaemonPlaybackDrained`. `stopAssistantPlaybackForInterrupt()` centralizes interrupt.
- **Orb host bridge is ALREADY default-ON** (`FAE_ORB_DAEMON_AUDIO`, `daemon_audio_bridge.rs`). It
  authenticates as `fae_control_plane::BOOTSTRAP_CLIENT_ID` (the 2026-06-17 reviewer fix — do NOT
  revert to `"fae-ui-shell"`; that was the `UnknownClient` bug) and feeds the `orb_state.rs` grace-hold
  machine. No orb-host change is expected here.

> Note: there are now **two** subscribers to the daemon event stream — Swift's `DaemonEventSubscriber`
> (for TTFA + the local playback-event path) and the orb host's `daemon_audio_bridge` (for orb mode).
> That's fine: `EventBus` fans out to all subscribers. Swift no longer drives orb mode.

---

## The work

### 1. Flip the default (the cutover)
- Make daemon-owned playback the default: `FAE_DAEMON_PLAYBACK` becomes **opt-OUT** —
  default-ON, disabled only by `0/false/off/no`. Keep it as a loud, documented **kill switch** (a bad
  audio regression must be one env var away from the old behavior). Update the doc-comment + any
  CLAUDE.md / config references.
- Confirm the production code-default path (no config.toml) takes the daemon-owned branch.

### 2. No dual audio
- With the default on, the Swift `AudioPlaybackManager` must NOT also play the TTS PCM (the daemon
  plays it). Verify there is exactly ONE audio output during a turn (no echo/doubling). The
  `daemonPlaybackActive` gating should already route correctly — **prove it live** (listen / check the
  log for a single playback path).

### 3. Barge-in / interrupt
- Right-⌥ PTT start (and any interrupt) must cut daemon playback promptly via `audio.stop`, the
  `interrupted` event must clear the playback id, and the orb must leave Speaking → listening/idle
  without stranding. Verify: start a long reply, interrupt mid-sentence, confirm audio stops fast and
  the orb recovers.

### 4. Fallback-path correctness (the important edge)
- When `daemonPlaybackActive` is **false at runtime** — e.g. the in-process **MLX TTS fallback** is
  selected (no `tts.speak`), or the subscriber failed — playback falls back to local Swift
  `AudioPlaybackManager`, which emits **no daemon `audio.level`**. Because the Swift orb
  speaking-driver was retired, **the orb will show no Speaking on that fallback path** (dark-ish
  breathing orb while she actually talks).
- **Decide + implement the simplest safe option, and FLAG it for the reviewer:**
  - (a) **Accept** degraded-orb-on-fallback (it still SPEAKS; fallback is rare = daemon/MLX-only), and
    **log it loudly** when the fallback path is taken so it's diagnosable. *(Recommended — least code,
    no Swift orb-drive resurrection.)*
  - (b) Restore a **minimal** Swift→host speaking signal *only* on the local-fallback path (a narrow,
    clearly-commented exception to the no-Swift-orb-drive principle). Heavier; needs reviewer sign-off.
  - Do NOT silently leave the orb dark with no log — that reads as "works" when it doesn't (Rule 12).
- Either way, **prove the fallback still SPEAKS and never strands** (force it: select the MLX TTS lane
  or make the subscriber fail, run a turn, confirm audio + a clean return to idle).

### 5. Release-validation contract
- Run `docs/checklists/app-release-validation.md` for the playback-change surface and paste results.
- Re-run owner-voice / a few representative turns; confirm TTFA is not regressed vs the flag-off path.

---

## Live-run recipe (how to capture the evidence)

```bash
# Build + embed + sign (NO launch) — the bundling trap: this is what updates the running app.
env -u RUSTFLAGS just build-ui-shell build-daemon build _bundle-app _embed-ui-shell _embed-daemon _sign-bundle _kill-fae

# Launch with logging + test server. RUST_LOG=info surfaces ORB_MODE (orb host stderr → Swift NSLog → log).
# Process inherits the app env, so --env reaches the embedded orb host.
BUNDLE="$PWD/native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app"
SHELL_BIN="$BUNDLE/Contents/MacOS/fae-ui-shell"
# DEFAULT run: do NOT pass FAE_DAEMON_PLAYBACK — prove the NEW default is daemon-owned.
FAE_DEV=1 RUST_LOG=info FAE_UI_SHELL_BIN="$SHELL_BIN" open "$BUNDLE" \
  --stdout /tmp/fae-dev.log --stderr /tmp/fae-dev.log \
  --env FAE_DEV=1 --env RUST_LOG=info --env FAE_UI_SHELL_BIN="$SHELL_BIN" --args --test-server

# Wait for: test server (curl 127.0.0.1:7433 → any HTTP code), daemon socket
# (~/Library/Application Support/fae/run/fae-daemon.sock), and "all models loaded" in the log.
# Inject a multi-sentence turn (urllib — a hook intercepts curl):
python3 -c "import urllib.request,json; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:7433/inject', data=json.dumps({'text':'Tell me a short two-sentence story about the sea.'}).encode(), headers={'Content-Type':'application/json'}), timeout=10)"

# Evidence:
grep "ORB_MODE" /tmp/fae-dev.log                       # expect Quiescent→Thinking→Speaking→Quiescent, no idle-between flips
grep -iE "tts.speak|tts.synthesize|playback finished" /tmp/fae-dev.log  # expect tts.speak (daemon-owned), NOT synthesize
grep -iE "UnknownClient|session ended|Connection refused" /tmp/fae-dev.log | tail  # bridge should be quiet after connect
```

The default-on success signature: a no-flag turn shows **`tts.speak`** (not `tts.synthesize`) and an
`ORB_MODE` trace that reaches **Speaking** flicker-free.

---

## Gotchas

- **Bundling trap.** `just build` runs the compiled Swift but does NOT update the running `.app`. Use
  the full `_bundle-app`/`_embed-*`/`_sign-bundle` chain (or `just run-dev`) — else you'll test a stale
  binary and "fix" things that were never live. This has bitten this feature before.
- **`env -u RUSTFLAGS`** for all crate builds (vendored candle's unused-import breaks `-D warnings`).
- **Do NOT touch the orb-host bridge auth.** It must stay `fae_control_plane::BOOTSTRAP_CLIENT_ID`
  (`"swift-frontend-bootstrap"`). `"fae-ui-shell"` is the `UnknownClient` bug fixed 2026-06-17.
- **QUIT the dev app before any local `swift test`** (live daemons + MLX loads abort the suite; MLX ops
  also crash under `swift test`).
- **Don't strand on a missing end-event.** The whole point of `daemonPlaybackActive`'s subscriber
  check is to fall back rather than hang. Preserve that property when you flip the default.
- **autoresearch.jsonl** is unrelated churn — keep it out of your diff.

---

## Done criteria

1. **Default-on turn (NO `FAE_DAEMON_PLAYBACK` set):** log shows `tts.speak` (daemon-owned), single
   audio output (no dual/echo), and `ORB_MODE` `Quiescent→Thinking→Speaking→Quiescent` with **no
   `thinking→idle→thinking` / `speaking→idle→speaking`** flips. Pasted trace.
2. **Barge-in:** interrupt mid-reply → audio stops promptly, orb leaves Speaking cleanly, no strand.
3. **Fallback path:** forced (MLX TTS lane or subscriber-down) → still SPEAKS, returns to idle, and the
   chosen orb behavior (degraded+logged, or minimal-signal) is implemented and demonstrated.
4. **Kill switch:** `FAE_DAEMON_PLAYBACK=0` restores the old local-playback path (proven live).
5. **Release-validation checklist** worked through with pasted results; TTFA not regressed.
6. **Green:** `swift build`; `env -u RUSTFLAGS` clippy `-D warnings` + nextest for any touched crate.
7. **Hand back** the evidence report (do NOT commit/push). The reviewer validates, commits, and
   updates open-gaps D5/D2 + memory + Obsidian on publish.

---

## Suggested order
1. Flip the default + kill switch (small); rebuild/bundle; default-on live turn → confirm `tts.speak`
   + flicker-free Speaking. 2. No-dual-audio check. 3. Barge-in. 4. Fallback-path decision + impl +
   proof. 5. Release-validation checklist + TTFA. 6. Hand back.
