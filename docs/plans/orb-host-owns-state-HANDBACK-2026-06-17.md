# Hand-back report — orb-host-owns-state (Steps 3–5)

Branch: `llamacpp-serving-adapter` · Working tree (NOT committed/pushed — for reviewer)
Session: 2026-06-17. Steps 1+2 were committed earlier (`67ce77dd`); this change
completes Steps 3, 4, and the static portion of 5.

> ## Reviewer addendum (2026-06-17, main session)
>
> Reviewed against live behavior + `git diff` (not the report's claims). Re-ran
> all static checks independently — green (19 orb-host, 53 daemon+control-plane,
> clippy `-D warnings`).
>
> **Release-blocking bug found + fixed.** The new daemon bridge authenticated as
> `client_id: "fae-ui-shell"`, but the daemon bootstraps exactly ONE client,
> `"swift-frontend-bootstrap"`, and `registry.authenticate` rejects any unknown
> id with `UnknownClient`. Auth would fail → reconnect-loop forever → the orb
> receives ZERO daemon events. With Swift orb-drive retired in the same change,
> there is no fallback: the orb would be stuck idle for the whole turn. Never
> caught because the prior session's voice-ride ran through the Swift relay, not
> this bridge — its auth path had never been exercised end-to-end. **Fix:** auth
> under the bootstrap client id, promoted to a shared `fae_control_plane::
> BOOTSTRAP_CLIENT_ID` const used by BOTH the daemon (registration) and the
> bridge (auth) so the literal can never drift. Also fixed a stale bridge header
> doc (claimed "cargo feature / default-OFF"; it is `#[cfg(unix)]` runtime-gated,
> default-ON).
>
> **Live run COMPLETED** (the open Step-5 blocker), dev app `FAE_DAEMON_PLAYBACK=1
> RUST_LOG=info --test-server`, real turn via `POST /inject`. Bridge connected +
> authenticated cleanly (zero `UnknownClient`/`session ended`). `ORB_MODE` trace:
> `Quiescent → Thinking (inject) → Speaking (tts.speak→audio.level) → Quiescent` —
> **no `thinking→idle→thinking`, no `speaking→idle→speaking`**; grace-hold held
> Speaking across the multi-sentence gaps. Orb bright at rest (Quiescent).
>
> **Coupling to note (documented staging, not a regression introduced here):**
> orb speaking now requires daemon-OWNED playback (`tts.speak`, gated by
> `FAE_DAEMON_PLAYBACK`). On the DEFAULT lane (`tts.synthesize` + Swift-local
> playback, flag off) the daemon emits no `audio.level`, so with the Swift
> speaking-driver retired the orb shows no Speaking. This is the open-gaps V3b
> staging (owned-playback is a gated HIGH-risk cutover). **Gate:** making
> `FAE_DAEMON_PLAYBACK` the default is the step that returns orb-speaking to
> default-config users; this series must not reach an end-user release before
> that flip.

> **Workflow note:** the plan says the team HANDS BACK for review and does NOT
> commit/push. I have not committed or pushed. `autoresearch.jsonl` is an
> unrelated modified file from a prior coverage session and is excluded from all
> diffs below.

---

## TL;DR

- **Step 3 (info indicator + click→action):** DONE in the Rust orb host. Second
  pill line (green dot + summary), `__faeSetInfoItems`, click posts
  `{type:"info_action",id}`, routed by canonical-model lookup → url / app /
  research (temp HTML page). `InfoItem` gained `action: Option<String>`.
  Collapsed-pill sizing grows to 78px (from 52) when the info line is shown so
  it isn't clipped; `renderInfo` re-sizes on change.
- **Step 4 (retire Swift orb-drive):** DONE — **strictly**. Swift no longer
  sends `thinking`/`speaking`/`quiescent` state commands to the orb host AT
  ALL. `sendState(forMode:)` forwards ONLY `.listening` (PTT); the `$feeling`
  sink now sends feeling without a `state` field (mode no-op). `OrbStateBridgeController`
  drives no orb modes except `.listening`/`.idle` from PTT/mic_status; runtime
  mode assignments removed (only `runtime.error → .concern` feeling kept). The
  V4 relay (`sendAudioLevel` + the two daemon-audio subscriptions +
  `useRealAudioOrb`/`ridingRealAudio`) is gone. The orb host's grace-hold
  state machine is the single source of truth for thinking/speaking/idle.
- **Step 5 (live verification):** ⚠️ **NOT PERFORMED — blocker below.** All
  static verification (fmt/clippy/test/build) is green. The live turn +
  on-screen check requires a GUI/bundled macOS app run that this headless agent
  environment cannot perform.

---

## 1. `git diff --stat` (excluding `autoresearch.jsonl`)

```
 .../Fae/Sources/Fae/OrbStateBridgeController.swift | 231 ++++-----------------
 .../Fae/Sources/Fae/RustUiShellController.swift    | 100 +++------
 native/rust/fae-ui-shell/src/daemon_audio_bridge.rs|  52 ++++-
 native/rust/fae-ui-shell/src/main.rs               | 179 +++++++++++++++-
 native/rust/fae-ui-shell/src/orb_state.rs          |   7 +-
 5 files changed, 309 insertions(+), 260 deletions(-)
```

No new files; new tests live in existing `#[cfg(test)]` modules.

## 2. Static verification — command tails

### Rust crates (`env -u RUSTFLAGS`)

**fae-control-plane** — fmt ✓ · clippy `-D warnings` ✓ · `nextest` 23/23 pass
```
 Summary [   0.018s] 23 tests run: 23 passed, 0 skipped
```

**fae-daemon** — fmt ✓ · clippy `-D warnings` ✓ · `nextest` 30/30 pass
(incl. `inject_text_publishes_generating_active_then_inactive_on_success`,
`info_push_validates_and_publishes_items`,
`info_push_rejects_items_missing_required_fields`)
```
 Summary [   0.625s] 30 tests run: 30 passed, 0 skipped
```

**fae-ui-shell (orb host)** — fmt ✓ · clippy `-D warnings` ✓ · `nextest` 19/19
pass (incl. 3 new `daemon_audio_bridge::tests::parse_info_items_*` and the 6
existing `orb_state` flicker tests)
```
 Summary [   0.022s] 19 tests run: 19 passed, 0 skipped
```

Release binaries rebuilt clean:
- `native/rust/fae-ui-shell/target/release/fae-ui-shell` (with new info UI + `ORB_MODE` trace)
- `crates/target/release/fae-daemon`

### Swift
`cd native/macos/Fae && swift build` → **Build complete! (39.57s)**
(one pre-existing unrelated `CFString` warning in `PipelineCoordinator.swift:5048`,
untouched by this change.)

## 3. Grep evidence — Swift no longer drives the orb mode

Done criterion: *"the orb host derives state from the daemon with Swift not
driving the mode."*

All remaining `orbState.mode =` assignments in the two orb-drive files are
**listening/PTT only** — NONE set `.thinking`/`.speaking`/`.idle` from
generation, audio, or runtime events:

```
OrbStateBridgeController.swift:175  orbState.mode = .listening  // pipeline.mic_status active
OrbStateBridgeController.swift:180  orbState.mode = .idle       // mic closed
OrbStateBridgeController.swift:191  orbState.mode = .listening  // pipeline.control Start/Resume
OrbStateBridgeController.swift:195  orbState.mode = .idle       // Stop/Pause
```

And Swift→host state commands — **only `listening` is forwarded** (the one
remaining PTT signal); `thinking`/`speaking`/`quiescent` are NOT sent:
```
$ grep -nE 'sendState\("(thinking|speaking|quiescent|listening)"' RustUiShellController.swift
332:            sendState("listening", feeling: feeling)
```

The retired notifications/APIs appear **only in comments** documenting the
retirement (zero live usage):
```
$ grep -rnE "faeAssistantGenerating|faeAudioLevel|faeDaemonAudioLevel|faeDaemonAudioEnded|sendAudioLevel|useRealAudioOrb|ridingRealAudio" \
    native/macos/Fae/Sources/Fae/{OrbStateBridgeController,RustUiShellController}.swift
OrbStateBridgeController.swift:10   /// `.faeAssistantGenerating`, `.faeAudioLevel`, `.faeDaemonAudioLevel`, or
OrbStateBridgeController.swift:11   /// `.faeDaemonAudioEnded` — those subscriptions were removed …
OrbStateBridgeController.swift:90   // NOTE: `.faeAssistantGenerating`, `.faeAudioLevel`,
OrbStateBridgeController.swift:91   // `.faeDaemonAudioLevel`, and `.faeDaemonAudioEnded` are deliberately …
RustUiShellController.swift:310     // `.faeDaemonAudioLevel` / `.faeDaemonAudioEnded` subscriptions +
RustUiShellController.swift:311     // `sendAudioLevel` are gone …
```

The notifications are still **posted** by `PipelineCoordinator` and **defined**
in `BackendEventRouter` — that's expected (the daemon TTS engine + event
subscriber stay for V3b playback and other pipeline consumers); only the
**orb-drive consumers** were retired.

## 4. What was built (Step 3 detail)

**Data model** (`orb_state.rs`): `InfoItem` gained `action: Option<String>` (the
click-routing payload). `daemon_audio_bridge.rs::parse_info_items` now parses
the optional `action` and drops malformed items; 3 new unit tests cover
with-action / drops-malformed / missing-items.

**Pill UI** (`main.rs` `PILL_HTML`):
- New `#info` line (green dot `#5F7F6F` + summary), CSS-toggled by
  `shell.classList.has-info`; hidden when there are no items.
- `window.__faeSetInfoItems(items)` renders one item's title or "N updates".
- Click `stopPropagation()`s (so it doesn't expand the conversation pill) and
  posts `{type:"info_action", id}`.
- **Sizing:** a `baseHeight()` helper returns 78px (vs 52) when info items are
  present, so the second line isn't clipped in the collapsed pill; `renderInfo`
  calls `sizePill(false)` on change to re-resize, and multi-message sizing adds
  the info height. Rust `pill_resize` clamp (52..240) admits the new height.

**Routing** (`main.rs` `PanelAction` match): new `Some("info_action")` arm calls
`handle_info_action(id, &orb_ui)`, which looks the item up in the **canonical
model** (doesn't trust the JS payload's kind) and dispatches:
- `url` → `open`/`xdg-open` only if `http(s)://` or `file://` (refuses others).
- `app` → macOS `open -a <action|title>`; Linux `xdg-open`.
- `research`/`x0x` → writes a minimal temp HTML page (title + link/pre for the
  payload) under the OS temp dir and opens it. v1 until a richer `show_html`
  reuse lands.

Never panics; every miss is logged. The orb host owns the whole path (no-Swift
principle). `push_pill_info(&pill, &orb_ui)` is called on `InfoUpdate`.

**Step 2 (daemon `info.update` source):** already present — `info_push` in
`session.rs` publishes `info.update` on `Scope::StatusRead`, forwarding the whole
item incl. `action`. The orb's `SwiftFrontend`-class bootstrap grant includes
`StatusRead`/`ConversationRead`/`AudioPlayback`, so it receives the event. The
orb bridge resolves the daemon socket + token at the standard
`~/Library/Application Support/fae/run/` path (mirrors the daemon's
`data_directory()`), so **no Swift env passing is required** for the host to
self-subscribe on macOS. (`FAE_DAEMON_SOCK`/`TOKEN`/`RUN_DIR` overrides exist
for non-standard layouts.)

## 5. ⚠️ Live verification — NOT PERFORMED (blocker)

The plan's done criteria require a **live turn** driven through the bundled app
(`FAE_DAEMON_PLAYBACK=1 FAE_TEST_SERVER=1`, `POST 127.0.0.1:7433/inject`), an
`ORB_MODE` trace with no `thinking→idle→thinking` / `speaking→idle→speaking`
flips, and **on-screen** confirmation (thinking holds steadily, reply streams,
orb bright at rest, info indicator click opens the page/app/url).

**I could not perform this.** This is a headless, non-interactive agent
environment: it cannot launch a macOS `.app` as a GUI process, render the orb to
a screen, play audio, or visually confirm the indicator. Per the plan's own rule
("Flag anything you could not verify; do not paper over it"), I am reporting
this as a blocker rather than asserting it passes.

What I **did** do to de-risk the live run:
- Added a low-noise `log::info!("ORB_MODE -> {:?}", mode)` in `apply_orb_mode`,
  emitting **only on mode change**, so the live trace is a handful of lines per
  turn and the flicker check is a clean `grep ORB_MODE`.
- Rebuilt the release orb-host + daemon binaries so the bundled app will embed
  the new code once the reviewer runs the bundle path.

**For the reviewer to finish Step 5**, run (per the plan + `native/macos/Fae/justfile`):
```bash
cd native/macos/Fae
just run-dev   # build-ui-shell build-daemon build _bundle-app _embed-ui-shell _embed-daemon _sign-bundle _kill-fae
# then with the app up:
FAE_DAEMON_PLAYBACK=1 FAE_TEST_SERVER=1 … launch the .app
python3 -c "import urllib.request,json; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:7433/inject', data=json.dumps({'text':'hello'}).encode()))"
# capture: grep ORB_MODE <orb-host-stderr>   → expect Thinking then Speaking then Quiescent, no idle-between
# info indicator: drive an info.push through the daemon and click the green-dot line
```
Mind the plan's **bundling trap**: `just build` alone does NOT update the
running `.app` — `run-dev` (bundle + embed + sign) does.

## 6. Deviations / risks

- **Listening/PTT stays Swift-signaled** (plan caveat V5). `OrbStateBridgeController`
  still sets `.listening`/`.idle` from `pipeline.mic_status` and
  `pipeline.control` Start/Stop, and `RustUiShellController` forwards ONLY
  `.listening` to the host. Right-⌥ PTT is a Swift `NSEvent` the orb host can't
  see; the orb host already self-sets listening for its own long-press gesture.
  This is the one remaining orb signal Swift emits, as the plan allows. The
  host recovers from `listening` on its own when the next daemon event arrives.
- **Feeling (orb emotion) is forwarded without a mode.** The `$feeling` sink now
  sends `{type:"state", feeling}` with NO `state` field; the orb host's State
  handler treats a missing state as a mode no-op, so palette/emotion updates
  without clobbering the daemon-derived mode.
- **Info click routing for `research`/`x0x`** is a v1 temp-HTML-page affordance,
  not a reuse of the full `show_html`/x0x-gui page style. Functional, opens in
  the default browser; a richer integration can land incrementally.
- **Status: implementation + static verification complete; live GUI
  verification remains for the reviewer** (see §5 blocker).
- **No commit/push** (per workflow). `autoresearch.jsonl` is an unrelated
  modified file from a prior coverage session; leave it out of the orb commit.
