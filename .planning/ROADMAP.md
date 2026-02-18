# Fae Onboarding + Skill-Gated Permission System

## Problem Statement

Fae currently has no guided first-run experience — users are dropped into a raw voice
interface with no permissions granted. The existing LLM-conversational onboarding (asks
questions mid-chat) needs a proper visual UI flow. System permissions (mic, contacts,
calendar) aren't wired to skills, so Fae can't actually use them even when granted.

## Success Criteria

- 3-screen visual onboarding (Welcome → Permissions → Ready)
- Permission-gated skill system — skills only activate when required permissions granted
- TTS help button — Fae speaks to explain each permission and reassure about privacy
- Apple Contacts integration for personalization ("Hi, Benjamin")
- Deferred permission flow — skills request permissions just-in-time when first needed
- All existing tests pass, zero warnings, zero compilation errors
- Production ready: tested, polished, documented

---

## Milestone 1: Permission-Gated Skill Engine

Build the core permission registry and skill trait system in Rust. Each skill declares
required permissions; skills only activate when those permissions are granted. Wire the
existing `capability.request`/`capability.grant` host commands to persist permission
state and control skill activation.

### Phase 1.1: Permission Store + Config Schema

Add `PermissionStore` to config — persistent map of permission name → granted/denied
status with timestamps. Add `PermissionKind` enum (Microphone, Contacts, Calendar,
Reminders, Mail, Files, Notifications, Location, Camera, DesktopAutomation). Serialize
to config.toml under `[permissions]`.

**CRITICAL:** Add `onboarded: bool` flag to `SpeechConfig` (default `false`). The Swift
app checks this flag at launch — if `false`, show onboarding flow instead of main
conversation view. This catches existing test users who never completed onboarding.
The flag is set to `true` only when the user completes the final onboarding screen.
Query via `onboarding.get_state` host command, set via `onboarding.complete`.

**Key files:** `src/permissions.rs` (new), `src/config.rs`, `src/lib.rs`

### Phase 1.2: FaeSkill Trait + Built-in Skill Definitions

Create `FaeSkill` trait with `name()`, `description()`, `required_permissions()`,
`is_available()`, `prompt_fragment()`. Build skill definitions for Calendar, Contacts,
Mail, Reminders, Files, Notifications, Location, Camera, DesktopAutomation. Each
returns a prompt fragment that gets injected when the skill is active.

**Key files:** `src/skills/trait_def.rs` (new), `src/skills/builtins/` (new), `src/skills.rs`

### Phase 1.3: Wire Capability Bridge

Wire `FaeDeviceTransferHandler.request_capability()` and `grant_capability()` to
persist permission grants in `PermissionStore`. When a permission is granted, activate
corresponding skills. When denied, deactivate. Emit events so Swift UI can update.

**Key files:** `src/host/handler.rs`, `src/host/channel.rs`, `src/permissions.rs`

---

## Milestone 2: Onboarding UI + TTS Help

Build the 3-screen onboarding flow matching the mockup, with native macOS permission
requests, TTS-powered help button, and Apple Contacts integration.

### Phase 2.1: Onboarding State Machine (Rust)

Add `OnboardingPhase` enum (Welcome, Permissions, Ready, Complete) tracked in config.
Add host commands: `onboarding.get_state`, `onboarding.advance`, `onboarding.complete`.
Emit events when phase changes so Swift UI transitions.

**Key files:** `src/onboarding.rs` (new), `src/host/contract.rs`, `src/host/channel.rs`

### Phase 2.2: Onboarding HTML/JS Screens

Build the 3-screen onboarding UI in HTML/JS/CSS matching the mockup. Screens:
Welcome (Fae intro speech bubble), Permissions (mic + contacts toggles with help
buttons), Ready (personalized greeting + listening indicator). Animated transitions,
dot indicators, speaking animation.

**Key files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html` (new)

### Phase 2.3: Swift Bridge + Native Permission Requests

Create `OnboardingWebView.swift` to host the onboarding HTML. Wire JS message
handlers for permission toggles. Trigger native macOS permission dialogs
(`AVCaptureDevice.requestAccess`, `CNContactStore.requestAccess`). Report results
back to JS and Rust via host commands.

**Key files:** `OnboardingWebView.swift` (new), `OnboardingController.swift` (new)

### Phase 2.4: TTS Help Button + Privacy Reassurance Audio

When user taps help button on a permission card, Fae speaks via local TTS explaining
why the permission matters and reassuring about local-only processing. Pre-generate
help audio or synthesize on-demand via Kokoro TTS. Audio snippets:
- Microphone: "I need to hear you so we can talk naturally..."
- Contacts: "Your contact card helps me know your name..."
- Privacy: "Everything stays right here on your Mac..."

**Key files:** `src/tts/` integration, `OnboardingController.swift`, JS handlers

### Phase 2.5: Apple Contacts Integration

Read the user's "Me" contact card via CNContactStore when contacts permission is
granted. Extract first name, email, phone. Send to Rust via `config.patch` or
dedicated command. Use in the "Ready" screen greeting and in the onboarding memory
records.

**Key files:** `ContactsReader.swift` (new), `OnboardingController.swift`

---

## Milestone 3: Deferred Permission Flow + Integration

Just-in-time permission requests when skills need them, plus end-to-end testing.

### Phase 3.1: Just-in-Time Permission Request UI

When a skill needs an ungranted permission (e.g., user says "What's on my schedule?"
but Calendar isn't granted), Fae: (1) explains what she needs and why, (2) triggers
the native permission dialog via `capability.request`, (3) if granted, activates the
skill and fulfills the request. UI: permission sheet/popover with Fae explanation +
native dialog.

**Key files:** `ConversationWebView.swift`, `conversation.html`, `src/host/handler.rs`

### Phase 3.2: End-to-End Integration Tests

Full integration tests: onboarding lifecycle (init → advance → complete), permission
grant/deny → skill activation/deactivation, deferred permission flow, contacts
integration, TTS help synthesis. Rust-side tests + manual Swift verification checklist.

**Key files:** `tests/onboarding_lifecycle.rs` (new), `tests/permission_skill_gate.rs` (new)
