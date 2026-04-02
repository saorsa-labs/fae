# Phase 1.2: Context Compression Engine

## Overview

Implement a `ConversationCompressor` actor that intelligently summarizes old conversation messages using the local LLM when conversation history exceeds a threshold. This replaces the hard 120-message truncation with progressive, lossy compression that retains semantic context.

**Status:** Planning  
**Priority:** Phase 1.2 Core Feature  
**Estimated Tasks:** 5

---

## Key Design Constraints

### Integration Points
- **WorkWithFaeWorkspace.swift**: Contains `maxConversationMessages = 120` (line 451) and `sanitizedConversationState()` (line 912)
- **CoworkLLMProvider.swift**: `FaeLocalhostCoworkProvider` (line 440) is the interface to invoke local LLM
- **CoworkModelRegistry.swift**: `CoworkKnownModelRegistry.metadata(for:)` provides context window sizes (e.g., Claude models: 200K)
- **CoworkWorkspaceController.swift**: `runtimeDescriptor: FaeLocalRuntimeDescriptor` (line 41) needed to instantiate FaeLocalhostCoworkProvider

### Message Structure
```swift
struct WorkWithFaeConversationMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: String           // "user", "assistant", "summary"
    let content: String
    let timestamp: Date
    let modelID: String?       // e.g., "fae-agent-local"
    let providerKind: String?  // "fae-localhost"
}
```

### Compression Parameters
- **Trigger ratio:** 0.75 (compress when 75% of context window is used)
- **Recent messages ratio:** 0.20 (keep 20% of oldest messages as recent context)
- **Token estimation:** ~4 characters per token (simple heuristic)
- **Summary role:** `"summary"` (new role to mark compressed message)

---

## Task Breakdown

## Task 1: Create ConversationCompressor Actor

**Files:** 
- `native/macos/Fae/Sources/Fae/Cowork/ConversationCompressor.swift` (new)

**Description:**

Create a new actor that encapsulates compression logic. The actor must:

1. Define compression configuration struct:
   - `compressionTriggerRatio: Double = 0.75`
   - `recentMessagesRatio: Double = 0.20`
   - `tokensPerChar: Double = 0.25` (inverse of 4 chars/token)

2. Implement token estimation function:
   ```swift
   func estimateTokens(_ text: String) -> Int
   ```
   Use the heuristic: `Int(Double(text.count) * tokensPerChar)`

3. Implement compression method:
   ```swift
   func compressIfNeeded(
       messages: [WorkWithFaeConversationMessage],
       contextWindowTokens: Int,
       modelID: String
   ) -> [WorkWithFaeConversationMessage]
   ```
   
4. Logic:
   - Calculate total tokens in messages
   - If under 75% of context window, return messages unchanged
   - If over threshold:
     - Keep last 20% of messages as "recent context"
     - Extract remaining older messages for compression
     - Call `generateSummary()` to compress them
     - Return: recent messages + summary message + kept recent context

5. Mark the actor as `Sendable` with all properties isolated.

**Acceptance:**
- Actor compiles and type-checks
- Token estimation produces reasonable numbers (e.g., 100-char message ≈ 25 tokens)
- Compression methods have correct signatures matching CoworkProviderRequest flow
- Unit test: verify 90-message conversation triggers compression at 200K context window

---

## Task 2: Implement Summary Generation

**Files:**
- `native/macos/Fae/Sources/Fae/Cowork/ConversationCompressor.swift` (extend)

**Description:**

Implement the `generateSummary()` method that invokes the local LLM to compress messages.

1. Define summary prompt template:
   ```
   You are a conversation summarizer. Compress the following messages into a brief summary that preserves key decisions, context, and action items.
   
   [Previous summary, if exists]
   
   Messages to compress:
   [older messages joined with newlines]
   
   Provide a concise summary (max 500 tokens).
   ```

2. Implement private method:
   ```swift
   private func generateSummary(
       messages: [WorkWithFaeConversationMessage],
       previousSummary: WorkWithFaeConversationMessage?,
       modelID: String,
       provider: FaeLocalhostCoworkProvider
   ) async throws -> WorkWithFaeConversationMessage
   ```

3. Logic:
   - Build prompt including previous summary if exists (progressive compression)
   - Create `WorkWithFaePreparedPrompt` with summary prompt
   - Create `CoworkProviderRequest` with prepared prompt
   - Call `provider.submit(request:)` to get LLM response
   - Wrap response in new `WorkWithFaeConversationMessage` with:
     - `role: "summary"`
     - `content: <LLM response>`
     - `modelID: modelID`
     - `providerKind: "fae-localhost"`
   - Return the summary message

4. Error handling:
   - If LLM call fails, log error and return original messages unchanged
   - Propagate timeout errors (180s limit from FaeLocalhostCoworkProvider)

**Acceptance:**
- Summary message has correct role and metadata
- Progressive compression: next compression includes previous summary in prompt
- Test: verify LLM is invoked with correct prepared prompt format
- Test: verify timeouts are handled gracefully

---

## Task 3: Add Compression Trigger to Workspace Save

**Files:**
- `native/macos/Fae/Sources/Fae/Cowork/WorkWithFaeWorkspace.swift` (modify)
- `native/macos/Fae/Sources/Fae/Cowork/ConversationCompressor.swift` (integrate)

**Description:**

Replace the hard message truncation with compression logic in `sanitizedConversationState()`.

1. Modify `WorkWithFaeWorkspaceStore.sanitizedConversationState()`:
   ```swift
   private static func sanitizedConversationState(
       _ state: WorkWithFaeWorkspaceState,
       compressor: ConversationCompressor?,
       runtimeDescriptor: FaeLocalRuntimeDescriptor?,
       modelID: String?
   ) async -> WorkWithFaeWorkspaceState
   ```

2. Logic:
   - If no compressor or no runtime descriptor, fall back to hard truncation (`.suffix(120)`)
   - Get context window from `CoworkKnownModelRegistry.metadata(for: modelID)`
   - Default to 200K tokens if model not found
   - Call `compressor.compressIfNeeded(messages:contextWindowTokens:modelID:)`
   - Return sanitized state with compressed messages

3. Update call sites:
   - `WorkWithFaeWorkspaceStore.save()` (line 507): pass compressor and runtime descriptor
   - Ensure async/await compatibility (may need to refactor to async variant)

4. Hard limits:
   - Always keep last message (user input) even if it exceeds context window
   - Never exceed hard cap of 500 messages (safety valve)

**Acceptance:**
- Compression is called when message count triggers threshold
- Hard truncation fallback works if compression unavailable
- No messages lost except during summarization (which preserves content)
- Test: 200-message conversation compresses to ~100 messages with summary

---

## Task 4: Update CoworkWorkspaceController to Pass Runtime

**Files:**
- `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift` (modify)

**Description:**

Enable the workspace to access `runtimeDescriptor` so compression can invoke the local LLM.

1. Store compressor instance:
   - Add property: `private let compressor: ConversationCompressor?`
   - Initialize in `init()` alongside `chatProvider`

2. Pass descriptor through save flow:
   - In `save()` method, pass `runtimeDescriptor` to `sanitizedConversationState()`
   - Ensure descriptor is available before `WorkWithFaeWorkspaceStore.save()` is called

3. When submitting conversation:
   - Before sending request to provider, call `sanitizedConversationState()` with compression enabled
   - This ensures old context is compressed before submission

4. Handle missing local runtime:
   - If `runtimeDescriptor` is nil, use hard truncation only
   - Log debug message when compression is skipped

**Acceptance:**
- Compressor is initialized when workspace controller is created
- Runtime descriptor is passed through save flow correctly
- Workspace can be saved and reopened with compressed history preserved
- No crashes if local LLM is unavailable

---

## Task 5: Add Compression Tests and Validation

**Files:**
- `native/macos/Fae/Tests/FaeTests/Cowork/ConversationCompressionTests.swift` (new)

**Description:**

Write comprehensive tests to validate compression behavior.

1. Token estimation tests:
   - Empty string: 0 tokens
   - 1000-char message: ~250 tokens
   - Mixed ASCII/Unicode: correct length-based calculation

2. Trigger threshold tests:
   - Messages under 75% capacity: no compression
   - Messages at 75% capacity: triggers compression
   - Messages over 100% capacity: compression + safety truncation

3. Progressive compression tests:
   - First compression: generates summary from messages
   - Second compression: includes previous summary in prompt
   - Verify summary chain accumulates context

4. Preservation tests:
   - Recent messages are never compressed
   - Last user message is always kept
   - Summary message has correct role and metadata

5. Edge case tests:
   - Empty conversation: no compression
   - Single message: no compression
   - Only summary messages: no infinite recursion
   - LLM timeout: falls back to hard truncation

6. Integration test:
   - Create 200-message conversation
   - Trigger compression with real FaeLocalhostCoworkProvider mock
   - Verify final message count is reasonable (~100-150)
   - Verify summary message is included

**Acceptance:**
- All tests pass
- Code coverage >80% for ConversationCompressor
- Performance: compression completes in <30s for 500-message conversation
- No memory leaks in actor lifecycle

---

## Implementation Order

1. **Task 1** → Create ConversationCompressor actor (enables all others)
2. **Task 2** → Implement summary generation (defines compression behavior)
3. **Task 5** → Write tests (validates Tasks 1-2 before integration)
4. **Task 3** → Integrate into workspace save (applies compression in production)
5. **Task 4** → Update workspace controller (completes end-to-end flow)

---

## Success Criteria

- Conversations no longer hard-truncate at 120 messages
- Old messages are intelligently summarized instead of dropped
- Compression preserves semantic context and action items
- Local LLM is invoked for summarization (stays private)
- Branch-aware: forked workspaces inherit compressed history
- Graceful fallback if local LLM is unavailable
- All tests pass with >80% coverage
- No performance regression in workspace save time (<500ms)

---

## Notes

- **Actor model**: Use actor isolation to prevent race conditions during compression
- **Async integration**: Compression is async; update call sites to be async-aware
- **Token estimation**: 4 chars/token is approximate; refine if actual tokenization data becomes available
- **LLM selection**: Default to workspace's selected model; allow override in config
- **Progressive context**: Previous summaries are included in next compression prompt to maintain semantic continuity
