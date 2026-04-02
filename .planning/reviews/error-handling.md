# Error Handling Review — Phase 1.1

## Reviewer: Error Handling Hunter
## Focus: Error paths, nil handling, optional chaining

### Findings

**FINDING 1 — CRITICAL: Streaming path loses metadata**
- File: `ConversationController.swift` lines 206-211
- `finalizeStreaming()` calls `appendMessage(role: .assistant, content: streamingText)` with NO modelID/providerKind
- `cancelStreaming()` (line 214-220) has the same problem
- This means ALL streaming responses from external providers (OpenAI, Anthropic) have nil metadata
- The metadata IS captured in `agentModelID`/`agentProviderKind` variables but never reaches `finalizeStreaming()`
- Vote: MUST FIX

**FINDING 2 — HIGH: Error path drops metadata**
- File: `CoworkWorkspaceController.swift` lines 1541-1545
- When streaming fails with partial content, `cancelStreaming()` is called which calls `appendMessage()` with no metadata
- The partial content is committed as a message with no model attribution
- Vote: SHOULD FIX

**FINDING 3 — LOW: faeLocalhost user message inconsistency**
- Line 1397: `appendMessage(role: .user, content: prompt)` — uses old signature (no explicit nil args)
- Lines 1471, 1587: both use `appendMessage(role: .user, content: prompt, modelID: nil, providerKind: nil)` explicitly
- Functionally identical due to defaults, but inconsistent style in same class
- Vote: MINOR

### Summary
2 MUST/SHOULD FIX findings. The streaming path is the critical gap.
