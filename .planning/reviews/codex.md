# External Review — Codex Perspective
## Phase 1.1: Per-Message Model Metadata

### Grade: B-

### Strengths
1. Clean additive API — nil defaults preserve all call site compatibility
2. Bidirectional conversion functions correctly map all fields (no round-trip loss)
3. MessageOverride struct is well-designed infrastructure
4. Backward compatibility via Swift auto-synthesized Codable is sound

### Critical Issues

**[CRITICAL] Streaming path metadata is lost**
The most common path for external providers (OpenAI/Anthropic streaming) will produce messages 
with nil modelID and nil providerKind because `finalizeStreaming()` → `appendMessage()` doesn't 
receive the metadata from the outer scope. This defeats the primary purpose of Phase 1.1.

The fix is straightforward:
```swift
// ConversationController.swift
func finalizeStreaming(modelID: String? = nil, providerKind: String? = nil) {
    if !streamingText.isEmpty {
        appendMessage(role: .assistant, content: streamingText, modelID: modelID, providerKind: providerKind)
    }
    streamingText = ""
    isStreaming = false
}

// CoworkWorkspaceController.swift line 1516:
self.conversation.finalizeStreaming(modelID: agentModelID, providerKind: agentProviderKind)
```

**[HIGH] No tests**
Phase plan specified TDD with tests first. Zero tests were added. At minimum, a test proving 
backward-compatible JSON decode is essential for a persistent data type change.

### Recommendations
1. Fix streaming path — 8 lines of code
2. Add 3 tests minimum: backward compat decode, forward encode/decode, streaming metadata
3. Define `consensusSynthesisKind` constant

### Verdict: NEEDS FIXES before merge
