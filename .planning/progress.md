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

## Phase 1.4: Runtime Events → FFI → Swift Callback - COMPLETE (via Phase 1.2)

All 26 RuntimeEvent variants mapped to EventEnvelope in Phase 1.2's `map_runtime_event()`.
No additional work needed.

### Milestone 1 Complete — 2026-02-19
### Core Pipeline & Linker Fix DONE

## Phase 2.1: BackendEventRouter Expansion (Swift) - COMPLETE

- [x] Task 1: Defined 8 typed notification names (faeTranscription, faeAssistantMessage, faeAssistantGenerating, faeToolExecution, faeOrbStateChanged, faeAudioLevel, faePipelineState, faeMemoryActivity)
- [x] Task 2: Route pipeline.transcription → .faeTranscription
- [x] Task 3: Route pipeline.assistant_sentence/generating → .faeAssistantMessage/.faeAssistantGenerating
- [x] Task 4: Route pipeline.tool_executing/tool_call/tool_result → .faeToolExecution
- [x] Task 5: Route orb.* events (state_changed/palette_set/cleared/feeling_set/urgency_set/flash_requested) → .faeOrbStateChanged
- [x] Task 6: Route pipeline.audio_level → .faeAudioLevel
- [x] Task 7: Route all remaining pipeline.* lifecycle events → .faePipelineState (set-based routing)
- [x] Task 8: Route pipeline.memory_* events → .faeMemoryActivity + full Swift build validation

Results: Swift build clean (zero errors, zero warnings). All 8 event categories now routed.
Previously only capability.requested was handled; now BackendEventRouter covers all 26 RuntimeEvent variants plus host-command echo events.

## Phase 2.2: Conversation Display Wiring (Swift) - COMPLETE

- [x] Task 1: ConversationBridgeController.swift (new) — @MainActor ObservableObject, observes faeTranscription/faeAssistantMessage/faeAssistantGenerating/faeToolExecution
- [x] Task 2: ConversationWebView.swift — added onWebViewReady callback, Coordinator stores it, fires after didFinish
- [x] Task 3: FaeTranscription → window.addMessage('user', text) + showConversationPanel (final segments only)
- [x] Task 4: faeAssistantMessage → stream accumulation + window.addMessage('assistant', text) on final
- [x] Task 5: faeAssistantGenerating → window.showTypingIndicator(active)
- [x] Task 6: faeToolExecution → window.addMessage('tool', ...) for executing/result
- [x] Task 7: FaeNativeApp.swift — @StateObject conversationBridge, environmentObject injection
- [x] Task 8: ContentView.swift — onWebViewReady: { conversationBridge.webView = webView }, Swift build clean

Results: Swift build clean (zero errors, zero warnings).
ConversationBridgeController is a retained @StateObject in FaeNativeApp that bridges pipeline events to the conversation WebView JS API.

## Phase 2.3: Orb State & Emotion Wiring (Swift) - COMPLETE

- [x] Task 1: OrbStateBridgeController.swift (new) — @MainActor ObservableObject, weak ref to OrbStateController
- [x] Task 2: Subscribe to .faeOrbStateChanged → map change_type to OrbPalette/OrbFeeling/OrbMode updates
- [x] Task 3: Subscribe to .faePipelineState (pipeline.mic_status) → listening/idle mode
- [x] Task 4: Subscribe to .faeAssistantGenerating → thinking/idle mode
- [x] Task 5: pipeline.control events → Start/Resume → listening, Stop/Pause → idle
- [x] Task 6: FaeNativeApp.swift — @StateObject orbBridge, wire orbBridge.orbState = orbState in onAppear
- [x] Task 7: Build clean (zero errors, zero warnings)

Results: OrbStateController now reflects live pipeline state automatically.

## Phase 2.4: Canvas, Audio Levels & Diagnostics (Swift) - COMPLETE

- [x] Task 1: PipelineAuxBridgeController.swift (new) — handles canvas visibility, audio level, pipeline status
- [x] Task 2: pipeline.canvas_visibility → window.showCanvasPanel() / hideCanvasPanel()
- [x] Task 3: .faeAudioLevel → window.setAudioLevel(rms) injection + @Published audioRMS
- [x] Task 4: pipeline.control/model_selected/provider_fallback → @Published status string
- [x] Task 5: SettingsView.swift — Pipeline section: status label + audioRMS ProgressView
- [x] Task 6: FaeNativeApp.swift — @StateObject pipelineAux, environmentObject injections for ContentView + Settings
- [x] Task 7: ContentView.swift — onWebViewReady also sets pipelineAux.webView
- [x] Task 8: Swift build clean (zero errors, zero warnings)

Results: Canvas panel visibility, audio level visualization, and pipeline diagnostics fully wired.

### Milestone 2 Complete — 2026-02-19
### Event Flow & UI Wiring DONE

Summary of Milestone 2:
- Phase 2.1: BackendEventRouter routes all 26+ RuntimeEvent types to 8 typed notifications
- Phase 2.2: ConversationBridgeController wires transcription/assistant/tool events to WebView JS
- Phase 2.3: OrbStateBridgeController wires pipeline state to OrbStateController (mode/palette/feeling)
- Phase 2.4: PipelineAuxBridgeController handles canvas visibility, audio levels, and settings diagnostics

## Milestone 3: Apple Ecosystem Tools

### Phase 3.1: Contacts & Calendar Tools — 2026-02-19

- [x] Task 1: AppleEcosystemTool trait in src/fae_llm/tools/apple/trait_def.rs
- [x] Task 2: ContactStore trait + SearchContactsTool (search_contacts)
- [x] Task 3: GetContactTool (get_contact)
- [x] Task 4: CreateContactTool (create_contact)
- [x] Task 5: CalendarStore trait + ListCalendarsTool + ListEventsTool
- [x] Task 6: CreateEventTool (create_calendar_event)
- [x] Task 7: UpdateEventTool + DeleteEventTool (update/delete with confirm guard)
- [x] Task 8: FFI bridge stubs, MockContactStore, MockCalendarStore, 58 tests, agent wiring

Results: 58 new tests pass, zero warnings, all 8 Apple tool types registered in agent.

### Phase 3.2: Reminders & Notes Tools — 2026-02-19

- [x] Task 1: ReminderStore trait + domain types + ListReminderListsTool + ListRemindersTool
- [x] Task 2: CreateReminderTool + SetReminderCompletedTool
- [x] Task 3: NoteStore trait + domain types + ListNotesTool + GetNoteTool
- [x] Task 4: CreateNoteTool + AppendToNoteTool
- [x] Task 5: UnregisteredReminderStore + UnregisteredNoteStore in ffi_bridge.rs (10 tests)
- [x] Task 6: MockReminderStore + MockNoteStore in mock_stores.rs
- [x] Task 7: Permission guard tests (Reminders + DesktopAutomation) in tool unit tests
- [x] Task 8: Agent wiring (8 new tools in build_registry()) + mod.rs exports + 54 unit tests

Commit: b4f160c
Results: 2107/2107 unit tests pass (+54 new), zero clippy warnings, zero fmt diff

### Phase 3.3: Mail Tool & Tool Registration — 2026-02-19

- [x] Task 1: MailStore trait + domain types (MailMessage, MailQuery, MailDraft)
- [x] Task 2: SearchMailTool (search_mail) + GetMailTool (get_mail)
- [x] Task 3: ComposeMailTool (compose_mail) with attachment support
- [x] Task 4: UnregisteredMailStore in ffi_bridge.rs
- [x] Task 5: MockMailStore in mock_stores.rs
- [x] Task 6: Agent wiring (3 new mail tools in build_registry())
- [x] Task 7: AvailabilityGatedTool permission-gating wrapper
- [x] Task 8: Integration tests (tests/apple_tool_registration.rs — 16 tests)

Commit: 917c29a
Results: all tests pass, zero warnings

### Phase 3.4: JIT Permission Flow — 2026-02-19

- [x] Task 1: SharedPermissionStore type alias (Arc<Mutex<PermissionStore>>) + JitPermissionRequest struct in permissions.rs
- [x] Task 2: AvailabilityGatedTool updated to use SharedPermissionStore (live lock) + optional JIT channel with 60s timeout
- [x] Task 3: FaeDeviceTransferHandler owns SharedPermissionStore; grant/deny update live store + emit permissions.changed event
- [x] Task 4: build_registry() + FaeAgentLlm::new_with_permissions() thread SharedPermissionStore through PipelineCoordinator
- [x] Task 5: capability.requested event enriched with jit: bool, tool_name: Option, tool_action: Option
- [x] Task 6: permissions.changed event emitted on every grant_capability/deny_capability
- [x] Task 7: JIT blocking flow in AvailabilityGatedTool (spin-loop 25ms/60s)
- [x] Task 8: 11 integration tests in tests/jit_permission_flow.rs (all pass)

Commit: 33a7655
Results: 2479/2479 tests pass, zero clippy warnings

### Milestone 3 Complete — 2026-02-19
### Apple Ecosystem Tools DONE

Summary of Milestone 3:
- Phase 3.1: Contacts & Calendar tools (8 tools: search/get/create contacts, list/create/update/delete events)
- Phase 3.2: Reminders & Notes tools (8 tools: list/create/complete reminders, list/get/create/append notes)
- Phase 3.3: Mail tools (3 tools: search/get/compose mail) + AvailabilityGatedTool permission gating
- Phase 3.4: JIT permission flow (SharedPermissionStore, live gates, enriched events, integration tests)

## Milestone 4: Onboarding Redesign

### Phase 4.1: Glassmorphic Design & Separate Window — 2026-02-19

- [x] Task 1: OnboardingWindowController.swift (separate NSWindow)
- [x] Task 2: NSVisualEffectView glassmorphic blur backdrop
- [x] Task 3: Warm color palette — soft gradients, rounded corners (onboarding.html)
- [x] Task 4: Slide transitions between phases
- [x] Task 5: Responsive layout (clamp-based sizing)
- [x] Task 6: Dark/light mode adaptation
- [x] Task 7: Animated orb greeting on Welcome screen
- [x] Task 8: Close onboarding window → open main window on completion

Results: Swift build clean (zero errors, zero warnings).

### Phase 4.2: Permission Cards with Help — 2026-02-19

- [x] Task 1: Calendar/Reminders permission card added to onboarding.html (📅 icon, data-permission="calendar")
- [x] Task 2: Mail/Notes permission card added to onboarding.html (✉️ icon, data-permission="mail")
- [x] Task 3: Privacy assurance banner (🔒 + help "?" button, glassmorphic warm-gold styling)
- [x] Task 4: Enhanced animated state transitions — cardGrantedPulse, cardDeniedShake, iconFadeIn keyframes; PERMISSION_CARDS map; shared updatePermissionCard() for all 4 cards
- [x] Task 5: TTS help text for "calendar" and "mail" in OnboardingTTSHelper.swift
- [x] Task 6: OnboardingController — "calendar" + "mail" in permissionStates; requestCalendar() via EventKit; requestMail() opens System Settings
- [x] Task 7: OnboardingWindowController wires "calendar" and "mail" permission cases
- [x] Task 8: Swift build clean (zero source errors, zero warnings); HTML validates OK

Results: Swift build clean (zero errors, zero warnings). All 4 permission cards functional end-to-end.

### Phase 4.3: App Integration & Release — 2026-02-19

- [x] Task 1: tests/llm_config_integration.rs — 9 config integration tests (round-trip, comments, unknown fields, partial updates, validation)
- [x] Task 2: tests/llm_toml_roundtrip.rs — 9 TOML round-trip preservation tests (comments, ordering, unknown sections, arrays-of-tables)
- [x] Task 3: src/fae_llm/docs/OPERATOR_GUIDE.md — complete operator guide (all providers, secret modes, tool modes, session, tracing, troubleshooting)
- [x] Task 4: src/fae_llm/docs/DEVELOPER_GUIDE.md + ARCHITECTURE.md — developer guide + architecture overview
- [x] Task 5: Public API audit — zero missing docs warnings; all pub exports documented and necessary; validate_config fixed to skip disabled providers
- [x] Task 6: Release candidate validation — just check passes (fmt, lint, build-strict, test, doc, panic-scan); 2493/2493 tests pass; zero warnings
- [x] Task 7: Final integration smoke test — tests/llm_final_smoke.rs (subsystem initialization); existing integration tests cover E2E
- [x] Task 8: Release readiness checklist — STATE.json → milestone_complete; zero TODO/FIXME; zero clippy warnings; zero doc warnings

Fixes applied:
- src/agent/mod.rs: fixed 2 clippy::field_reassign_with_default warnings in test code
- src/fae_llm/config/service.rs: validate_config now skips empty base_url check for disabled providers
- src/linker_anchor.rs: fixed 4 unresolved doc links (fully-qualified crate paths)
- src/pipeline/coordinator.rs: fixed SharedPermissionStore doc link
- src/fae_llm/tools/apple/availability_gate.rs: fixed with_jit_channel + JIT_TIMEOUT doc links

Results: 2493/2493 tests pass, zero clippy warnings, zero doc warnings, just check EXIT CODE: 0

### Milestone 4 Complete — 2026-02-19
### Onboarding Redesign DONE

Summary of Milestone 4:
- Phase 4.1: Glassmorphic Design & Separate Window (NSWindow, glassmorphic blur, warm palette, slide transitions, animated orb)
- Phase 4.2: Permission Cards with Help (calendar/mail cards, privacy banner, TTS help, OnboardingController wiring)
- Phase 4.3: App Integration & Release (config tests, TOML round-trip tests, operator/developer docs, API audit, release validation)

## Milestone 8: Python Skill Runtime (v0.8.1)

### Phase 8.1: Core Python Skill Runner — COMPLETE

- [x] Task 1: Error Types & Protocol Definitions (commit: 6f2e9ac)
- [x] Task 2: Process Lifecycle State Machine (commit: 85f0313)
- [x] Task 3: JSON-RPC 2.0 Communication Layer (commit: 1fa539b)
- [x] Task 4: Handshake & Health Check Protocol (commit: 20a3a37)
- [x] Task 5: Daemon vs One-Shot Mode (commit: f8ca441)
- [x] Task 6: Config Types & Directory Paths (commit: c1ac82f)
- [x] Task 7: ToolRegistry Integration (commit: 3c21254)
- [x] Task 8: Host Commands & Module Wiring (commit: 49e38b2)
- [x] Task 9: End-to-End Integration Tests (13 tests pass)

Results: All tests pass, zero clippy warnings, zero compilation warnings

### Phase 8.1 Complete — 2026-02-21
