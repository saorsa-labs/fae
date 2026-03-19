# Fixes Applied — 2026-02-28

Based on consensus-20260228-000000.md MUST FIX items.

## Build Status
✅ `swift build` — Build complete, zero errors, zero warnings

---

## Fix 1: `.first!` Force Unwrap in FaeCore (DONE by code-fixer agent)
**File**: `FaeCore.swift`
**Status**: ✅ Fixed — `.first!` no longer present; safe `guard let` pattern used

---

## Fix 2: NSScreen.screens[0] Unsafe Array Access (Fixed manually)
**File**: `WindowStateController.swift` — 5 occurrences
**Changed**:
- Line 78: `let screen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]`
  → `guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }`
- Line 142: `let screen = window.screen ?? NSScreen.screens.first ?? NSScreen.screens[0]`
  → `guard let screen = window.screen ?? NSScreen.screens.first else { return }`
- Line 188: same pattern → `guard let screen = ...`
- Line 219: same pattern → `guard let screen = ...`
- Line 281: same pattern → `guard let screen = ...`

---

## Fix 3: NotificationCenter Observer Leak in FaeCore (Fixed manually)
**File**: `FaeCore.swift`
**Changed**:
- Added `private var schedulerObservers: [NSObjectProtocol] = []` property
- Modified `observeSchedulerUpdates()` to capture the tokens returned by `addObserver(forName:...)`
- Added `deinit { schedulerObservers.forEach { NotificationCenter.default.removeObserver($0) } }`

---

## Fix 4: Unsafe Type Cast in SQLiteMemoryStore (Fixed manually)
**File**: `SQLiteMemoryStore.swift:63`
**Changed**:
- `Set(columns.map { $0["name"] as String })`
  → `Set(columns.compactMap { $0["name"] as? String })`

---

## Not Fixed (Re-assessed as Already Safe)

### CoreMLSpeakerEncoder shape[1]/shape[2]
Re-assessed: These accesses at lines 377, 387, 388 are already inside `if shape.count == 2` and `else if shape.count == 3` guards respectively. The reviewers missed the surrounding conditions. No fix needed.

### FaeRelayServer data[0]
Re-assessed: Line 251 is inside `if data.count >= 4` guard at line 250. Already safe. No fix needed.

---

## SHOULD FIX Items (deferred)
- Dead `voiceOptimized` branch in PersonalityManager.assemblePrompt()
- Test coverage gaps in Core/Audio/Pipeline modules
- API tokens in ChannelConfig should use Keychain
- generateWithTools() decomposition (273 LOC, complexity improvement)
