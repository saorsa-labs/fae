## Phase 4.2 Review Context

### Changed Files
- OnboardingController.swift — added requestCalendar() (EventKit), requestMail() (System Settings), 4-key permissionStates dict, AppKit+EventKit imports
- OnboardingTTSHelper.swift — added "calendar" and "mail" TTS help text cases
- OnboardingWindowController.swift — added "calendar" and "mail" permission switch cases
- onboarding.html — added Calendar card, Mail card, Privacy assurance banner, 3 CSS animation keyframes (cardGrantedPulse/cardDeniedShake/iconFadeIn), PERMISSION_CARDS JS map, refactored updatePermissionCard()

### Language: Swift 5.10 + HTML/CSS/JS (no Rust in changed files)
### Build: swift build passes with zero source warnings
