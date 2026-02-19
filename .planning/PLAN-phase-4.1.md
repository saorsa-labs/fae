# Phase 4.1: Glassmorphic Design & Separate Window

## Overview

Redesign onboarding to use a dedicated NSWindow with Apple-style glassmorphic blur, warm color palette, slide transitions, and responsive layout. Currently, onboarding is embedded inside ContentView's ZStack in the same WindowGroup as the conversation. This phase extracts it into a separate window with vibrancy effects.

## Context

- **Current architecture:** Single `WindowGroup("Fae")` in `FaeNativeApp.swift`. `ContentView` switches between `OnboardingWebView` and conversation via `onboarding.isComplete` flag.
- **Current onboarding:** WKWebView loading `Resources/Onboarding/onboarding.html` — 3 screens (Welcome, Permissions, Ready) with CSS opacity/translateY transitions on a dark (#0a0b0d) background. Canvas-based orb animation already exists.
- **Swift framework:** SwiftUI App protocol + AppKit NSWindow access via `NSWindowAccessor`. Minimum macOS 14.
- **Onboarding controller:** `OnboardingController.swift` manages state, permission requests, and posts NotificationCenter events.
- **Key files:**
  - `FaeNativeApp.swift` — app entry point, WindowGroup scene
  - `ContentView.swift` — view switching logic
  - `OnboardingController.swift` — permission state, completion
  - `OnboardingWebView.swift` — WKWebView hosting onboarding.html
  - `OnboardingTTSHelper.swift` — TTS for permission help
  - `WindowStateController.swift` — collapsed/compact/expanded modes
  - `Resources/Onboarding/onboarding.html` — HTML/CSS/JS for screens
- **Constraints:** No .unwrap()/.expect() in Swift production code, zero compiler warnings, accessible
- **Test count:** 2490 passing Rust tests (not touching Rust this phase)

## Tasks

### Task 1: Create OnboardingWindowController with programmatic NSWindow
**Files:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/OnboardingWindowController.swift` (new)

Create a new `OnboardingWindowController` class that owns a programmatic `NSWindow` for the onboarding experience. The window should:
- Be a centered, fixed-size (520x640) titled window with no minimize/maximize
- Have `.fullSizeContentView` styleMask so content extends behind titlebar
- Set `titlebarAppearsTransparent = true` and `titleVisibility = .hidden`
- Use `NSVisualEffectView` as the window's `contentView` with `.behindWindow` blending mode and `.hudWindow` material for glassmorphic blur
- Prevent closing via the close button during onboarding (override `windowShouldClose`)
- Be `@MainActor` and `ObservableObject` so SwiftUI can observe it

**Acceptance:**
- Window opens centered on screen with transparent titlebar
- Background shows glassmorphic blur of desktop content
- Window cannot be closed/minimized during onboarding
- Compiles with zero warnings

### Task 2: Host OnboardingWebView inside the glassmorphic window
**Files:** `OnboardingWindowController.swift`, `OnboardingWebView.swift`

Embed the existing `OnboardingWebView` (WKWebView) inside the new glassmorphic window:
- Create an `NSHostingView` wrapping the `OnboardingWebView` SwiftUI view
- Add it as a subview of the `NSVisualEffectView` content view, pinned with AutoLayout
- Wire all existing callbacks (onRequestPermission, onPermissionHelp, onComplete, onAdvance) through
- Make the WKWebView background transparent so the NSVisualEffectView blur shows through
- Pass `userName` and `permissionStates` from `OnboardingController` via existing update mechanism

**Acceptance:**
- Onboarding HTML renders inside the glassmorphic window
- Desktop blur visible through the WKWebView background areas
- All permission buttons trigger native dialogs correctly
- Complete button fires onboardingComplete notification

### Task 3: Update FaeNativeApp to show onboarding window → main window lifecycle
**Files:** `FaeNativeApp.swift`, `ContentView.swift`, `OnboardingWindowController.swift`

Change the app startup flow:
- On launch, if `!onboarding.isComplete`, show the onboarding window instead of the main WindowGroup
- The main window should NOT be visible during onboarding
- When onboarding completes, close the onboarding window and show the main window
- If user has already completed onboarding (restored from backend), skip directly to main window
- Handle edge case: backend timeout → show onboarding window (safe default)

Implementation approach:
- Add `@StateObject var onboardingWindow = OnboardingWindowController()` in FaeNativeApp
- In `.onAppear`, after `restoreOnboardingState`, decide which window to show
- `OnboardingWindowController.show()` opens the onboarding window
- On `onboarding.isComplete` change → close onboarding, make main window key

**Acceptance:**
- Fresh launch: only onboarding window visible, main window hidden
- After completing onboarding: smooth transition to main window
- Subsequent launches: main window opens directly, no onboarding flash
- Backend timeout: shows onboarding (safe fallback)

### Task 4: Redesign onboarding.html with warm glassmorphic palette and rounded panels
**Files:** `Resources/Onboarding/onboarding.html`

Redesign the CSS for a warm, Apple-style glassmorphic aesthetic:
- Replace dark `--bg: #0a0b0d` with `transparent` body background (blur comes from NSVisualEffectView)
- New warm color variables: `--warm-amber: #F5E6D0`, `--warm-rose: #E8C4C4`, `--accent: #D4956A`, `--text-primary: rgba(0,0,0,0.85)` for light mode
- Permission cards: white/translucent background with `backdrop-filter: blur(20px)`, larger border-radius (20px), subtle warm shadow
- Buttons: warm gradient fills, larger touch targets (48px height), pill shape
- Typography: larger sizes for better readability (title 1.8rem, body 1rem)
- Reduce visual density — more whitespace, fewer elements on screen
- Keep orb canvas animation but adjust colors to warm palette

**Acceptance:**
- Onboarding screens look warm and inviting against glassmorphic blur
- Permission cards are clearly legible with warm tones
- Buttons have obvious affordance with warm gradients
- Body background is transparent (blur shows through)

### Task 5: Implement horizontal slide transitions between screens
**Files:** `Resources/Onboarding/onboarding.html`

Replace the current opacity/translateY transitions with horizontal slides:
- Welcome → Permissions: current screen slides left, new screen slides in from right
- Permissions → Ready: same left-slide pattern
- Add CSS classes: `.slide-enter-right`, `.slide-exit-left` with translateX transforms
- Update `transitionTo()` JS function to apply directional classes
- Animation duration: 400ms with ease-out timing for natural feel
- Dot indicator animates smoothly (not just snap)
- Ensure no layout thrashing during transitions (use transform, not left/right)

**Acceptance:**
- Screens slide left-to-right in sequence
- Transitions are smooth (60fps) with no jank
- Dot indicator position animates in sync
- No visual glitches during transition (no overlap, no flash)

### Task 6: Responsive layout for different screen sizes
**Files:** `Resources/Onboarding/onboarding.html`, `OnboardingWindowController.swift`

Make onboarding adapt gracefully:
- Window min size: 440x560, max size: 600x720
- Allow window resizing within these bounds
- CSS uses relative units (%, vh/vw, clamp()) for spacing and font sizes
- Orb size scales with window (use CSS custom property set from JS on resize)
- Permission cards stack vertically with proper spacing at all sizes
- Test at 1x and 2x Retina

**Acceptance:**
- Window is resizable between min/max bounds
- Content scales proportionally — no text overflow, no cut-off elements
- Orb maintains visual balance at all sizes
- Works on both 1x and 2x displays

### Task 7: Dark/light mode adaptation
**Files:** `Resources/Onboarding/onboarding.html`, `OnboardingWindowController.swift`

Support both system appearances:
- CSS `@media (prefers-color-scheme: dark)` and `light` variants
- Light mode: warm off-white text on translucent white cards, dark text for readability
- Dark mode: keep current aesthetic but with warm undertones instead of cold gray
- NSVisualEffectView automatically adapts material to appearance
- Orb palette adjusts — warmer hues in light mode, deeper in dark
- Remove the forced `.preferredColorScheme(.dark)` from the onboarding path
- Dot indicator, buttons, and status badges adapt colors

**Acceptance:**
- Switching system appearance immediately updates onboarding look
- Both modes are warm and inviting (not clinical)
- Text is highly readable in both modes
- NSVisualEffectView material looks correct in both modes

### Task 8: Animated orb greeting on Welcome screen and polish
**Files:** `Resources/Onboarding/onboarding.html`

Enhance the Welcome screen orb animation:
- Orb starts small (scale 0.5) and grows to full size with a spring-like ease over 1.2s
- During growth, emit a burst of warm-colored rings (pulse canvas)
- After orb settles, the welcome bubble fades in with a gentle bounce
- "Get started" button fades in after bubble (sequential stagger: orb → bubble → button)
- Add a subtle floating animation to the orb (gentle up-down bob, 4s period)
- Add touch/hover effect on the orb — gentle brightness increase
- Ensure `prefers-reduced-motion` disables growth/float animations (just fade in)

**Acceptance:**
- First-time welcome feels warm and alive — orb "arrives" with presence
- Stagger timing feels natural (not too slow, not too fast)
- Reduced motion: orb appears immediately, bubble fades in, no bouncing
- Animation runs smoothly at 60fps
- All existing functionality (screen transitions, permissions, TTS help) still works
