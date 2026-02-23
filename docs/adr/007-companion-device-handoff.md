# ADR-007: Companion Device Handoff (iPhone, iPad, Apple Watch)

**Status:** Proposed
**Date:** 2026-02-23
**Scope:** Cross-device architecture — Mac (brain), iOS/watchOS (thin companions), relay protocol, shared UI components

## Context

Fae runs as a macOS native app with an embedded Rust core (`libfae`). The Rust core
owns all intelligence: LLM inference (Qwen3 on Metal GPU), STT (Whisper), TTS
(Kokoro-82M), memory (SQLite + embeddings), scheduler (11 tasks), and tool execution.
The macOS app links `libfae.a` directly via C ABI (Mode A) with zero IPC overhead.

Users want to continue interacting with Fae from their iPhone, iPad, or Apple Watch —
at minimum seeing the orb and hearing/speaking to Fae, even though the brain stays on
the Mac.

### What already exists

| Component | Status | Location |
|-----------|--------|----------|
| **FaeHandoffKit** | Built | `native/apple/FaeHandoffKit/` — shared SPM package with `ConversationSnapshot`, `FaeHandoffContract`, `FaeHandoffPayload` |
| **DeviceHandoffController** | Built | `native/macos/.../DeviceHandoff.swift` — publishes `NSUserActivity`, network monitoring, 30s timeout, offline retry |
| **HandoffKVStore** | Built | `native/macos/.../HandoffKVStore.swift` — iCloud KV fallback with external change observation |
| **DeviceCommandParser** | Built | `native/macos/.../DeviceHandoff.swift` — voice commands: "move to my phone/watch", "go home" |
| **HandoffToolbarButton** | Built | `native/macos/.../HandoffToolbarButton.swift` — UI trigger for manual handoff |
| **Companion templates** | Scaffold | `native/apple/FaeCompanion/Templates/` — iOS + watchOS app shells that receive `onContinueUserActivity` |
| **Mode B JSON protocol** | Built | `src/host/stdio.rs` — `CommandEnvelope`/`ResponseEnvelope`/`EventEnvelope` over stdin/stdout |
| **Handoff tests** | Built | `native/macos/.../Tests/HandoffTests/` — 30+ test cases for parsing, snapshots, scenarios |

### The fundamental constraint

The Mac is the brain. It has the GPU, RAM, and power supply to run LLM inference:

| Workload | Can run on Mac | Can run on iPhone | Can run on Watch |
|----------|:-:|:-:|:-:|
| LLM inference (Qwen3 4B) | Yes (Metal GPU) | Marginal (battery/thermal) | No |
| STT (Whisper) | Yes (Metal) | Possible (Apple Speech fallback) | No |
| TTS (Kokoro-82M) | Yes | Possible (AVSpeechSynthesizer fallback) | No |
| Memory (SQLite + embeddings) | Yes | Read-only sync possible | No |
| Tool execution (bash, web, etc.) | Yes | No | No |
| Orb rendering (Metal shader) | Yes | Yes (Metal on A-series) | Yes (reduced) |

Apple Watch can never run any inference workload. iPhone could run smaller models but
at ruinous battery and thermal cost. The Mac must remain the brain for all devices.

## Decision

### Architecture: Thin client companions with Mac as brain

Companion apps are **remote microphones + speakers + orb displays**. The Mac does all
thinking. A relay protocol connects them.

```
Mac (the brain)
  libfae ─── full pipeline (VAD → STT → LLM → TTS → memory → tools)
    │
    ├── FFI → macOS UI (Mode A, existing, unchanged)
    │
    └── FaeRelay (NEW — Rust network service)
         ├── Bonjour advertisement: _fae._tcp
         ├── Multipeer Connectivity session (MCNearbyServiceAdvertiser)
         ├── Same JSON protocol as stdio.rs (CommandEnvelope/EventEnvelope)
         └── + Binary audio frames (PCM/Opus)

              │  local network / Bluetooth / WiFi Direct
              │
iPhone / iPad (thin companion)           Watch (ultra-thin)
  FaeRelayClient (NEW)                     via WatchConnectivity → iPhone
  ├── Mic → audio stream → Mac              ├── Tap-to-talk → audio → iPhone → Mac
  ├── Orb state ← Mac → CompanionOrbView   ├── Simplified orb animation
  ├── TTS audio ← Mac → speaker            ├── TTS audio ← speaker
  └── Conversation text ← Mac              └── Last response + complications
```

### Why a companion app is required (alternatives rejected)

We evaluated whether the orb could reach the iPhone without a dedicated app:

| Approach | Feasibility | Why rejected |
|----------|------------|-------------|
| **Project macOS UI to iPhone** (no app) | Not possible | Apple has no framework for Mac → iPhone UI projection. iPhone Mirroring and Sidecar work in the opposite direction only. |
| **Web page served from Mac** | Technically works | Bad UX: mic requires manual grant each session, no background audio (Safari suspends), no native orb (would need WebGL), no lock screen presence, no Watch support. |
| **AirPlay streaming** | Audio only | AirPlay streams audio output but cannot receive mic input. No custom visual content (only screen mirror or media playback). |
| **NSUserActivity Handoff only** | Launch trigger only | Handoff transfers a one-time payload (ConversationSnapshot) to launch the companion. It is not a persistent connection for real-time audio. |
| **Continuation Streams** | Short-lived bidirectional streams | `NSUserActivity.supportsContinuationStreams` opens input/output stream pairs at handoff time. Streams die on app switch, device lock, or WiFi blip. Too fragile for sustained voice sessions. |
| **Thin native companion + Multipeer Connectivity** | Best option | ~800 LOC Swift, no Rust, auto-discovery, persistent real-time audio, Metal orb rendering on all Apple Silicon. |

**Decision: Build thin native companion apps for iOS, iPadOS, and watchOS.**

### Transport layer: Multipeer Connectivity (primary) + Handoff (launch trigger)

Two Apple frameworks serve complementary roles:

**Apple Handoff (existing)** — triggers companion app launch:
1. User says "Fae, move to my phone" → `DeviceCommandParser` → `DeviceHandoffController`
2. Mac publishes `NSUserActivity` with `ConversationSnapshot` (last 20 turns + orb state)
3. iPhone receives via `onContinueUserActivity` → companion launches with context
4. iCloud KV store (`HandoffKVStore`) provides fallback when real-time Handoff fails

**Multipeer Connectivity (new)** — persistent real-time connection:
1. Once launched, companion discovers Mac via `MCNearbyServiceBrowser` (type: `fae-relay`)
2. Automatic peer discovery over WiFi, Bluetooth, and peer-to-peer WiFi
3. Bidirectional data streams for audio and control messages
4. Survives brief network blips (Multipeer handles reconnection)
5. No manual IP configuration, no port forwarding, no server setup

Why Multipeer Connectivity over raw Network.framework / Bonjour / WebSocket:

| Concern | Multipeer Connectivity | Network.framework + WebSocket |
|---------|:---:|:---:|
| Zero-config discovery | Yes (built-in) | Manual Bonjour setup |
| WiFi + Bluetooth fallback | Automatic | WiFi only |
| Encryption | Automatic (TLS) | Manual TLS configuration |
| iOS + macOS + tvOS | Yes | Yes |
| watchOS | No (use WatchConnectivity) | No |
| Streaming API | `NSOutputStream` / `NSInputStream` | Raw TCP/UDP |
| Reconnection | Automatic | Manual |
| Proven for audio | Yes (documented pattern) | Yes but more work |
| Apple-blessed | Yes | Yes |

### Relay protocol

The relay reuses the existing Mode B JSON protocol from `src/host/stdio.rs` with
two additions: audio frames and orb state events.

#### Message types (JSON text frames)

```jsonc
// Existing (from stdio.rs contract)
{"v": 1, "request_id": "uuid", "command": "runtime.status", "payload": {}}
{"v": 1, "request_id": "uuid", "ok": true, "payload": {"state": "running"}}
{"v": 1, "event_id": "uuid", "event": "runtime.assistant_sentence", "payload": {"text": "..."}}

// New: Orb state (Mac → companion)
{"v": 1, "event_id": "uuid", "event": "orb.state", "payload": {
  "mode": "listening",
  "feeling": "curiosity",
  "palette": "mode-default"
}}

// New: Conversation turn (Mac → companion)
{"v": 1, "event_id": "uuid", "event": "conversation.turn", "payload": {
  "role": "assistant",
  "content": "It's 3:15 PM.",
  "final": true
}}

// New: Audio control (bidirectional)
{"v": 1, "event_id": "uuid", "event": "audio.config", "payload": {
  "sample_rate": 16000,
  "channels": 1,
  "format": "pcm_s16le",
  "direction": "mic_to_brain"
}}

// New: Pipeline state (Mac → companion)
{"v": 1, "event_id": "uuid", "event": "pipeline.state", "payload": {
  "state": "running"
}}
```

#### Audio frames (binary data)

Audio is sent as raw binary data through Multipeer Connectivity's `sendData` API,
not as JSON. Each frame is prefixed with a 4-byte header:

```
[1 byte: frame type] [1 byte: flags] [2 bytes: payload length (big-endian)]
[N bytes: audio payload]
```

Frame types:
- `0x01` — Mic audio (companion → Mac): PCM 16-bit signed LE, 16kHz mono
- `0x02` — TTS audio (Mac → companion): PCM 16-bit signed LE, 24kHz mono
- `0x03` — Audio level (Mac → companion): 4-byte float (RMS for orb visualization)

Flags:
- `0x01` — Start of utterance
- `0x02` — End of utterance
- `0x04` — Opus compressed (future; v1 is raw PCM)

Frame size target: 20ms of audio per frame (320 samples at 16kHz = 640 bytes).
At 24kHz TTS: 480 samples = 960 bytes per frame. Well within Multipeer Connectivity's
reliable data channel limits.

### Orb portability

`NativeOrbView.swift` currently imports `AppKit` and uses `NSViewRepresentable` for
the click target overlay. The Metal shader (`fogCloudOrb`) is cross-platform.
`OrbTypes.swift` (`OrbMode`, `OrbFeeling`, `OrbPalette`, `OrbSnapshot`, `OrbColor`)
is pure Swift with no platform dependencies.

**Extraction strategy:**

1. Move `OrbTypes.swift` into `FaeHandoffKit` (or a new `FaeOrbKit` SPM package)
   as-is — zero changes needed.

2. Create `CompanionOrbView.swift` for iOS/watchOS that wraps the same Metal shader
   but uses `UIViewRepresentable` (iOS) or simplified SwiftUI (watchOS) instead of
   `NSViewRepresentable`. Touch handling replaces mouse tracking.

3. `OrbAnimationState.swift` is pure SwiftUI (`@Observable` + spring interpolation) —
   portable as-is once extracted.

4. The Metal shader library (`.metallib`) needs to be compiled for each platform target
   but the shader source (`.metal` file) is identical.

| Component | macOS | iOS / iPadOS | watchOS |
|-----------|:---:|:---:|:---:|
| `OrbTypes.swift` | Shared | Shared | Shared |
| `OrbAnimationState.swift` | Shared | Shared | Shared (subset) |
| `OrbColor` constants | Shared | Shared | Shared |
| Metal shader source | Shared | Shared | Shared (simplified) |
| Click/touch target | `NSViewRepresentable` | `UIViewRepresentable` | `onTapGesture` |
| Hover tracking | `NSTrackingArea` | N/A (no hover on touch) | N/A |
| Orb size | 80x80 (collapsed) | ~120x120 (centered) | ~60x60 (full screen) |

### Watch path

Apple Watch cannot use Multipeer Connectivity. The Watch communicates through
the paired iPhone using `WatchConnectivity` (`WCSession`):

```
Watch ──WCSession.sendMessageData()──→ iPhone ──MCSession──→ Mac
                                       iPhone ──MCSession──→ Mac
Mac ──MCSession──→ iPhone ──WCSession.transferUserInfo()──→ Watch
```

The iPhone acts as a transparent relay. The Watch companion is ultra-minimal:

- Simplified orb (no Metal shader — use SwiftUI gradient animation, or the Metal
  shader if performance allows on Series 9+ with GPU)
- Tap-to-talk: hold the Digital Crown or tap screen to begin speaking
- Audio capture via `AVAudioSession` (available on watchOS 6+)
- Audio playback via Watch speaker or connected AirPods
- Complication showing last response or connection status
- Haptic feedback (`.notification` tap) when Fae responds

### Authentication and pairing

Companions must prove they belong to the same user. Two mechanisms:

1. **Same iCloud account** (primary): Both devices signed into the same Apple ID.
   Multipeer Connectivity's `MCSession` supports `MCEncryptionRequired`, and the
   invitation flow can include a verification token derived from the shared iCloud
   identity.

2. **Local pairing code** (fallback): Mac displays a 6-digit code, user enters it on
   companion. Stored in Keychain. Required when iCloud is unavailable or for
   non-owner family devices.

The relay only accepts one companion connection at a time per device type (one iPhone
OR one iPad, plus one Watch). Multiple simultaneous companions of different types are
supported (iPhone + Watch).

### Degraded mode (Mac unavailable)

When the Mac is asleep, off, or unreachable:

| Tier | Condition | Behavior |
|------|-----------|----------|
| **Full** | Mac awake, same network | Real-time audio relay, full Fae experience |
| **Remote** | Mac awake, different network | Works via internet relay (future: Tailscale/WireGuard tunnel) |
| **Degraded** | Mac unreachable | Companion shows "Connecting to Fae..." with pulsing orb |
| **Offline** | Mac off, no internet | Optional: local Apple Speech STT + AVSpeechSynthesizer TTS + cloud LLM API (if configured) |

v1 implements Full tier only. Degraded mode shows a clear disconnection state.
Offline and Remote tiers are deferred to future work.

### iPad-specific considerations

iPad supports the same Multipeer Connectivity transport as iPhone. Additional
opportunities:

- **Larger orb canvas**: Full-screen orb with richer shader detail
- **Split view**: Orb on one side, conversation history on the other
- **Canvas support**: iPad could display Fae's canvas output (charts, code, etc.)
- **Apple Pencil**: Future handwriting-to-text input path
- **External display**: iPad + Stage Manager could show Fae on a secondary display

For v1, iPad uses the same companion app as iPhone with adaptive layout.

## Implementation plan

### Phase 1: Extract shared orb components into cross-platform SPM package

**Goal:** `FaeOrbKit` SPM package compiles for macOS, iOS, and watchOS.

**Files to create:**
- `native/apple/FaeOrbKit/Package.swift` — SPM manifest targeting all platforms
- `native/apple/FaeOrbKit/Sources/FaeOrbKit/OrbTypes.swift` — moved from macOS target
- `native/apple/FaeOrbKit/Sources/FaeOrbKit/OrbAnimationState.swift` — moved
- `native/apple/FaeOrbKit/Sources/FaeOrbKit/OrbColor.swift` — extracted from OrbTypes
- `native/apple/FaeOrbKit/Sources/FaeOrbKit/CompanionOrbView.swift` — new, platform-adaptive
- `native/apple/FaeOrbKit/Resources/fogCloudOrb.metal` — shared shader source

**Files to modify:**
- `native/macos/Fae/Package.swift` — add `FaeOrbKit` dependency
- `native/macos/.../NativeOrbView.swift` — import from `FaeOrbKit` instead of local
- `native/macos/.../OrbTypes.swift` — remove (now in FaeOrbKit)

**Platform adaptation in CompanionOrbView:**
```swift
#if os(macOS)
// NSViewRepresentable click target with NSTrackingArea (existing)
#elseif os(iOS)
// UIViewRepresentable touch target, or just .onTapGesture
#elseif os(watchOS)
// Simplified: SwiftUI gradient animation or Metal if GPU allows
#endif
```

**Acceptance criteria:**
- `swift build` succeeds for macOS, iOS simulator, watchOS simulator
- Existing macOS Fae.app builds and links against FaeOrbKit
- Orb renders identically on macOS (no visual regression)

### Phase 2: FaeRelay — Multipeer Connectivity service on Mac

**Goal:** Mac advertises as a Multipeer Connectivity peer and accepts companion connections.

**Rust side — `src/host/relay.rs` (new):**
- `FaeRelayConfig` — enable/disable, service type, display name
- Integration with existing `HostCommandServer` — relay routes commands through the
  same router as stdio.rs and FFI
- Audio injection — relay-received mic audio feeds into the VAD/STT pipeline as a
  virtual audio source (alongside or replacing local mic)
- TTS audio tapping — intercepts TTS output and forwards frames to connected companions

**Swift side — `FaeRelay.swift` (new in Fae macOS target):**
- `MCNearbyServiceAdvertiser` with service type `fae-relay`
- `MCSession` delegate handling connection lifecycle
- Bridges Multipeer Connectivity events to Rust relay via existing command channel
- Audio frame forwarding (binary `MCSession.send(_:toPeers:with:)`)

Note: Multipeer Connectivity is an Apple framework (Objective-C/Swift). The Mac side
must be implemented in Swift, bridging to the Rust core through the existing FFI/command
channel. The Rust side handles protocol logic; Swift handles the transport.

**Acceptance criteria:**
- Mac appears in Multipeer discovery from an iOS simulator
- JSON command/response round-trip works over Multipeer
- Orb state events stream to connected companion
- Audio frames (simulated) transmit in both directions

### Phase 3: FaeRelayClient — companion transport framework

**Goal:** Shared Swift framework that discovers and connects to the Mac's relay.

**Files to create:**
- `native/apple/FaeRelayKit/Package.swift`
- `native/apple/FaeRelayKit/Sources/FaeRelayKit/FaeRelayClient.swift` — discovery + connection
- `native/apple/FaeRelayKit/Sources/FaeRelayKit/AudioStreamer.swift` — mic capture + encode + send
- `native/apple/FaeRelayKit/Sources/FaeRelayKit/AudioPlayer.swift` — receive + decode + play
- `native/apple/FaeRelayKit/Sources/FaeRelayKit/RelayProtocol.swift` — frame parsing, JSON envelopes

**Key behaviors:**
- Auto-discovers Mac via `MCNearbyServiceBrowser`
- Connects and authenticates (iCloud identity or pairing code)
- Streams mic audio as binary frames (20ms chunks)
- Receives and plays TTS audio frames
- Receives and applies orb state events
- Receives conversation turn events
- Handles disconnection and reconnection gracefully
- Exposes `@Observable` state for SwiftUI binding (`isConnected`, `orbState`, etc.)

**Acceptance criteria:**
- iOS simulator connects to Mac's relay
- Mic audio captured on iOS reaches Mac's pipeline
- TTS audio from Mac plays on iOS device
- Orb state updates render on iOS within 50ms

### Phase 4: iOS / iPadOS companion app

**Goal:** Publishable companion app on the App Store.

**Files to create:**
- `native/apple/FaeCompanion/iOS/FaeCompanionApp.swift` — app entry
- `native/apple/FaeCompanion/iOS/CompanionContentView.swift` — main view
- `native/apple/FaeCompanion/iOS/CompanionConversationView.swift` — recent turns
- `native/apple/FaeCompanion/iOS/Info.plist` — microphone usage description, Bonjour services
- `native/apple/FaeCompanion/iOS/FaeCompanion.entitlements` — app groups, iCloud

**App structure:**
```
┌─────────────────────────┐
│      Connection bar     │  ← "Connected to David's MacBook" or "Searching..."
├─────────────────────────┤
│                         │
│                         │
│     CompanionOrbView    │  ← Full-size orb, centered
│      (from FaeOrbKit)   │
│                         │
│                         │
├─────────────────────────┤
│   Last 3 conversation   │  ← Scrollable, auto-hides after 15s
│   turns (optional)      │
├─────────────────────────┤
│  ◉ Tap to talk          │  ← Large touch target, or always-listening mode
└─────────────────────────┘
```

**Key behaviors:**
- Receives Handoff launch from Mac → restores conversation context
- Auto-discovers and connects to Mac relay
- Always-listening mode (when permitted) or tap-to-talk
- Orb reflects real-time state from Mac
- Conversation text appears briefly then fades
- Works in foreground and background (background audio session)
- Sends `goHome` command on disconnect or user request

**iPad adaptive layout:**
- Landscape: orb on left, conversation on right (split view)
- Portrait: same as iPhone but with larger orb

**App Store requirements:**
- Privacy manifest: microphone, local network discovery, iCloud
- Minimum iOS 17 (Multipeer Connectivity + Metal 3)
- Universal binary (iPhone + iPad)
- App review description: "Companion app for Fae — requires Fae running on a Mac"

**Acceptance criteria:**
- End-to-end voice conversation from iPhone to Mac and back
- Orb animation matches Mac in real-time
- Handoff from Mac launches companion and restores context
- "Go home" returns session to Mac
- Background audio session keeps mic/speaker active
- App passes Xcode Analyze with zero warnings

### Phase 5: Audio pipeline bridging (Rust)

**Goal:** Mac's VAD/STT pipeline accepts audio from a remote companion as a virtual
audio source.

**Files to modify:**
- `src/pipeline/coordinator.rs` — new `AudioSource` enum: `LocalMic`, `RemoteCompanion`
- `src/audio/` (or wherever mic capture lives) — accept injected PCM frames alongside
  CoreAudio capture
- `src/host/handler.rs` — route relay audio events into pipeline

**Key design:**
- When a companion is connected, the coordinator switches audio source to
  `RemoteCompanion` (remote mic replaces local mic)
- Local mic is muted (not capturing) while remote companion is active
- When companion disconnects, coordinator switches back to `LocalMic`
- Echo suppression applies to remote audio (companion's speaker is near companion's mic)
- VAD operates identically regardless of audio source

**Acceptance criteria:**
- Voice spoken into iPhone mic is transcribed by Mac's Whisper
- TTS output from Mac plays through iPhone speaker
- Echo suppression works for remote audio
- Switching between local and remote mic is seamless

### Phase 6: watchOS companion app

**Goal:** Minimal Watch companion with tap-to-talk and orb presence.

**Files to create:**
- `native/apple/FaeCompanion/watchOS/FaeCompanionWatchApp.swift`
- `native/apple/FaeCompanion/watchOS/WatchContentView.swift`
- `native/apple/FaeCompanion/watchOS/WatchRelayBridge.swift` — WCSession → iPhone relay
- `native/apple/FaeCompanion/watchOS/WatchOrbView.swift` — simplified orb

**Watch ↔ iPhone ↔ Mac relay chain:**
```swift
// Watch sends audio to iPhone
WCSession.default.sendMessageData(audioFrame, replyHandler: nil, errorHandler: nil)

// iPhone receives and forwards to Mac via MCSession
func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    relayClient.sendAudioFrame(messageData)
}

// Mac responds with TTS audio → iPhone → Watch
relayClient.onTTSAudio { frame in
    WCSession.default.transferUserInfo(["tts": frame])
}
```

**Watch UI:**
```
┌───────────────┐
│   ◯ orb ◯     │  ← Simplified gradient animation (or Metal on Series 9+)
│               │
│  "3:15 PM"    │  ← Last response text
│               │
│  [ 🎤 Talk ]  │  ← Tap or Digital Crown press to speak
└───────────────┘
```

**Complications:**
- Graphic corner: small orb icon with connection dot
- Inline: "Fae: Connected" / "Fae: Offline"
- Graphic rectangular: last assistant response snippet

**Acceptance criteria:**
- Tap-to-talk on Watch → transcribed on Mac → response plays on Watch speaker
- Orb color reflects Fae's current state
- Complication shows connection status
- Haptic tap (`.notification`) on assistant response
- Works with Watch speaker and with connected AirPods

### Phase 7: Settings and preferences

**Goal:** User-facing controls for companion features.

**macOS Settings (SettingsGeneralTab.swift):**
- Handoff toggle (existing: `handoffEnabled`)
- Relay toggle: enable/disable Multipeer advertising
- Connected companions list: show name, device type, connection duration
- Disconnect button per companion

**iOS Settings (in companion app):**
- Paired Mac: name, connection status
- Audio mode: always-listening vs tap-to-talk
- Show conversation text: on/off
- Auto-connect: on/off

**watchOS Settings (in companion app):**
- Same as iOS but minimal: paired Mac, audio mode

## Security considerations

### Audio privacy

- Mic audio streams only over encrypted Multipeer Connectivity channels
  (`MCEncryptionRequired`)
- Audio frames are never persisted on the companion device
- Companion does not cache conversation history beyond the current session
- Mic capture stops immediately on relay disconnect

### Authentication

- Primary: same iCloud account (verified during Multipeer invitation acceptance)
- Fallback: 6-digit pairing code entered once, stored in Keychain
- Session tokens rotate on each connection
- Only one companion per device type at a time

### Entitlements and privacy

Required entitlements for companion apps:

```xml
<!-- iOS / watchOS -->
<key>com.apple.developer.associated-domains</key>    <!-- iCloud identity -->
<key>com.apple.security.application-groups</key>      <!-- Shared Keychain -->
<key>NSMicrophoneUsageDescription</key>               <!-- Mic capture -->
<key>NSLocalNetworkUsageDescription</key>             <!-- Multipeer discovery -->
<key>NSBonjourServices</key>
<array><string>_fae-relay._tcp</string></array>
```

### Sandbox implications

- macOS Fae.app already has network entitlements for socket listener (Mode B)
- Multipeer Connectivity requires `com.apple.security.network.server` (macOS sandbox)
- iOS companion requires local network access (prompted once on first launch)

## Consequences

### Positive

- **Fae goes mobile** — users interact with Fae from pocket or wrist
- **Zero model downloads on companions** — all inference stays on Mac
- **Shared codebase** — `FaeHandoffKit`, `FaeOrbKit`, `FaeRelayKit` used across all platforms
- **Existing infrastructure reused** — Handoff, iCloud KV, Mode B protocol
- **Battery-friendly** — companions only stream audio, no local inference
- **Auto-discovery** — no manual IP entry, no port forwarding, just works

### Negative

- **Mac must be on** — companions are inert without the Mac brain (v1)
- **App Store overhead** — three targets to maintain, review, and update
- **Multipeer Connectivity limitations** — same local network or Bluetooth range required
- **Audio latency** — ~50-100ms round-trip over local WiFi (acceptable for voice)
- **watchOS constraints** — tiny screen, limited audio session, no direct MC support

### Deferred to future work

- **Remote relay** (v2) — route traffic over internet when Mac and companion are on
  different networks (Tailscale, WireGuard, or cloud relay)
- **Offline companion mode** (v3) — local Apple Speech STT + AVSpeechSynthesizer TTS +
  cloud LLM API fallback when Mac is unreachable
- **Multi-Mac** — companion discovers and switches between multiple Macs running Fae
- **Shared memory sync** — iCloud-based memory replication for read-only companion access
- **CarPlay** — voice-only Fae in the car (audio-only relay, no orb)

## Shared Swift package structure (final layout)

```
native/apple/
├── FaeHandoffKit/           ← existing: snapshot types, handoff contract
│   └── Sources/FaeHandoffKit/
│       ├── ConversationSnapshot.swift
│       └── FaeHandoffContract.swift
│
├── FaeOrbKit/               ← NEW: cross-platform orb rendering
│   ├── Package.swift        (platforms: .macOS(.v14), .iOS(.v17), .watchOS(.v10))
│   └── Sources/FaeOrbKit/
│       ├── OrbTypes.swift        (OrbMode, OrbFeeling, OrbPalette, OrbSnapshot)
│       ├── OrbAnimationState.swift
│       ├── OrbColor.swift
│       └── CompanionOrbView.swift (#if os(macOS) / os(iOS) / os(watchOS))
│   └── Resources/
│       └── fogCloudOrb.metal
│
├── FaeRelayKit/             ← NEW: companion ↔ Mac transport
│   ├── Package.swift        (platforms: .macOS(.v14), .iOS(.v17))
│   └── Sources/FaeRelayKit/
│       ├── FaeRelayClient.swift      (MCNearbyServiceBrowser, discovery)
│       ├── FaeRelayAdvertiser.swift   (MCNearbyServiceAdvertiser, Mac side)
│       ├── AudioStreamer.swift        (mic → binary frames)
│       ├── AudioPlayer.swift          (binary frames → speaker)
│       └── RelayProtocol.swift        (frame header, JSON envelopes)
│
├── FaeCompanion/            ← NEW: companion apps
│   ├── iOS/
│   │   ├── FaeCompanionApp.swift
│   │   ├── CompanionContentView.swift
│   │   └── CompanionConversationView.swift
│   ├── watchOS/
│   │   ├── FaeCompanionWatchApp.swift
│   │   ├── WatchContentView.swift
│   │   ├── WatchRelayBridge.swift
│   │   └── WatchOrbView.swift
│   └── Shared/
│       └── HandoffSessionModel.swift  (existing, moved from Templates/)
│
native/macos/
└── Fae/                     ← existing macOS app
    └── Package.swift        (now depends on FaeOrbKit, FaeRelayKit)
```

## References

- ADR-002: Embedded Rust Core Architecture (Mode A/B, command protocol)
- ADR-006: Voice Privilege Escalation (approval system carries over to companions)
- [Apple Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)
- [NSUserActivity & Handoff](https://developer.apple.com/documentation/foundation/nsuseractivity)
- [Handoff Continuation Streams](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/AdoptingHandoff/AdoptingHandoff.html)
- [Streaming Audio via Multipeer Connectivity (Thoughtbot)](https://thoughtbot.com/blog/streaming-audio-to-multiple-listeners-via-ios-multipeer-connectivity)
- [Streaming Audio on watchOS — WWDC19](https://developer.apple.com/videos/play/wwdc2019/716/)
- [WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity)
- `native/apple/FaeHandoffKit/` — existing shared contract package
- `native/macos/.../DeviceHandoff.swift` — existing handoff controller
- `native/macos/.../HandoffKVStore.swift` — existing iCloud KV fallback
- `src/host/stdio.rs` — existing Mode B JSON protocol
- `src/host/contract.rs` — existing command/event envelope schemas
