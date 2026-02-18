# Fae v1.0: Production-Ready Release + Orb Follows You

## Problem Statement

Fae's macOS app runs the Rust core as a subprocess (stdin/stdout JSON pipes) — fragile, adds
IPC latency, and prevents companion apps from connecting. Users can't use Fae on iPhone or
Apple Watch, can't hand off sessions across devices, and the app isn't distributed via App Store.

## Success Criteria

- Rust core embedded in-process via C ABI (zero IPC overhead)
- Single `.app` bundle, code-signed + notarized
- Optional Unix socket listener for external clients
- iPhone companion with "orb follows" Handoff
- Apple Watch companion with orb complication
- App Store submission with privacy nutrition labels
- All latency SLOs met (C ABI dispatch p95 <= 0.25ms)
- Zero compilation errors and warnings
- All tests pass

---

## Milestone 1: Embedded Core (Rock-Solid Mac App)

Replace interim subprocess bridge with in-process Rust via C ABI. Ship a single-binary
macOS app where Swift and Rust share the same process.

### Phase 1.1: FFI Surface

Create `src/ffi.rs` with C ABI exports:
- `fae_core_init(config_json) -> *mut FaeRuntime`
- `fae_core_start(rt) -> i32`
- `fae_core_send_command(rt, json) -> *mut c_char`
- `fae_core_poll_event(rt) -> *mut c_char`
- `fae_core_set_event_callback(rt, cb, ctx)`
- `fae_core_stop(rt)`
- `fae_string_free(s)`

Add `crate-type = ["staticlib", "lib"]` to `Cargo.toml`.
Generate C header with `cbindgen`.

**Key files:** `src/ffi.rs` (new), `Cargo.toml`, `cbindgen.toml` (new), `include/libfae.h` (generated)

### Phase 1.2: Swift Integration

Create `EmbeddedCoreSender` implementing `HostCommandSender` protocol.
Update `Package.swift` to link `libfae.a` static library.
Wire `EmbeddedCoreSender` into `FaeNativeApp.swift` replacing `ProcessCommandSender`.

**Key files:** `EmbeddedCoreSender.swift` (new), `Package.swift`, `FaeNativeApp.swift`

### Phase 1.3: Real DeviceTransferHandler

Wire a production `DeviceTransferHandler` implementation that routes commands to
`PipelineCoordinator` — replacing the current `NoopDeviceTransferHandler`.

Bridge all 24 host commands end-to-end: conversation inject/gate, orb controls,
device move/go_home, scheduler CRUD, approval, config get/patch.

**Key files:** `src/host/channel.rs`, `src/host/mod.rs`, `HostCommandBridge.swift`

### Phase 1.4: Release Workflow + Production Polish

Update `release.yml`: remove `fae-backend` from bundle, single binary only.
Add proper `Info.plist` with `NSUserActivityTypes`, deep link URL types.
Add login item registration (launch at boot, optional).
Add lightweight crash reporting (local crash logs).
Accessibility labels and VoiceOver support.

**Key files:** `.github/workflows/release.yml`, `Entitlements.plist`, `Info.plist`

### Phase 1.5: Integration Testing + Latency Validation

Full lifecycle test: init → start → send commands → receive events → stop.
Latency microbenchmarks: C ABI dispatch p95 <= 0.25ms.
Verify sandbox/entitlements work with in-process Rust.
Memory leak check with Instruments/LeakSanitizer.

**Key files:** `tests/ffi_lifecycle.rs` (new), `src/host/latency.rs`

---

## Milestone 2: Socket Listener + Handoff Infrastructure

Enable external frontends (CLI tools, companion apps) to connect to the running
Fae.app via Unix domain socket. Prepare cross-device Handoff payloads.

### Phase 2.1: UDS Socket Listener

Add tokio task in libfae: `tokio::net::UnixListener` on `~/.fae/fae.sock`.
Reuse `HostCommandServer` with same routing logic.
Gate behind config flag (disabled by default).

**Key files:** `src/host/socket.rs` (new), `src/ffi.rs`, config

### Phase 2.2: Bonjour/mDNS Discovery

Advertise the running Fae instance on local network via Bonjour.
Companion apps discover the Mac automatically (same WiFi).
Service type: `_fae._tcp.local.`

**Key files:** `src/host/discovery.rs` (new) or Swift-side `NWBrowser`

### Phase 2.3: Enhanced Handoff Payload

Extend `FaeHandoffContract` with orb state (mode, feeling, palette),
conversation tail (last N turns), active tasks, and backend endpoint.

**Key files:** `FaeHandoffContract.swift`, `DeviceHandoff.swift`

### Phase 2.4: Entitlements for Cross-Device Handoff

Add `NSUserActivityTypes` to macOS `Info.plist`.
Add `com.apple.developer.associated-domains` entitlement.
Add `com.apple.security.application-groups` for shared keychain.
Verify same Team ID across macOS/iOS/watchOS targets.

**Key files:** `Entitlements.plist`, `Info.plist`, signing configs

---

## Milestone 3: iPhone Companion ("Orb Follows You")

Build a minimal iPhone app that receives Handoff from the Mac, displays the orb,
and relays voice input back to the Mac's embedded Rust core.

### Phase 3.1: Xcode Project Setup

Create proper iOS target (not just templates).
Share `FaeHandoffKit` package between macOS and iOS targets.
Set up signing, entitlements, and provisioning.

**Key files:** `native/apple/FaeCompanion/` (full Xcode project)

### Phase 3.2: Shared Orb Renderer + Conversation UI

Port the orb WebView renderer to iOS (WKWebView or native Core Animation).
Minimal conversation panel (text display + voice input).
Match Mac's orb palette, feeling, and mode fidelity.

**Key files:** iOS orb view, shared HTML/JS resources

### Phase 3.3: Handoff Receiver + IPC Client

Implement `NSUserActivity` continuation handler.
Connect to Mac's socket listener via Bonjour-discovered endpoint.
Display orb state from handoff payload while connecting.
Fallback to handoff payload content when Mac unreachable.

**Key files:** iOS app delegate, IPC client module

### Phase 3.4: Voice Relay

Use Apple Speech framework for on-device transcription.
Relay transcribed text to Mac via IPC (`conversation.inject_text`).
Receive assistant responses via event stream.
On-device TTS playback from text (or relay audio stream later).

**Key files:** iOS speech module, IPC event handler

---

## Milestone 4: Watch Companion

Minimal Apple Watch experience: orb complication showing status, voice input.

### Phase 4.1: WatchKit Target + WCSession Bridge

Create watchOS target in same Xcode workspace.
Use `WCSession` to bridge Watch ↔ iPhone ↔ Mac relay.
Share `FaeHandoffKit` types.

**Key files:** `native/apple/FaeCompanion/watchOS/`

### Phase 4.2: Orb Complication + Voice Input

Orb complication showing current mode/feeling with palette colors.
Voice input via Watch mic → iPhone relay → Mac.
"Go home" gesture (crown press or wrist raise).

**Key files:** watchOS complication, voice handler

---

## Milestone 5: App Store Submission

### Phase 5.1: Privacy Labels + TestFlight

Privacy nutrition labels for all three targets (macOS, iOS, watchOS).
TestFlight beta distribution.
Beta feedback collection.

**Key files:** App Store Connect metadata

### Phase 5.2: App Store Connect + Submission

App descriptions, screenshots, keywords for all three platforms.
Review compliance (mic usage, network access, data handling).
Submit for App Review.

**Key files:** App Store Connect, marketing materials
