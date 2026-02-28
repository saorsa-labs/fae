# Code Simplification Review
**Date**: 2026-02-27
**Mode**: Scoped — recently modified Swift files
**Scope**: `native/macos/Fae/Sources/Fae/`

---

## Summary

The codebase is in strong shape overall. The v0.8.0 migration to pure Swift is clean and well-structured. Most files are readable, well-commented, and follow consistent patterns. The findings below are genuine opportunities — none are showstoppers, and several are low priority polish items.

---

## Findings

### [HIGH] PipelineCoordinator.swift — `generateWithTools()` is too long and handles two very different cases in one function

**File**: `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
**Lines**: 467–740 (~273 lines)

`generateWithTools()` does significantly different work on the first call vs. tool follow-up calls, yet both paths live in one function controlled by the `isToolFollowUp` flag. The branching on that flag is spread across the function body, making it harder to follow the control flow.

The function also contains two near-identical blocks for flushing roleplay voice segments (lines 633–658 and earlier in the streaming loop at 569–612). The voice segment routing logic — look up voice for character, strip non-speech chars, emit event, speak — is duplicated verbatim.

Additionally, the `currentSystemPrompt` property is a workaround for the `isToolFollowUp` pattern. This mutable state on the actor leaks across calls and is only valid within a single `generateWithTools` call chain. It exists only because the function was split from a single logical unit. If the function were refactored to pass the prompt explicitly, the property could be eliminated.

**Suggested direction**:
- Extract a `flushVoiceSegments(_ segments: [VoiceSegment], isFinal: Bool)` private helper to eliminate the duplicated roleplay flush logic.
- Consider extracting the "prepare first turn" work (thinking tone, history update, memory recall, prompt building) into a dedicated private function called only on the first turn, passing the prompt and options as explicit parameters into a shared generation loop.

---

### [MEDIUM] FaeConfig.swift — `parse()` function is excessively verbose with per-field repetition

**File**: `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`
**Lines**: 244–492 (~248 lines)

The `parse()` function consists of a large outer `switch section` with inner `switch key` blocks for each config section. Every key follows the same pattern:

```swift
case "someKey":
    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
    config.section.someKey = v
```

This is highly repetitive across 9 sections and ~40 keys. The pattern never varies — only the parse function (`parseInt`, `parseFloat`, `parseBool`, `parseString`) and the target keypath change.

The `serialize()` function at lines 494–578 has the same problem in reverse — every field is spelled out manually as a `lines.append(...)` call.

This is the most significant maintenance burden in the reviewed files. Adding a new config field requires touching both `parse()` and `serialize()` with identical boilerplate on both sides.

**Note**: A full refactor using `KeyPath` assignment helpers would reduce this dramatically, but since TOML parsers aren't part of the Swift package (by design — this is a hand-rolled TOML parser to avoid dependencies), the current approach is defensible. The simplest improvement is grouping the parsing helper calls to make the repetition visually obvious and easy to scan, which the current code already does reasonably well. The main callout is the size.

---

### [MEDIUM] MemoryOrchestrator.swift — Six `extract*` functions share identical structural pattern

**File**: `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift`
**Lines**: 392–533

The six private extraction functions (`extractName`, `extractPreference`, `extractInterest`, `extractCommitment`, `extractEvent`, `extractPerson`) all follow the exact same structure:

```swift
private func extractX(from lower: String, fullText: String) -> String? {
    let patterns = [...]
    for pattern in patterns {
        if lower.contains(pattern),
           let range = lower.range(of: pattern)
        {
            let after = fullText[range.lowerBound...]  // or range.upperBound...
            let result = String(after.prefix(N))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty [, result.count > 2] {
                return "Prefix: \(result)"
            }
        }
    }
    return nil
}
```

The only differences are: the pattern list, whether to use `lowerBound` or `upperBound` of the range, the prefix length (200 or 300), the minimum length check (some have `count > 2`), and the return string prefix ("User says:", "User is interested in:", etc.).

These six functions could be unified into a single helper:

```swift
private func extractFirstMatch(
    from lower: String,
    fullText: String,
    patterns: [String],
    anchorAtUpperBound: Bool = true,
    maxLength: Int = 200,
    minLength: Int = 1,
    prefix: String
) -> String?
```

This would reduce six ~15-line functions to six ~5-line call sites and one ~20-line function, making it easier to add new extraction patterns in the future.

---

### [MEDIUM] PipelineCoordinator.swift — `handleSpeechSegment()` has deep nesting in the speaker ID block

**File**: `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
**Lines**: 310–362

The speaker identification block nests four levels deep: `if config.speaker.enabled`, `if let encoder`, `do`, `let hasOwner`, `if !hasOwner`, `else if let match`. The logic is correct but the indentation depth makes it harder to follow than necessary.

The `if !hasOwner && !config.onboarded` branch (first-launch enrollment) is a special case that could be handled with an early-exit guard, flattening the nesting by one level:

```swift
// Current: if !hasOwner && !config.onboarded { ... } else if let match = ... { ... }
// Simplified: guard hasOwner || config.onboarded else {
//     await store.enroll(label: "owner", embedding: embedding)
//     ...
//     return (label, isOwner)
// }
// let match = await store.match(...)
```

---

### [MEDIUM] PersonalityManager.swift — `assemblePrompt()` has a dead branch and a misleading comment

**File**: `native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift`
**Lines**: 241–251

The `voiceOptimized` parameter branch is dead code — both `true` and `false` paths append `voiceCorePrompt`:

```swift
if voiceOptimized {
    parts.append(voiceCorePrompt)
} else {
    // Full prompt would be loaded from Prompts/system_prompt.md bundle resource.
    // For now, use the voice prompt as fallback.
    parts.append(voiceCorePrompt)
}
```

This is identical behavior for both branches. The `else` branch has a comment saying "for now" but this has clearly been the state for some time. Either implement the intended behavior (load from bundle resource) or simplify to `parts.append(voiceCorePrompt)` and remove the dead branch.

Also, the comment on step 5 says `// 5. Memory context` and the next comment says `// 5b. Current date/time` — the numbering should be `6`, `7`, etc., or the numbering convention should be clarified (the subsequent steps in comments 6-9 are off by one).

---

### [LOW] MemoryOrchestrator.swift — `supersedeContradiction()` duplicates embedding load guard from `rerankHitsIfPossible()`

**File**: `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift`
**Lines**: 247–248 and 313–314

Both `rerankHitsIfPossible()` and `supersedeContradiction()` contain the same guard for loading the embedding engine:

```swift
if !(await embeddingEngine.isLoaded) {
    try await embeddingEngine.load(modelID: "foundation-hash-384")
}
```

This is a lazy-load pattern that is duplicated rather than centralized. A private helper `ensureEmbeddingEngineLoaded()` would remove the duplication.

---

### [LOW] FaeCore.swift — `createMemoryStore()` and `createSchedulerPersistenceStore()` duplicate the fae directory URL lookup

**File**: `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
**Lines**: 404–421

Both static factory methods repeat the same three-line pattern:

```swift
let appSupport = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
).first!
let faeDir = appSupport.appendingPathComponent("fae")
let dbPath = faeDir.appendingPathComponent("X.db").path
```

The `init()` method at line 32 already contains the same lookup. A static computed property `faeDirectoryURL` would centralize this and also eliminate the `!` force-unwrap (which is safe here, but still breaks the project's spirit of avoiding forced unwraps in production code).

```swift
private static var faeDirectoryURL: URL {
    get throws {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let first = urls.first else { throw ... }
        return first.appendingPathComponent("fae")
    }
}
```

---

### [LOW] SpeakerProfileStore.swift — `enroll()` and `enrollIfBelowMax()` share a large block of duplicated mutation logic

**File**: `native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift`
**Lines**: 79–117

`enroll()` and `enrollIfBelowMax()` both contain the same five-line mutation block:

```swift
profiles[idx].embeddings.append(embedding)
var dates = profiles[idx].embeddingDates ?? []
dates.append(now)
profiles[idx].embeddingDates = dates
profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)
profiles[idx].lastSeen = now
```

This block could be extracted into a private helper `appendEmbedding(at index: Int, embedding: [Float], date: Date)` that both functions call. This is a small but meaningful reduction since this mutation logic is the core of both functions.

---

### [LOW] WebSearchTool.swift — `domainCategory(for:)` uses a deeply nested series of `Set` lookups that could be a single lookup with a map

**File**: `native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift`
**Lines**: 245–301

The `domainCategory(for:)` function defines six separate `Set<String>` constants, checks them sequentially with early returns. A dictionary mapping domain to category would be more concise:

```swift
private static let domainCategories: [String: String] = {
    var map: [String: String] = [:]
    let news = ["reuters.com", ...]
    news.forEach { map[$0] = "[News]" }
    // etc.
    return map
}()
```

However, the current approach is very readable — each category is clearly labeled and the sets are easy to extend. This is a genuine tradeoff. The lazy-static dict version would be marginally faster (O(1) vs O(n) sequential checks) but the n is tiny (6 checks) and both are negligible. This is LOW priority and more preference than improvement.

---

### [LOW] MLProtocols.swift — `MLEngineLoadState.isLoaded` and `isFailed` could use `if case` more idiomatically

**File**: `native/macos/Fae/Sources/Fae/Core/MLProtocols.swift`
**Lines**: 13–21

```swift
var isLoaded: Bool {
    if case .loaded = self { return true }
    return false
}
```

This is functionally correct but could use the more idiomatic Swift pattern:

```swift
var isLoaded: Bool { self == .loaded }
```

However, `MLEngineLoadState` is not `Equatable` and `failed(String)` has an associated value, so `Equatable` conformance would require a custom implementation or pattern matching. The current approach is fine — this is purely a style note.

Alternatively, the computed properties could use `guard case`:

```swift
var isLoaded: Bool {
    guard case .loaded = self else { return false }
    return true
}
```

Neither is clearly better. No change recommended.

---

### [LOW] PersonalityManager.swift — `nextApproval*` functions all share the same rotation pattern

**File**: `native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift`
**Lines**: 159–187

Five functions (`nextThinkingAcknowledgment`, `nextApprovalGranted`, `nextApprovalDenied`, `nextApprovalTimeout`, `nextApprovalAmbiguous`) all share an identical two-line body:

```swift
let phrase = someArray[ackCounter % someArray.count]
ackCounter += 1
return phrase
```

A single private helper:

```swift
private static func nextPhrase(from array: [String]) -> String {
    let phrase = array[ackCounter % array.count]
    ackCounter += 1
    return phrase
}
```

...would reduce the five functions to one-liner call sites. This is clean and eliminates the copy-paste risk if the rotation logic ever needs to change (e.g., switching to random selection).

---

### [LOW] FaeConfig.swift — Boolean serialization is verbose

**File**: `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`
**Lines**: 499, 527, 544–546, etc.

Boolean fields are serialized as:
```swift
lines.append("onboarded = \(onboarded ? "true" : "false")")
```

This appears ~10 times. A helper `encodeBool(_ value: Bool) -> String` returning `"true"` or `"false"` would be consistent with the existing `encodeString`, `encodeStringOrNil`, `encodeStringArray` helpers already in the file.

---

## Simplification Opportunities Summary

| Priority | File | Opportunity |
|----------|------|-------------|
| HIGH | PipelineCoordinator.swift | Extract `flushVoiceSegments()` helper; consider splitting first-turn setup from the generation loop |
| MEDIUM | FaeConfig.swift | The 248-line `parse()` function is unavoidably verbose for a hand-rolled TOML parser; consider adding a comment calling out this intentional verbosity |
| MEDIUM | MemoryOrchestrator.swift | Unify six structurally identical `extract*()` functions into one parameterized helper |
| MEDIUM | PipelineCoordinator.swift | Flatten speaker ID nesting in `handleSpeechSegment()` using early-exit guard |
| MEDIUM | PersonalityManager.swift | Remove dead `voiceOptimized` branch; fix step numbering comments |
| LOW | MemoryOrchestrator.swift | Extract `ensureEmbeddingEngineLoaded()` to remove duplicated lazy-load guard |
| LOW | FaeCore.swift | Extract `faeDirectoryURL` computed property; eliminate repeated appSupport lookup |
| LOW | SpeakerProfileStore.swift | Extract `appendEmbedding(at:embedding:date:)` helper from `enroll()` and `enrollIfBelowMax()` |
| LOW | PersonalityManager.swift | Extract `nextPhrase(from:)` helper for the five rotation functions |
| LOW | FaeConfig.swift | Add `encodeBool()` helper for consistency with other encode helpers |

---

## Strengths Worth Preserving

- **Actor isolation is used correctly throughout** — `PipelineCoordinator`, `MemoryOrchestrator`, `SpeakerProfileStore`, `RoleplaySessionStore`, and `SQLiteMemoryStore` all use `actor` correctly with no unnecessary nonisolated escapes.
- **Error handling is clean** — tools return `ToolResult.error(...)` rather than throwing, which is the right pattern for LLM tool results. Throwing is reserved for infrastructure-level failures.
- **`generateWithTools()` recursion is bounded** — the `maxToolTurns = 5` cap is explicit and well-placed.
- **Protocol + extension design in `MLProtocols.swift`** — default implementations on `TTSEngine` for `loadVoice` and `synthesize(text:voiceInstruct:)` are a clean way to make the protocol backward-compatible.
- **`ToolRegistry` is simple and clear** — the dictionary lookup, schema generation, and tool listing are all minimal and obvious.
- **Memory extraction patterns are explicit** — while the six `extract*()` functions are repetitive, having named functions for each memory kind is easier to audit and extend than a table-driven approach.

---

## Grade: B+

The codebase is well-structured and clearly written. The MEDIUM findings represent real refactoring opportunities that would improve maintainability — particularly the six `extract*()` functions in `MemoryOrchestrator` and the dead branch in `PersonalityManager.assemblePrompt()`. The HIGH finding in `generateWithTools()` is the most impactful: the duplicated roleplay flush logic and the `isToolFollowUp` control flag add cognitive load to an already complex function. None of the issues are bugs or safety concerns — they are all clarity and maintainability improvements.
