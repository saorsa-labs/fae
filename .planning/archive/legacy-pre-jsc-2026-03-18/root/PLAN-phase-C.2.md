# Phase C.2: System Theme & Tray

## Overview

Add system theme detection and synchronization for the macOS menu bar app. The app will detect the system's light/dark mode preference and automatically apply appropriate CSS variables. Users can override with a manual preference (auto/light/dark).

## Task 1: Add theme configuration types

**Objective:** Define theme-related configuration types in `src/config.rs`

**Files:**
- src/config.rs

**Dependencies:** None

**Tests:** Unit tests for ThemeConfig default values and serialization

**Implementation:**
- Add `ThemeMode` enum: `Auto`, `Light`, `Dark`
- Add `ThemeConfig` struct with `mode: ThemeMode` field
- Add `theme: ThemeConfig` field to `SpeechConfig`
- Implement `Default` for `ThemeConfig` (defaults to `Auto`)
- Implement `Serialize` and `Deserialize` derives

## Task 2: Add macOS system theme detection

**Objective:** Create platform-specific system theme detection using NSAppearance

**Files:**
- src/theme.rs (new)
- src/lib.rs (add module)

**Dependencies:** Task 1

**Tests:**
- Test that `SystemTheme::current()` returns a valid theme on macOS
- Test `SystemTheme::is_dark()` returns bool
- Mock tests for theme change detection

**Implementation:**
- Create `src/theme.rs` module
- Define `SystemTheme` enum: `Light`, `Dark`
- Implement `SystemTheme::current()` using `NSAppearance` (via objc2-app-kit crate if needed, or core-foundation/cocoa)
- Implement `SystemTheme::is_dark()` helper
- Add conditional compilation for macOS vs other platforms
- On non-macOS, default to Dark theme

## Task 3: Add theme CSS variable generation

**Objective:** Generate light/dark CSS variable sets

**Files:**
- src/theme.rs

**Dependencies:** Task 2

**Tests:**
- Test `generate_theme_css(SystemTheme::Light)` returns light variables
- Test `generate_theme_css(SystemTheme::Dark)` returns dark variables
- Test that generated CSS includes all required variables

**Implementation:**
- Add `generate_theme_css(theme: SystemTheme) -> String` function
- Light theme variables: lighter backgrounds, darker text
- Dark theme variables: current GLOBAL_CSS colors (already dark)
- Return CSS string with `:root { ... }` variable definitions
- Cover all variables used in GLOBAL_CSS: bg-primary, bg-secondary, text-primary, etc.

## Task 4: Wire theme config into GUI state

**Objective:** Add theme configuration to GUI state management

**Files:**
- src/bin/gui.rs

**Dependencies:** Tasks 1, 2, 3

**Tests:**
- Integration test that theme state is readable/writable
- Test theme config persists across restarts

**Implementation:**
- Add `use_signal` for current theme mode in `app()` function
- Load theme mode from config on startup
- Add signal for computed effective theme (based on mode + system theme)
- Add helper to resolve effective theme: if Auto, use system; else use explicit mode
- No UI changes yet, just state plumbing

## Task 5: Inject theme CSS dynamically

**Objective:** Replace static GLOBAL_CSS with dynamic theme-aware CSS

**Files:**
- src/bin/gui.rs

**Dependencies:** Task 4

**Tests:**
- Visual regression test (manual) - app renders correctly in light mode
- Visual regression test (manual) - app renders correctly in dark mode
- Test CSS injection updates when theme changes

**Implementation:**
- Remove static GLOBAL_CSS constant
- Create `build_global_css(theme: SystemTheme) -> String` function
- Include structural CSS (layout, sizes, transitions) as static
- Inject theme-specific variables via `generate_theme_css()`
- Update `style { {GLOBAL_CSS} }` to use computed CSS from signal
- Test by manually switching theme in macOS System Settings

## Task 6: Add theme selection to settings UI

**Objective:** Allow user to override theme mode in settings

**Files:**
- src/bin/gui.rs (settings screen)

**Dependencies:** Task 5

**Tests:**
- Test theme radio buttons render correctly
- Test selecting theme updates config and triggers re-render
- Test theme persists after app restart

**Implementation:**
- Add theme selection radio buttons to settings screen: Auto / Light / Dark
- Wire to theme mode signal
- On change, update config and save to disk
- Trigger CSS regeneration when mode changes
- Add visual indicator of current active theme

## Task 7: Implement system theme change listener

**Objective:** Detect macOS system theme changes while app is running

**Files:**
- src/theme.rs
- src/bin/gui.rs

**Dependencies:** Task 6

**Tests:**
- Test that listener detects theme changes
- Test that app re-renders when system theme changes (in Auto mode)
- Test that listener does not trigger updates when mode is Light or Dark

**Implementation:**
- Add `watch_system_theme(tx: Sender<SystemTheme>)` function
- Use `NSDistributedNotificationCenter` to observe `AppleInterfaceThemeChangedNotification`
- Spawn background task in GUI that watches for theme changes
- When change detected (and mode is Auto), update effective theme signal
- Gracefully handle watcher thread lifetime

## Task 8: Validate menu bar persistence and tray behavior

**Objective:** Ensure NSStatusBar menu bar item persists correctly in background

**Files:**
- src/bin/gui.rs (menu bar setup)

**Dependencies:** Task 7

**Tests:**
- Manual test: app minimizes but remains in menu bar
- Manual test: clicking menu bar item restores window
- Manual test: menu bar icon adapts to system theme
- Test that app can be configured to launch at login (if not already implemented)

**Implementation:**
- Review existing NSStatusBar implementation (already present in gui.rs)
- Ensure `with_menu()` is correctly configured in `LaunchBuilder`
- Verify window close behavior (minimize to tray vs quit)
- Add window event handler to hide (not quit) on close if desired
- Document menu bar behavior in code comments
- No changes if already working correctly - validation task only

## Quality Gates (All Tasks)

- Zero `.unwrap()` or `.expect()` in production code (tests OK)
- Zero clippy warnings: `just lint`
- Zero compilation warnings: `just check`
- All tests pass: `just test`
- Code formatted: `just fmt`
- Changes committed with clear message after each task
