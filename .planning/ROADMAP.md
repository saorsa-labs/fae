# Fae Native macOS App — Production Readiness Roadmap

## Project Overview

Take Fae native macOS app from UI shell to full production readiness. The app has a Swift UI shell (orb, onboarding, conversation webviews) connected to a Rust backend via C ABI (libfae.a), but the backend command handlers are stubs, the audio/STT/LLM/TTS pipeline is not wired, Apple ecosystem tools are missing, handoff doesn't work, and the UI is disconnected from the backend.

## Architecture

```
Swift UI (WKWebView)
  ├─ OrbWebView         — animated orb with mode/palette/feeling
  ├─ ConversationWebView — chat, listening, canvas panels
  └─ OnboardingWebView   — permission flow, welcome, ready
        │
        ▼ (NotificationCenter → HostCommandBridge)
  EmbeddedCoreSender (C ABI)
        │
        ▼ (fae_core_send_command / fae_core_set_event_callback)
  Rust FFI (ffi.rs)
        │
        ▼ (mpsc command channel)
  HostCommandServer → FaeDeviceTransferHandler (STUBS)
        │
        ▼ (NEEDS WIRING)
  PipelineCoordinator
    ├─ Audio Capture (cpal) → VAD → STT (Parakeet)
    ├─ LLM (mistral.rs) → Tool Dispatch → Agent
    └─ TTS (Kokoro) → Playback (cpal)
```

## Success Criteria

- Production ready: complete, tested, documented
- Voice pipeline fully functional (listen → understand → respond → speak)
- Apple ecosystem tools functional (contacts, calendar, reminders, mail, notes)
- Orb reflects real-time emotion during conversation
- World-class glassmorphic onboarding with conversational help
- Device handoff works (Mac ↔ iPhone ↔ Watch)
- Zero clippy warnings, zero test failures

---

## Milestone 1: Core Pipeline & Linker Fix

**Goal**: Make Fae's voice pipeline actually start, accept input, and produce output.

### Phase 1.1: Linker Anchor & Anti-Dead-Strip (8 tasks)

**Problem**: SPM's `-dead_strip` removes all ML code (mistralrs, kokoro, parakeet) because the FFI entry points don't transitively reference them. Binary dropped from ~100MB to 9MB.

**Solution**: Add a Rust-side anchor function that references all subsystem entry points, exported as `extern "C"` so the linker sees direct references.

- Task 1: Create `src/linker_anchor.rs` with `#[no_mangle] pub extern "C" fn _fae_link_anchor()`
- Task 2: Reference PipelineCoordinator::new, ParakeetStt, KokoroTts, LocalLlm
- Task 3: Reference audio capture/playback, VAD, AEC entry points
- Task 4: Reference memory, scheduler, canvas, agent subsystems
- Task 5: Add anchor to lib.rs exports
- Task 6: Update Package.swift — keep `-force_load`, add `_fae_link_anchor` call from Swift
- Task 7: Verify binary size restored (~100MB+)
- Task 8: Integration test — symbol count verification

### Phase 1.2: Wire runtime.start to PipelineCoordinator (8 tasks)

**Problem**: `request_runtime_start()` just logs and returns Ok(). No pipeline is spawned.

**Solution**: Handler spawns PipelineCoordinator with models, text injection, gate commands, and emits events back through the broadcast channel.

- Task 1: Add pipeline channels to FaeDeviceTransferHandler (text_injection_tx, gate_cmd_tx, runtime_event_rx)
- Task 2: Implement model loading in runtime.start (download + initialize)
- Task 3: Build PipelineCoordinator with_models, with_text_injection, with_gate_commands
- Task 4: Spawn pipeline on tokio runtime, store JoinHandle
- Task 5: Forward RuntimeEvents from pipeline broadcast → FFI event broadcast
- Task 6: Implement runtime.stop to cancel pipeline CancellationToken
- Task 7: Implement runtime.status with real pipeline state
- Task 8: Integration test — start/stop lifecycle

### Phase 1.3: Wire Text Injection & Gate Commands (8 tasks)

**Problem**: `conversation.inject_text` and `conversation.gate_set` are stubs.

**Solution**: Forward these commands through the pipeline's text injection and gate channels.

- Task 1: Wire request_conversation_inject_text → text_injection_tx.send()
- Task 2: Wire request_conversation_gate_set → gate_cmd_tx.send()
- Task 3: Handle channel-not-ready state (pipeline not started yet)
- Task 4: Wire approval.respond to tool_approval channel
- Task 5: Wire orb.palette.set/feeling.set to emit OrbStateChanged events
- Task 6: Wire scheduler CRUD to actual scheduler module
- Task 7: Error propagation from channel sends to ResponseEnvelope
- Task 8: Integration tests for all wired commands

### Phase 1.4: Runtime Events → FFI → Swift Callback (8 tasks)

**Problem**: PipelineCoordinator emits RuntimeEvents but they never reach Swift.

**Solution**: Bridge pipeline's broadcast::Sender<RuntimeEvent> → FFI event broadcast → Swift callback.

- Task 1: Map RuntimeEvent variants to EventEnvelope JSON payloads
- Task 2: Emit Transcription events (user speech text)
- Task 3: Emit AssistantSentence events (LLM response text)
- Task 4: Emit ToolCall/ToolResult events
- Task 5: Emit AssistantAudioLevel events (for visualization)
- Task 6: Emit Control events (pipeline state changes)
- Task 7: Emit MemoryRecall/MemoryWrite events
- Task 8: Integration test — event roundtrip from pipeline to FFI

---

## Milestone 2: Event Flow & UI Wiring

**Goal**: Connect all backend events to Swift UI — conversation display, orb state, panels.

### Phase 2.1: BackendEventRouter Expansion (8 tasks)

**Problem**: BackendEventRouter only routes `capability.requested`. All other events are dropped.

- Task 1: Define typed notification names for all event categories
- Task 2: Route transcription events → .faeTranscription notification
- Task 3: Route assistant sentence events → .faeAssistantMessage notification
- Task 4: Route tool call/result events → .faeToolExecution notification
- Task 5: Route orb state events (mode, feeling, palette) → .faeOrbStateChanged
- Task 6: Route audio level events → .faeAudioLevel
- Task 7: Route pipeline control events → .faePipelineState
- Task 8: Route memory events → .faeMemoryActivity

### Phase 2.2: Conversation Display Wiring (8 tasks)

**Problem**: ConversationWebView shows static HTML. No messages appear.

- Task 1: ConversationController subscribes to assistant message notifications
- Task 2: Push assistant text to WebView via JS bridge (window.addAssistantMessage)
- Task 3: Push user transcription to WebView (window.addUserMessage)
- Task 4: Push tool execution status to WebView (window.showToolExecution)
- Task 5: Push typing/generating indicator (window.setAssistantGenerating)
- Task 6: Handle message streaming (partial sentences during generation)
- Task 7: Handle error display in conversation
- Task 8: Integration tests for conversation event flow

### Phase 2.3: Orb State & Emotion Wiring (8 tasks)

**Problem**: Orb stays static. No mode changes, no emotion colors.

- Task 1: OrbStateController subscribes to pipeline state notifications
- Task 2: Map pipeline state → OrbMode (idle/listening/thinking/speaking)
- Task 3: Wire sentiment detection output → OrbFeeling
- Task 4: Wire emotion → palette selection (auto-palette when .modeDefault)
- Task 5: Push mode transitions on conversation start/stop
- Task 6: Push feeling transitions during LLM response generation
- Task 7: Handle orb flash for tool completion/error
- Task 8: Integration tests for orb state transitions

### Phase 2.4: Canvas, Audio Levels & Diagnostics (8 tasks)

- Task 1: Wire canvas panel open/close to canvas session registry
- Task 2: Push canvas renders from pipeline → WebView
- Task 3: Wire audio level events → listening visualization in WebView
- Task 4: Display model loading progress in UI
- Task 5: Display pipeline state in settings/debug view
- Task 6: Wire runtime.status to real diagnostic data
- Task 7: Error toast display for pipeline failures
- Task 8: Integration tests for auxiliary UI features

---

## Milestone 3: Apple Ecosystem Tools

**Goal**: Give Fae's LLM access to macOS system data (contacts, calendar, reminders, mail, notes) through permission-gated tools.

### Phase 3.1: Contacts & Calendar Tools (8 tasks)

- Task 1: Define AppleEcosystemTool trait extending existing Tool trait
- Task 2: ContactsTool — search contacts by name/email/phone (CNContactStore)
- Task 3: ContactsTool — read contact details (phone, email, address, birthday)
- Task 4: ContactsTool — create new contact
- Task 5: CalendarTool — list calendars and upcoming events (EventKit)
- Task 6: CalendarTool — create calendar event with title, date, reminders
- Task 7: CalendarTool — update/delete events
- Task 8: Unit tests with mock stores

### Phase 3.2: Reminders & Notes Tools (8 tasks)

- Task 1: RemindersTool — list reminder lists and items (EventKit)
- Task 2: RemindersTool — create reminder with due date, priority
- Task 3: RemindersTool — complete/uncomplete reminder
- Task 4: NotesTool — list notes via AppleScript/Shortcuts
- Task 5: NotesTool — read note content
- Task 6: NotesTool — create/append to note
- Task 7: Permission guard — tools check PermissionStore before execution
- Task 8: Unit tests with mock bridges

### Phase 3.3: Mail Tool & Tool Registration (8 tasks)

- Task 1: MailTool — compose email (NSSharingService or scripting bridge)
- Task 2: MailTool — search inbox (AppleScript bridge to Mail.app)
- Task 3: MailTool — read email details
- Task 4: Register Apple tools in ToolRegistry with permission gating
- Task 5: Dynamic tool availability — tools appear when permission granted
- Task 6: Tool descriptions for LLM — clear schema + usage examples
- Task 7: Rate limiting for Apple ecosystem API calls
- Task 8: Integration tests for full tool registration flow

### Phase 3.4: JIT Permission Flow (8 tasks)

**Problem**: LLM needs to request permission mid-conversation when it wants to use a tool.

- Task 1: Enhance capability.request to include tool context (what LLM wants to do)
- Task 2: Swift JitPermissionController shows native dialog with Fae's explanation
- Task 3: On grant → register tool immediately, resume LLM turn
- Task 4: On deny → LLM gets graceful "permission denied" tool result
- Task 5: Persist grants across sessions
- Task 6: Allow revocation from Settings → tools are deregistered
- Task 7: Show granted permissions in conversation UI
- Task 8: End-to-end test — LLM requests contacts → dialog → grant → tool works

---

## Milestone 4: Onboarding Redesign

**Goal**: World-class Apple-style glassmorphic onboarding with separate windows and conversational help.

### Phase 4.1: Glassmorphic Design & Separate Window (8 tasks)

- Task 1: Create OnboardingWindow as separate NSWindow (not embedded in main)
- Task 2: Apply NSVisualEffectView for glassmorphic blur backdrop
- Task 3: Design warm color palette — soft gradients, rounded corners
- Task 4: Implement slide transitions between phases
- Task 5: Responsive layout for different screen sizes
- Task 6: Dark/light mode adaptation
- Task 7: Animated orb greeting on Welcome screen
- Task 8: Close onboarding window → open main window on completion

### Phase 4.2: Permission Cards with Help (8 tasks)

- Task 1: Permission card component — icon, title, description, grant button
- Task 2: "?" help button → Fae speaks conversational explanation
- Task 3: Microphone card — "I need to hear you so we can talk naturally"
- Task 4: Contacts card — "I can learn your name and help with people you know"
- Task 5: Calendar/Reminders card — "I can help manage your schedule"
- Task 6: Mail/Notes card — "I can help find and compose messages"
- Task 7: Privacy assurance — "Everything stays on your Mac. I never send data anywhere."
- Task 8: Animated state transitions (pending → granted/denied)

### Phase 4.3: Model Download & First-Run Experience (8 tasks)

- Task 1: Model download progress screen with estimated time
- Task 2: Download STT, LLM, TTS models with retry logic
- Task 3: Voice test — "Say hello to make sure I can hear you"
- Task 4: Personality greeting — Fae introduces herself by name
- Task 5: Smooth transition animation from onboarding to main experience
- Task 6: Skip/defer option for optional permissions
- Task 7: Resume interrupted downloads on next launch
- Task 8: Integration test for full onboarding flow

---

## Milestone 5: Handoff & Production Polish

**Goal**: Device handoff, error resilience, and production hardening.

### Phase 5.1: Device Handoff (8 tasks)

- Task 1: NSUserActivity with full conversation state serialization
- Task 2: iCloud key-value store for session continuity
- Task 3: Handoff UI — show available devices, transfer button
- Task 4: Receive handoff on target device — restore conversation
- Task 5: Handle offline/disconnected gracefully
- Task 6: Handoff status in orb (flash on transfer)
- Task 7: Settings for handoff enable/disable
- Task 8: Manual test plan for handoff scenarios

### Phase 5.2: Error Recovery & Resilience (8 tasks)

- Task 1: Pipeline crash recovery — auto-restart with backoff
- Task 2: Model corruption detection — re-download on checksum mismatch
- Task 3: Audio device hot-swap handling
- Task 4: Network resilience for external LLM fallback
- Task 5: Memory pressure handling — reduce model quality on low RAM
- Task 6: Graceful degradation — text-only mode when STT/TTS unavailable
- Task 7: Diagnostic logging with log rotation
- Task 8: Crash reporting framework integration

### Phase 5.3: Accessibility & Final Polish (8 tasks)

- Task 1: VoiceOver support for all UI elements
- Task 2: Keyboard navigation for conversation and panels
- Task 3: High contrast mode support
- Task 4: Reduce motion preferences
- Task 5: Performance profiling and optimization
- Task 6: Memory leak detection and fixes
- Task 7: App Store metadata and screenshots
- Task 8: Release build validation and signing
