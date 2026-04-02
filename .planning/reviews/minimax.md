# External Review — MiniMax Perspective
## Phase 1.1: Per-Message Model Metadata

### Grade: B

### Overview
Competent implementation of message metadata infrastructure. Core data model changes are correct 
and backward-compatible. The streaming path gap is the primary deficiency.

### Findings by Category

**Data Model (PASS)**
- `WorkWithFaeConversationMessage` correctly uses auto-synthesized Codable with Optional fields
- `ChatMessage` mirrors the fields with identical semantics
- Hashable/Sendable/Equatable all synthesize correctly with new Optional String fields

**Wiring (PARTIAL)**
Three submission paths:
- faeLocalhost (non-streaming): assistant message correctly tagged ✓
- External non-streaming: assistant message correctly tagged ✓  
- External streaming: finalizeStreaming() called → metadata lost ✗
- Consensus summary: tagged with "consensus-synthesis" ✓

The streaming path handles most real-world OpenAI/Anthropic interactions and is the highest-volume path.

**API Design (GOOD)**
- `appendMessage()` signature extended with nil defaults — clean additive change
- All existing call sites unaffected
- Parameter naming is clear: `modelID`, `providerKind`

**Infrastructure (GOOD)**
- `MessageOverride` is well-structured future infrastructure
- All five fields have appropriate types (Double?, String?, Int?)
- Conformances: Sendable, Codable, Hashable — all correct

**Tests (FAIL)**
- Zero tests added
- Plan specified tests-first TDD approach
- Persistence changes require at minimum backward-compat tests

### Summary of Required Changes
1. CRITICAL: `finalizeStreaming(modelID: String? = nil, providerKind: String? = nil)` 
2. CRITICAL: `cancelStreaming(modelID: String? = nil, providerKind: String? = nil)`
3. HIGH: At least one backward-compat decode test
4. MEDIUM: `// TODO:` on MessageOverride

### Verdict: NEEDS REVISION
