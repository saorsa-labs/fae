# Phase 4.2: Permission Cards with Help

## Overview

Extends the glassmorphic onboarding (Phase 4.1) with a full set of permission
cards for Calendar/Reminders, Mail/Notes, and a Privacy Assurance section.
Microphone and Contacts cards are already implemented in Phase 4.1. This phase
adds the remaining cards, enriches TTS help text, and adds animated state
transitions for all permission states (pending → granted / denied).

## Current State (from Phase 4.1)

- `onboarding.html`: 3-screen flow (Welcome, Permissions, Ready)
  - Microphone card ✓, Contacts card ✓, help "?" buttons ✓, granted/denied state ✓
- `OnboardingTTSHelper.swift`: speaks help for "microphone", "contacts", "privacy"
- `OnboardingController.swift`: tracks microphone + contacts states, reads Me card
- `OnboardingWindowController.swift`: separate glassmorphic NSWindow (Phase 4.1)
- `OnboardingWebView.swift`: WKWebView bridge with permission state push API

## Tasks

### Task 1: Calendar/Reminders permission card in onboarding.html
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html`

Add a Calendar/Reminders permission card to Screen 2 (Permissions), after the
Contacts card:
- Icon: 📅, title: "Calendar & Reminders", desc: "I can help manage your schedule"
- data-permission="calendar" on the help and Allow buttons
- Card state updates from `window.setPermissionState("calendar", state)`

**Acceptance:** Card renders correctly in the permissions screen, receives state pushes.

### Task 2: Mail/Notes permission card in onboarding.html
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html`

Add a Mail/Notes permission card, after the Calendar card:
- Icon: ✉️, title: "Mail & Notes", desc: "I can help find and compose messages"
- data-permission="mail" on the help and Allow buttons
- Card state updates from `window.setPermissionState("mail", state)`

**Acceptance:** Card renders correctly, receives state pushes.

### Task 3: Privacy assurance section in onboarding.html
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html`

Add a privacy assurance banner below the permission cards (above the Continue
button) on Screen 2:
- A small lock icon 🔒 with text: "Everything stays on your Mac. I never send data anywhere."
- Styled with the warm-gold accent, subtle glass card background
- Includes a help "?" button that triggers TTS "privacy" speech

**Acceptance:** Privacy assurance renders with correct styling.

### Task 4: Enhanced animated state transitions in onboarding.html
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html`

Improve the granted/denied card animations:
- Add a smooth scale pulse (scale 1.02 → 1.0) on state change
- Granted: green checkmark icon swaps in with a fade-in animation
- Denied: subtle shake animation (translateX keyframes)
- All 4 cards (microphone, contacts, calendar, mail) use the same animation system

Also extract `updatePermissionCard()` into a shared function that handles all
card IDs by permission name.

**Acceptance:** All 4 cards animate correctly on state change.

### Task 5: TTS help text for calendar and mail in OnboardingTTSHelper.swift
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/OnboardingTTSHelper.swift`

Add help text cases for "calendar" and "mail":
- calendar: "I can help manage your schedule — creating reminders, checking
  appointments, and keeping you organised. Everything stays on your Mac."
- mail: "I can help you find emails and draft messages. I never send anything
  without you telling me to, and all data stays private on your Mac."

**Acceptance:** `speak(permission: "calendar")` and `speak(permission: "mail")`
produce appropriate TTS output. Zero warnings.

### Task 6: OnboardingController permission state tracking for calendar and mail
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/OnboardingController.swift`

Add "calendar" and "mail" to the `permissionStates` dictionary initial values:
```swift
@Published var permissionStates: [String: String] = [
    "microphone": "pending",
    "contacts": "pending",
    "calendar": "pending",
    "mail": "pending",
]
```

Add `requestCalendar()` and `requestMail()` methods that use EventKit
`EKEventStore.requestAccess(to:)` for calendar and reminder access. Note: for
Mail/Notes, the permission is a macOS Full Disk Access or Automation permission;
for Phase 4.2, just show the state as "pending" and allow the user to grant via
System Settings (show an alert explaining this).

**Acceptance:** Controller tracks all 4 permission states. Zero warnings. Swift
build clean.

### Task 7: Wire new permissions through OnboardingWindowController
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/OnboardingWindowController.swift`,
           `native/macos/FaeNativeApp/Sources/FaeNativeApp/OnboardingWebView.swift`

Update `OnboardingContentView` to handle "calendar" and "mail" permission requests:
```swift
case "calendar":
    onboarding.requestCalendar()
case "mail":
    onboarding.requestMail()
```

All 4 permission types are now wired end-to-end: JS button → Swift handler →
state update → webView.setPermissionState push.

**Acceptance:** Tapping each card's Allow button triggers the correct Swift path.
Swift build clean.

### Task 8: Swift build validation and progress log update
**Files:** All modified Swift + HTML files

Run the Swift build to confirm zero errors and zero warnings:
```bash
swift build --package-path native/macos/FaeNativeApp 2>&1 | tail -20
```

Update `.planning/progress.md` with Phase 4.2 completion entry.

**Acceptance:** Swift build passes clean. progress.md updated. State JSON updated.
