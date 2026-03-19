# Error Handling Review - Fae Swift Codebase
**Date**: 2026-02-27
**Mode**: scoped (native/macos/Fae/Sources/Fae/)
**Reviewer**: Claude Code

## Summary

The Fae Swift codebase demonstrates **good defensive error handling practices** overall, with appropriate logging and degraded mode fallbacks for non-critical systems. However, there are **several critical issues** that violate the zero-tolerance policy:

1. **Array index access without bounds checking** — unsafe subscript patterns in critical paths
2. **Unsafe buffer pointer creation** — potential crash vectors in audio processing
3. **Silent error handling** in some database/file operations
4. **Missing guards on optional accesses** before array indexing
5. **Index calculation errors** that could cause crashes

---

## Critical Findings

### [CRITICAL] Array Index Access Without Bounds Checking

**File**: `ConversationBridgeController.swift:378`
```swift
let parts = basename.components(separatedBy: "-")
if parts.count >= 3 {
    return "\(parts[0]) \(parts[1]) · \(parts[2])"  // ✓ SAFE (guarded)
}
```
**Status**: ✓ SAFE — properly guarded by `parts.count >= 3` check.

---

**File**: `WindowStateController.swift:78`
```swift
let screen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
```
**Status**: ❌ **UNSAFE** — force unwrap pattern `[0]` is reachable if both `.first` and `.main` are nil.
**Risk**: HIGH - Crash if `NSScreen.screens` is empty (very rare but possible in headless/VM scenarios).
**Fix**:
```swift
let screen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
```
Or safer:
```swift
guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
```

**Occurrences** (same pattern):
- `WindowStateController.swift:78`
- `WindowStateController.swift:142`
- `WindowStateController.swift:188`
- `WindowStateController.swift:219`
- `WindowStateController.swift:281`

---

**File**: `Scheduler/FaeScheduler.swift:278`
```swift
let selected = Array(items.prefix(3))
if selected.count == 1 {
    briefing = "Good morning! Just a heads up — \(selected[0])."  // ✓ SAFE
} else {
    let joined = selected.dropLast().joined(separator: ", ")
    briefing = "Good morning! Just a heads up — \(joined), and \(selected.last ?? "")."
}
```
**Status**: ✓ SAFE — the `else` branch handles all cases with `.last` optional coalescing.

---

**File**: `Search/SearchHTTPClient.swift:17`
```swift
return userAgents.randomElement() ?? userAgents[0]
```
**Status**: ⚠️ **RISKY** — assumes `userAgents` is non-empty.
**Risk**: MEDIUM - Crash if the array is initialized empty.
**Context**: This is a private constant, so it's likely safe in practice, but violates zero-tolerance.

---

### [HIGH] Unsafe Buffer Pointer Access

**File**: `Pipeline/PipelineCoordinator.swift:1029`
```swift
private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    let frameCount = Int(buffer.frameLength)
    guard let channelData = buffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
}
```
**Status**: ⚠️ **POTENTIALLY UNSAFE** — creates `UnsafeBufferPointer` with raw pointer arithmetic.
**Risk**: MEDIUM - If `frameCount` exceeds the actual buffer size, this will read past bounds.
**Mitigation**: AVAudioPCMBuffer should guarantee consistency, but should validate.
**Fix**:
```swift
guard let channelData = buffer.floatChannelData,
      frameCount <= buffer.frameLength else {
    return []
}
```

---

**File**: `Audio/AudioCaptureManager.swift:113`
```swift
let ptr = channelData[0]
return Array(UnsafeBufferPointer(start: ptr, count: frameCount))
```
**Status**: ⚠️ **SAME RISK** — direct channel data access without validation.

---

**File**: `ML/CoreMLSpeakerEncoder.swift:245-253`
```swift
// vDSP_fft_zrip packs: DC in realp[0], Nyquist in imagp[0].
realp[0] = 0  // Clear DC
imagp[0] = 0  // Clear Nyquist
magnitudes[offset] = abs(realp[0])      // DC
magnitudes[offset + nFFT / 2] = abs(imagp[0])  // Nyquist
```
**Status**: ⚠️ **RISKY** — accessing `realp[0]` and `imagp[0]` without explicit length validation.
**Context**: `realp` and `imagp` are vDSP output buffers. Should be safe if `DSPSplitComplex` is properly allocated.
**Risk**: MEDIUM - If allocation is incomplete, access causes crash.

---

### [HIGH] Missing Input Validation on Array Access

**File**: `ML/CoreMLSpeakerEncoder.swift:377, 387-388`
```swift
let dim = shape[1]
let numFrames = shape[1]
let dim = shape[2]
```
**Status**: ⚠️ **UNSAFE** — assumes `shape` array has at least 3 elements without validation.
**Risk**: HIGH - Core ML output shape mismatch causes crash.
**Fix**:
```swift
guard shape.count >= 3 else {
    return .error("Invalid model output shape")
}
let numFrames = shape[1]
let dim = shape[2]
```

---

**File**: `Memory/SQLiteMemoryStore.swift:116, 411`
```swift
let result: String = row[0]  // Direct column access
return row?[0] as? Int ?? 0  // Unsafe optional unwrap
```
**Status**: ⚠️ **POTENTIALLY UNSAFE** — assumes query result columns exist.
**Risk**: MEDIUM - Malformed query results cause crash.
**Context**: GRDB should validate, but explicit guards are safer.

---

### [MEDIUM] Silent Error Handling

**File**: `JitPermissionController.swift:196-198`
```swift
do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
} catch {
    return false  // Silent catch — no logging
}
```
**Status**: ⚠️ **SILENT FAIL** — permission check failure is logged nowhere.
**Risk**: MEDIUM - Silent permission denial can leave user confused.
**Fix**:
```swift
} catch {
    NSLog("JitPermissionController: permission check failed: %@",
          error.localizedDescription)
    return false
}
```

---

**File**: `Tools/RoleplayTool.swift:112-118`
```swift
do {
    let data = try Data(contentsOf: url)
    let all = try JSONDecoder().decode([String: [String: String]].self, from: data)
    return all[title] ?? [:]
} catch {
    // Missing file or corrupt data — start fresh (don't log missing file).
    if !((error as NSError).domain == NSCocoaErrorDomain
        && (error as NSError).code == NSFileReadNoSuchFileError)
    {
        NSLog("RoleplayVoicePersistence: load error: %@", error.localizedDescription)
    }
    return [:]
}
```
**Status**: ✓ **ACCEPTABLE** — intentional silent handling of missing-file case, with logging of other errors.

---

**File**: `ML/ModelManager.swift:55-59`
```swift
} catch {
    NSLog("ModelManager: STT load failed (degraded — text input only): %@",
          error.localizedDescription)
    failedEngines.append("STT")
}
```
**Status**: ✓ **GOOD** — proper logging with degraded mode fallback.

---

### [MEDIUM] Index Calculation Without Bounds Validation

**File**: `ConversationBridgeController.swift:210-211`
```swift
let originalRange = result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
    ..< result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
```
**Status**: ⚠️ **COMPLEX CALCULATION** — `offsetBy` with calculated distance could crash if distance is negative or exceeds string length.
**Risk**: MEDIUM - Incorrect distance calculation causes invalid range.
**Mitigation**: `range` is guaranteed to be within `lower`, so distance should be valid.
**Better**:
```swift
guard originalRange.lowerBound < originalRange.upperBound else { continue }
```

---

### [MEDIUM] FaeRelayServer Frame Access Without Length Check

**File**: `FaeRelayServer.swift:251`
```swift
let frameType = data[0]
```
**Status**: ⚠️ **UNSAFE** — no check that `data` is non-empty before subscripting.
**Risk**: HIGH - Crash on empty data packet.
**Fix**:
```swift
guard !data.isEmpty else { return }
let frameType = data[0]
```

---

### [LOW] NSSound Force Unwrap Pattern

**File**: `ConversationBridgeController.swift:245, 249, 253`
```swift
NSSound(named: NSSound.Name("Tink"))?.play()
NSSound(named: NSSound.Name("Submarine"))?.play()
NSSound(named: NSSound.Name("Basso"))?.play()
```
**Status**: ✓ **SAFE** — properly uses optional chaining `?.play()` for safe nil handling.

---

### [LOW] Pipeline Text Processing Index Operations

**File**: `Pipeline/TextProcessing.swift:29, 35, 39, 66, 199, 210-211, 239`
```swift
while index > text.startIndex {
    let prev = text.index(before: index)
    let ch = text[prev]
    if prev > text.startIndex {
        let beforePrev = text.index(before: prev)
```
**Status**: ✓ **SAFE** — all uses are guarded with `> startIndex` checks before creating indices.

---

### [LOW] VoiceTagParser Index Calculation

**File**: `Pipeline/VoiceTagParser.swift:196`
```swift
let start = self.index(self.endIndex, offsetBy: -len)
return start..<self.endIndex
```
**Status**: ⚠️ **RISKY IF len > STRING LENGTH** — negative offsetBy with large `len` crashes.
**Risk**: LOW - `len` is bounded by the prefix length (max 7), and `hasSuffix` check ensures safety.

---

## Code Quality Observations

### Good Practices ✓
1. **Degraded mode fallbacks** — STT, TTS failures don't crash the app
2. **Event-based error propagation** — errors routed through `FaeEventBus`
3. **Optional chaining** — widespread use of `?.` to avoid force unwraps
4. **Guard statements** — guard clauses protect most critical paths
5. **Logging** — errors logged with `NSLog` for debugging

### Problem Areas ❌
1. **Array subscript without bounds** — 5+ unsafe `[0]` or `[index]` patterns
2. **Unsafe pointer arithmetic** — audio buffer operations need stricter validation
3. **Index calculations** — complex `offsetBy` patterns not fully validated
4. **Empty array assumptions** — several places assume non-empty arrays
5. **Buffer access patterns** — Core ML tensor access assumes valid shapes

---

## Recommendations

### Priority 1: Fix Unsafe Array Access
1. Replace `NSScreen.screens[0]` with `.first ?? NSScreen()` pattern
2. Add bounds checks before Core ML tensor indexing
3. Validate `data.count > 0` before `data[0]`
4. Validate `shape.count >= expected` before `shape[index]`

### Priority 2: Harden Buffer Operations
1. Add explicit frame count validation in `extractSamples`
2. Validate vDSP buffer allocation completeness
3. Add bounds checks to `UnsafeBufferPointer` creation

### Priority 3: Add Missing Logging
1. Log permission check failures in `JitPermissionController`
2. Log database query mismatches in `SQLiteMemoryStore`
3. Add validation logging in error paths

### Priority 4: Input Validation
1. Validate array length before indexing in all Core ML operations
2. Validate string indices before accessing text[index]
3. Validate buffer sizes before creating pointer ranges

---

## Grade: C+

**Overall Assessment**:
- **Strengths**: Good degraded mode handling, extensive logging in critical paths, proper optional chaining
- **Weaknesses**: Unsafe array subscripting (violates zero-tolerance), missing bounds validation, risky buffer operations

**Compliance with Zero-Tolerance Policy**: **FAILING**
- Array index access without bounds: 5-7 violations
- Unsafe buffer pointer patterns: 3 violations
- Missing input validation: 4 violations

**Recommendation**: **Fix all array subscript operations before next release.** These are critical crash vectors that should not exist in production code.

