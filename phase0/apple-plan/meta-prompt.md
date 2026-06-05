> NON-AUTHORITATIVE SCRATCH ARTIFACT. This file was produced by a planning subagent and may overstate Phase 0 authorization. Do not use it as implementation authority; use `phase0/TEAM-PROMPT-phase0-clearing.md`, `phase0/phase0-clearing-status-2026-06-01.md`, and `docs/architecture/headless-core-impl-plan-2026-06-01.md` instead. No Phase 1 production code is approved until gate exit and owner signoff.

# Meta-Prompt: Swift Frontend Implementation

## Goal

Implement the Swift thin frontend architecture for Fae macOS, transforming the current monolithic Swift app into a lightweight UX shell that communicates with a Rust daemon.

## Context & Evidence

### Source Documents
- **Implementation plan**: `phase0/apple-plan/swift-frontend.md` — comprehensive architecture, protocol, migration strategy
- **Context inventory**: `phase0/apple-plan/context.md` — file map, patterns, risks
- **Design authority**: `docs/architecture/headless-core-impl-plan-2026-06-01.md` — Phase 0-5 roadmap, gates
- **Protocol reference**: `docs/adr/002-embedded-rust-core.md` — JSON command format basis (historical)

### Key Decisions Already Made
1. Swift retains: Apple tools (EventKit/Contacts), audio capture/playback, TCC permissions, UI, orb rendering
2. Daemon owns: Pipeline, scheduler, memory, STT/LLM/TTS engines
3. Transport: Unix socket primary (`~/.fae/fae.sock`), WebSocket fallback
4. Protocol: JSON command/event envelopes with binary audio framing
5. Migration: Feature flags allow gradual component-by-component transition

## Success Criteria

### Phase 1: DaemonConnection Stub
- [ ] `DaemonBridge/DaemonConnection.swift` created with connection state machine
- [ ] `DaemonBridge/CommandProtocol.swift` with JSON codec matching ADR-002 v2 format
- [ ] `DaemonBridge/HeartbeatMonitor.swift` with ping/pong and reconnection
- [ ] Unit tests for connection state transitions
- [ ] Swift builds and tests pass: `cd native/macos/Fae && swift build && swift test`

### Phase 2: Audio Bridge
- [ ] `DaemonBridge/AudioBridge.swift` streams mic PCM to daemon
- [ ] Binary audio framing (8-byte header + float32 samples)
- [ ] TTS audio from daemon plays through `AudioPlaybackManager`
- [ ] Barge-in signals from daemon stop playback <50ms

### Phase 3: Apple Tool Bridge
- [ ] `AppleBridge/AppleToolBridge.swift` handles `tool.execute_request` events
- [ ] `AppleBridge/TCCPermissionManager.swift` centralizes permission state
- [ ] Permission request flow: daemon → Swift → TCC dialog → Swift → daemon
- [ ] All existing Apple tool tests pass

### Integration Gate
- [ ] App launches, connects to mock daemon, displays ready state
- [ ] Mock daemon events update orb, conversation UI correctly
- [ ] Feature flags work: `useDaemonLLM = false` falls back to local MLX

## Hard Constraints

1. **Do not remove existing functionality yet** — Phase 1-3 add parallel paths, not replacements
2. **Swift code must compile and test**: `swift build && swift test` must pass at every commit
3. **No changes to `fae.db` schema** — memory migration is blocked on G4 gate
4. **Preserve ADR-002 latency SLOs**: IPC must stay under p95 ≤ 3ms
5. **Actor isolation**: New components must be `actor` types (DaemonConnection, AudioBridge)

## Suggested Approach

1. **Start with DaemonConnection** — the minimal viable bridge
   - Implement state machine: disconnected → connecting → connected → reconnecting
   - Use NIO or Foundation URLSessionWebSocketTask for WebSocket
   - Use Foundation.FileHandle for Unix socket
   - Add mock server for testing (returns canned events)

2. **Add AudioBridge** — wire existing AudioCaptureManager
   - New stream consumer that sends to daemon instead of local STT
   - Feature flag to switch between local and daemon paths
   - Test with mock daemon that echoes audio back as TTS

3. **Add AppleToolBridge** — lightweight dispatcher
   - Listen for `tool.execute_request` events
   - Route to existing CalendarTool/RemindersTool/etc
   - Send results back via `tool.execute_apple` command

4. **Refactor FaeCore** — make daemon optional
   - Add `@Published var daemonState: DaemonState`
   - In `start()`, try daemon connection first, fall back to local
   - Subscribe to daemon events, feed to existing FaeEventBus

## Validation

### Automated
```bash
cd native/macos/Fae
swift build
swift test
```

### Manual (after mock daemon exists)
1. Launch app with `FAE_USE_DAEMON=1` environment variable
2. Verify "Connecting..." → "Connected" state transition
3. Inject text, verify round-trip through mock daemon
4. Kill mock daemon, verify reconnection behavior

### Integration Checklist
- [ ] `docs/checklists/app-release-validation.md` steps still pass
- [ ] `docs/checklists/main-and-cowork-live-test-scenarios.md` scenarios work

## Stop / Escalation Rules

- **Stop** if changing protocol format — must match ADR-002 v2 for daemon compatibility
- **Escalate** if audio latency exceeds 5ms per hop (requires architecture review)
- **Escalate** if TCC permission flow requires changes to Info.plist entitlements
- **Escalate** if feature flag approach creates observable user-facing regressions
- **Escalate** before modifying `fae.db` schema or memory store paths

## Output Expectations

1. New files in `native/macos/Fae/Sources/Fae/DaemonBridge/` and `AppleBridge/`
2. Modified `FaeCore.swift` with daemon connection management
3. Updated unit tests in `Tests/`
4. No removal of existing code (that comes in Phase 4+)

## Resolved Questions

| Question | Answer | Source |
|----------|--------|--------|
| Transport protocol | WebSocket + Unix socket | swift-frontend.md §3 |
| Binary audio format | 8-byte header + float32 mono | swift-frontend.md §4.4 |
| Feature flag naming | `ff.daemon.*` in UserDefaults | swift-frontend.md §8.2 |
| Apple tools stay in Swift? | Yes, EventKit/Contacts require it | swift-frontend.md §2.1 |
| Daemon bundled in .app? | TBD (open question for owner) | swift-frontend.md §11 |

## Assumptions

1. Rust daemon will implement the v2 protocol as specified in `swift-frontend.md §4`
2. Unix socket path is always `~/.fae/fae.sock` (daemon creates, Swift connects)
3. Daemon handles scheduler leader election (Swift never runs scheduler when daemon connected)
4. Memory migration (G4) will be handled by daemon before Swift connects post-Phase-5
