# Progress Log

## Phase 1.1: FFI Surface

- [x] Task 1-2: src/ffi.rs skeleton + Cargo.toml [lib] crate-type
- [x] Task 3: FaeRuntime struct + fae_core_init
- [x] Task 4: fae_core_start / fae_core_stop
- [x] Task 5: fae_core_send_command (CommandEnvelope → ResponseEnvelope round-trip)
- [x] Task 6: fae_string_free (null-safe CString reclaim)
- [x] Task 7: fae_core_poll_event (non-blocking broadcast try_recv)
- [x] Task 8: fae_core_set_event_callback (synchronous dispatch during send_command)
- [x] Task 9: FaeInitConfig serde struct
- [x] Task 10: include/fae.h C header with full documentation
- [x] Task 11: tests/ffi_abi.rs — 6 ABI-level tests, all passing
- [x] Task 12: justfile staticlib recipes + nm symbol verification (8/8 symbols)

## Phase 2.1: Onboarding State Machine (Rust) - COMPLETE

- [x] Task 1: src/onboarding.rs - OnboardingPhase enum with advance/as_str/parse/Display (6 unit tests)
- [x] Task 2: src/config.rs - onboarding_phase field in SpeechConfig
- [x] Task 3: src/lib.rs - pub mod onboarding registered
- [x] Task 4: src/host/contract.rs - OnboardingAdvance command ("onboarding.advance")
- [x] Task 5: src/host/channel.rs - advance_onboarding_phase() trait + route handler + event
- [x] Task 6: tests/host_contract_v0.rs + tests/host_command_channel_v0.rs - 4 new tests

Commit: 9fccad1
Results: 2261/2261 tests pass, zero clippy warnings, zero doc warnings

## Phase 2.2: Onboarding HTML/JS Screens - COMPLETE

- [x] Task 1: native/.../Resources/Onboarding/onboarding.html — 3-screen onboarding UI with orb animation, permission cards, dot indicators, Swift bridge

Commit: a28e118

## Phase 2.3: Swift Bridge + Native Permission Requests - COMPLETE

- [x] Task 1: OnboardingController.swift — @MainActor ObservableObject, requestMicrophone/requestContacts, notifications
- [x] Task 2: OnboardingWebView.swift — NSViewRepresentable, WKWebView, JS message handlers, setPermissionState/setUserName push APIs
- [x] Task 3: ContentView.swift — onboarding gate (isComplete), onboardingView/conversationView split
- [x] Task 4: HostCommandBridge.swift — faeOnboardingAdvance/Complete notification observers

Commit: d256956

## Phase 2.4: TTS Help Button + Privacy Reassurance Audio - COMPLETE

- [x] Task 1: OnboardingTTSHelper.swift — AVSpeechSynthesizer wrapper with microphone/contacts/privacy help scripts
- [x] Task 2: ContentView.swift — onPermissionHelp wired to onboardingTTS.speak(permission:)

Commit: e4cf4ed

## Phase 2.5: Apple Contacts Integration - COMPLETE

- [x] Task 1: OnboardingController.swift — permissionStates @Published property, readMeCard from CNContactStore Me card
- [x] Task 2: OnboardingWebView.swift — userName/permissionStates input props, lastUserName/lastPermissionStates tracking, updateNSView push logic
- [x] Task 3: ContentView.swift — pass userName/permissionStates to OnboardingWebView

Commit: 8710191
Swift build: clean (zero errors, zero source warnings)

### Milestone 2 Complete — 2026-02-18

## Phase 3.1: Just-in-Time Permission Request UI - COMPLETE

- [x] Task 1: src/host/channel.rs — jit field in CapabilityRequestPayload + event propagation
- [x] Task 2: tests/host_command_channel_v0.rs — 2 new jit field tests
- [x] Task 3: ProcessCommandSender.swift — parseEventLine dispatches faeCapabilityRequested
- [x] Task 4: JitPermissionController.swift (NEW) — native permission dialogs mid-conversation
- [x] Task 5: HostCommandBridge.swift — faeCapabilityGranted/Denied observers → grant/deny dispatch
- [x] Task 6: FaeNativeApp.swift — JitPermissionController @StateObject retained

Commit: 5544595
Results: 2263/2263 Rust tests pass, Swift build clean

## Phase 3.2: End-to-End Integration Tests - COMPLETE

- [x] Task 1: src/host/handler.rs — advance_onboarding_phase() impl + phase in query_onboarding_state
- [x] Task 2: src/host/handler.rs — 4 new handler unit tests (phase cycling, persistence, state)
- [x] Task 3: tests/onboarding_lifecycle.rs (NEW) — 6 full lifecycle integration tests
- [x] Task 4: tests/capability_bridge_e2e.rs — 3 JIT capability integration tests

Commit: 4d165f4
Results: 2275/2275 Rust tests pass, zero warnings

### Milestone 3 Complete — 2026-02-18
### All milestones complete — project fae-onboarding-skill-system DONE

---

# Project: fae-native-production-readiness

## Phase 1.1: Linker Anchor - COMPLETE

Commit: 034ae6c

## Phase 1.2: Wire runtime.start to PipelineCoordinator - COMPLETE

- [x] Task 1: Add PipelineState enum + pipeline fields to FaeDeviceTransferHandler
- [x] Task 2: Wire handler construction in ffi.rs (shared broadcast channel)
- [x] Task 3: Model loading in request_runtime_start via initialize_models_with_progress
- [x] Task 4: Create and spawn PipelineCoordinator with all channels
- [x] Task 5: Event bridge — map 26 RuntimeEvent variants → EventEnvelope
- [x] Task 6: Implement runtime.stop (cancel+abort+cleanup) and runtime.status (state/error/uptime)
- [x] Task 7: Update tests for new constructor (handler, integration tests)
- [x] Task 8: Lifecycle integration tests (events, channels, restart)

Results: 2001 unit + 54 GUI + 44 doc + integration tests pass, zero warnings

Commit: ff1458d

### Phase 1.2 Complete — 2026-02-19

**NOTE**: Phase 1.2 implementation also completed much of Phase 1.3 and all of Phase 1.4:
- Phase 1.3 Tasks 1-3, 7 already done (text injection, gate commands, channel-not-ready handling, error propagation)
- Phase 1.4 COMPLETE (all 26 RuntimeEvent variants mapped to EventEnvelope in map_runtime_event())

## Phase 1.3: Wire Text Injection & Gate Commands - COMPLETE

Tasks 1-3,7 were covered by Phase 1.2. Remaining tasks implemented:
- [x] Task 4: Wire approval.respond to tool_approval channel (pending_approvals registry, approval bridge task, approval.requested events)
- [x] Task 5: Wire orb.palette.set/feeling.set/clear/urgency/flash to emit orb.state_changed events
- [x] Task 6: Wire scheduler CRUD to persisted scheduler module (upsert/remove/mark_due_now with corruption recovery)
- [x] Task 8: Integration tests in tests/phase_1_3_wired_commands.rs (13 tests, all pass)

Results: all tests pass, zero clippy warnings, zero compilation warnings

Commit: 46d050c

### Phase 1.3 Complete — 2026-02-19
