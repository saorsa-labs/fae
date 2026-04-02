# External Review — GLM-4.7 Perspective
## Phase 1.1: Per-Message Model Metadata

### Grade: B+

### Summary
A clean, minimal data infrastructure change. The approach is sound. 
Primary concern is the incomplete streaming path and absent tests.

### Detailed Assessment

**Architecture: GOOD**
- Separating ChatMessage (runtime) from WorkWithFaeConversationMessage (persistence) is correct
- Both updated symmetrically with same fields
- Conversion functions handle both directions

**Backward Compatibility: GOOD**
- Swift Optional auto-synthesis uses decodeIfPresent — confirmed safe
- No custom CodingKeys means no risk of accidentally using decode() vs decodeIfPresent()
- Existing workspace files will load with nil metadata — correct behavior

**Streaming Path: BAD**
- `finalizeStreaming()` is the terminal commit for streamed responses
- It does NOT accept modelID/providerKind
- All streamed responses will have nil metadata
- This is the primary delivery mechanism for OpenAI/Anthropic — most external responses affected

**MessageOverride: NEUTRAL**
- Well-designed struct, appropriate conformances
- Currently dead code — acceptable for infrastructure phase
- Missing `// TODO:` comment explaining when it will be wired

**Tests: MISSING**
- No tests at all
- For a Codable persistence change, at minimum need backward-compat test
- Risk: future CodingKeys addition silently breaks decoding

### Required Changes
1. Fix `finalizeStreaming(modelID:providerKind:)` and `cancelStreaming(modelID:providerKind:)`  
2. Add backward-compat decode test
3. Add `// TODO:` comment on MessageOverride

### Verdict: REQUEST CHANGES
