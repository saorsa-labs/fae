# Mega-prompt — orb host owns its state via the daemon (retire Swift orb-drive) + info indicator (2026-06-17)

Paste into a fresh session. Self-contained; **verify every claim against the repo and live output** —
dev-agents have fabricated reports.

---

## Workflow — read first

**You (the team) implement AND test this to completion, then HAND BACK for review. You do NOT commit
or push.** The owner's reviewer commits + publishes after review.

1. **Build it** per "The work" below, smallest-increment-first (the "Suggested order").
2. **Test to completion** — every item in "Done criteria" must pass with **verbatim evidence you
   captured yourself**, not asserted:
   - `git diff --stat` of everything you changed.
   - `cd crates && env -u RUSTFLAGS cargo fmt -p <c> -- --check && cargo clippy -p <c> --all-targets --
     -D warnings && cargo nextest run -p <c>` tails for each touched crate, and the orb host
     (`native/rust/fae-ui-shell`); Swift `swift build` clean.
   - A **live run** of the dev app (`FAE_DAEMON_PLAYBACK=1`, `FAE_TEST_SERVER=1`) driving a real turn
     via `POST http://127.0.0.1:7433/inject` (Python urllib — a hook intercepts curl): paste the
     mode-transition trace showing **no `thinking→idle→thinking` / `speaking→idle→speaking` flips**,
     and confirm on-screen that thinking holds steadily, the reply streams, the orb is bright at rest,
     and the info indicator works.
   - **Heed the BUNDLING TRAP** (gotchas): a `just build` alone does NOT update the running app — your
     Swift changes won't take effect until you `_bundle-app`/`_sign-bundle`. Confirm the live behavior,
     don't trust the source diff.
3. **Hand back a report** with all the above evidence + a short summary of what changed and any
   deviations/risks. Then STOP — the reviewer validates against the evidence, commits the series, and
   publishes. Flag anything you could not verify; do not paper over it.

---

## Objective (owner decision 2026-06-17)

Make the **Rust orb host** (`native/rust/fae-ui-shell`) derive its own state — thinking / speaking /
idle / **info** — by **subscribing to the daemon's event stream**, and **retire the Swift orb-drive
code** (`OrbStateBridgeController` mode logic + the V4 level relay in `RustUiShellController`). The
orb is the cross-platform face; its state must come from the daemon (brain), not the Swift adapter.
This simultaneously: (a) fixes the **thinking/speaking flicker** (the orb host grace-holds state in
Rust), and (b) adds the new **info indicator** (a second pill line, green dot, click→action).

**The no-Swift principle:** Swift stays the macOS *adapter* (Apple tools/EventKit, MLX training, the
voice pipeline, launching the orb host) — but it must NOT drive the orb's mode. The orb host owns
that, from daemon events.

---

## Why (root cause, measured live 2026-06-17)

The orb mode is driven by `OrbStateBridgeController` from `.faeAssistantGenerating` and the daemon
audio notifications. The pipeline **toggles** `.assistantGenerating` mid-turn, so the orb flips
`thinking → idle → thinking` in the gap (no steady "thinking" indication), and daemon TTS is
sentence-streamed (one `tts.speak` per sentence → one `playback_ended` each), so it flips
`speaking → idle → speaking` between sentences. Live `ORB_MODE` trace of one turn:
`idle→thinking→thinking→idle→thinking→speaking→idle→speaking→idle`. Patching this in Swift is more
adapter code to delete later — the fix belongs in the orb host with a **grace-hold** (a brief
down-transition delay that a resuming event cancels), driven by daemon events.

---

## What already exists (build on it — don't rebuild)

Branch `llamacpp-serving-adapter` (pushed) + **uncommitted working-tree changes** from the prior
session (V3b/V4 + orb UX). Verify with `git status`/`git diff`.

- **Daemon event channel (V2, committed 086f8024).** `conversation.subscribe` opens a server-push
  stream; `crates/fae-daemon/src/events.rs` has `EventBus` (Weak-ref subscribers, per-event `Scope`
  filter) + `ConnSink` (per-connection writer task). Wire type `Event { v, event, payload }` in
  `fae-control-plane` — demux from `Response` by the `event` key. Events go ONLY to subscribers.
- **Daemon TTS playback events (V3a, committed 3e0b226f).** During `tts.speak` the daemon publishes
  `audio.level {rms, playback_id}` (~quiet: mean ~0.026, peak ~0.09) and
  `audio.playback_ended {playback_id, reason}` on the bus (scope `AudioPlayback`). `audio.stop`
  barges in.
- **V4b daemon-audio bridge (orb host, uncommitted).** `native/rust/fae-ui-shell/src/daemon_audio_bridge.rs`
  ALREADY: opens its own Unix socket to the daemon, reads `bootstrap.token`, authenticates,
  `conversation.subscribe`, demuxes `{event,payload}`, forwards `audio.level`/`playback_ended` to a
  `UserEvent::DaemonAudio`. **Currently feature-gated (`daemon-audio-bridge`) + Unix-only + runtime
  `FAE_ORB_DAEMON_AUDIO=1`, and it only sets `bridge_audio` (not the mode).** This is the seam to
  extend + enable on macOS.
- **Orb host pill + rendering (Rust, uncommitted, WORKING per owner):** pill fade-after-7s, autoexpand
  (`scrollHeight` measure → `pill_resize`, guarded), sentence formatting (`formatBody`), idle
  brightness (`presence mix(0.9,1.0)` + fuller idle breath), `rms_to_level` (maps quiet RMS into the
  0.18–0.6 expressive band), tri-state `AudioPatch`, hint "Hold right ⌥ to talk · click to see
  conversation". KEEP all of this.
- **Swift orb-drive to RETIRE:** `OrbStateBridgeController` (`.faeAssistantGenerating`→thinking/idle;
  `.faeAudioLevel`/`.faeDaemonAudioLevel`→speaking; grace handlers) and the V4 audio relay in
  `RustUiShellController` (`sendAudioLevel`, the `.faeDaemonAudioLevel`/`Ended` sinks). `DaemonTTSEngine.speak`
  (`tts.speak`) + `DaemonEventSubscriber` (Swift's daemon event sub, posts `.faeDaemonAudio*`) STAY
  for V3b playback, but the orb host will subscribe for ITSELF (the Swift sub can remain for pipeline
  state, or be slimmed).

---

## The work

### A. Daemon: emit the missing state events
- **`assistant.generating {active: bool}`** (new event, scope `ConversationRead`). Publish `active:true`
  when the daemon begins processing a `conversation.inject_text` turn and `active:false` when the turn
  text is ready (before/at TTS). Files: `crates/fae-daemon/src/session.rs` (inject_text handler) +
  `EventBus::publish`. This is the "thinking" signal the orb host needs.
- **`info.update {items:[{id,kind,title,action}]}`** (new event, scope e.g. `StatusRead`). The daemon
  publishes the current info set (app messages / x0x / research / scheduler results). For v1 a
  daemon-side `info.push`/test command or a simple source is fine — wire real sources incrementally;
  log what's dropped.
- (Listening: PTT capture is still Swift until V5. See caveat below.)

### B. Orb host: own the state (Rust)
- Promote `daemon_audio_bridge` from feature-gated/Linux-only to the **default macOS path** (runtime
  flag ok, default ON when a daemon socket + token are available). It must connect on macOS too
  (the daemon socket path + `bootstrap.token` are under the fae data dir; Swift can pass them via env
  at spawn, e.g. `FAE_DAEMON_SOCK`/`FAE_DAEMON_TOKEN`, or the host resolves them like the bridge does).
- Subscribe + handle: `assistant.generating(true)`→**thinking**; `audio.level`→**speaking** + ride the
  RMS (existing `rms_to_level`); `audio.playback_ended`→arm idle **grace**; `assistant.generating(false)`
  →arm idle grace; `info.update`→info indicator. Drive `OrbUiState` directly in the orb host.
- **Grace-hold (the flicker fix):** a down-transition (to idle) waits ~1.2–1.5 s; any resuming event
  (next sentence's `audio.level`, or `generating(true)`) cancels it. So thinking holds across the
  `generating` toggle and speaking holds across sentence gaps. Pure, unit-testable.
- The pill already renders thinking/speaking/quiescent from `ui_mode`; now `ui_mode` is set by the
  bridge, not by Swift `State` commands.

### C. Info indicator (the new feature)
- **Second pill line:** below the main line, a small **green dot** + summary (single item → its title;
  many → "N updates"), shown only when `info.items` is non-empty. Use DESIGN.md tokens (Scottish
  palette; green ≈ `glen-green`/`#5F7F6F` or a clear status green — check DESIGN.md, don't invent).
- **Click → action:** post `{type:"info_action", id}`. Route by `kind`:
  - `research` / `x0x` → write an HTML page (reuse the `show_html` tool / x0x-gui page style) and open it.
  - `app` (whatsapp/discord/slack) → open that app (NSWorkspace on macOS / `xdg-open` Linux).
  - `url` → open the URL.
  - The router can live daemon-side (cross-platform) or in the orb host; keep Swift out of it where
    possible (Swift may still perform the macOS `open` as the adapter).

### D. Retire the Swift orb-drive
- Remove `OrbStateBridgeController`'s mode driving (thinking/speaking/idle + the daemon grace handlers)
  and the `RustUiShellController` V4 relay. Keep Swift ↔ orb only for: launching the host, passing the
  daemon socket/token, window show/hide, menu actions, and the **PTT listening** signal (below).
- Verify the orb still works with Swift NOT driving mode (the host self-subscribes).

---

## Caveats / gotchas (verified this session — trust these)

- **BUNDLING TRAP (cost me a whole cycle):** `just build` compiles Swift but does NOT update the
  running `.app`. You MUST run `just build _bundle-app _embed-ui-shell _embed-daemon _sign-bundle`
  (and `_kill-fae`) for Swift changes to take effect; the bundle binary mtime + `strings <bin> | grep
  <yourmarker>` confirm it. The orb host can be iterated faster by pointing `FAE_UI_SHELL_BIN` at
  `native/rust/fae-ui-shell/target/release/fae-ui-shell` (no re-embed needed).
- **`env -u RUSTFLAGS`** for ALL crate builds (vendored candle breaks `-D warnings`).
- **Listening/PTT stays Swift-signaled** until capture moves to the daemon (gap V5): Right ⌥ is a Swift
  NSEvent the orb host can't see. Options: Swift emits a `listening` event to the daemon→orb, or a
  minimal Swift→orb `listening` command (the one remaining orb signal). The orb host already owns the
  orb long-press gesture, so it can self-set listening for THAT path. Don't block the refactor on V5.
- **Daemon must be reachable from the orb host on macOS** — the daemon is spawned by Swift
  (`DaemonLLMEngine`); pass its socket path + bootstrap token to the orb host (env at spawn is
  simplest). The bridge already reads `bootstrap.token` from the run dir.
- **Run the app with the V3b/V4 flags** to exercise daemon playback: `FAE_DAEMON_PLAYBACK=1`
  `FAE_ORB_REAL_AUDIO` is being SUPERSEDED (the host self-subscribes now). Drive turns headlessly via
  the test server: launch with `FAE_TEST_SERVER=1`, `POST http://127.0.0.1:7433/inject {"text":...}`
  (use Python urllib — a hook intercepts curl).
- **Event demux:** events are `{v,event,payload}` (no `ok`/`request_id`); `Response` has
  `deny_unknown_fields` so decoding an event as a response fails — branch on `event` first.
- **MLX ops crash under `swift test`**; quit the dev app before local `swift test`.

---

## Done criteria
- A real turn (text-inject or voice): the pill shows **"Thinking…" steadily** through the whole
  generation gap (no idle flicker), then the **response text streams** in (no flicker, formatted),
  then fades after 7 s; the orb stays **speaking** across all sentences and returns to its **bright**
  idle. Verified by an `ORB_MODE`-style trace showing NO `thinking→idle→thinking` /
  `speaking→idle→speaking` flips, plus on-screen confirmation.
- The orb host derives state from the daemon with **Swift not driving the mode** (grep: no
  `orbState.mode =` in the orb-drive path; `OrbStateBridgeController` mode logic gone).
- **Info indicator:** with a test `info.update`, the second pill line shows a green dot + summary;
  clicking opens the appropriate page/app. Verified live.
- `env -u RUSTFLAGS` clippy `-D warnings` + tests green (fae-control-plane, fae-daemon, fae-ui-shell);
  Swift builds; flag-OFF / no-daemon path degrades gracefully (orb falls back to a calm idle).

## Suggested order
1. Daemon `assistant.generating` event (+ test). 2. Orb host: extend the bridge to drive mode +
grace-hold (un-gate, enable macOS); verify the flicker is gone via a turn. 3. Info: daemon
`info.update` + orb host second-line + click-action. 4. Retire Swift orb-drive; verify. 5. **Hand back** the full
evidence report (do NOT commit/push) — the reviewer validates, commits the whole series
(V3b+V4+orb-host-owns-state+info), and updates `open-gaps-2026-06-16.md` D5 + memory + Obsidian on
publish.

**Current uncommitted state to fold in / not lose:** V3b (daemon TTS playback), V4 (relay — being
retired), V4b bridge, the 3 V4 bug fixes, and all the orb-host pill UX (brightness/fade/expand/format/
hint/streaming/voice-ride). Diagnostics already removed. Nothing committed since the pushed
`086f8024`/V3a — decide commit granularity with the owner.
