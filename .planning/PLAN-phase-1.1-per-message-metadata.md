# Phase 1.1: Per-Message Model Metadata

## Context
Currently, conversation messages (WorkWithFaeConversationMessage) contain only: id, role, content, timestamp. To support model selection replay, adaptive sampling, and future A/B testing, each message needs to track which model/provider generated it.

**Scope:**
- Add `modelID: String?` and `providerKind: String?` fields to WorkWithFaeConversationMessage struct
- Add optional MessageOverride struct for ephemeral per-request settings (temperature, model override)
- Populate metadata on every submission path: runSingleAgentSubmission, runConsensus, synthesis
- Ensure backward compatibility: existing JSON loads with nil for new fields
- No UI changes; this is data infrastructure

**Key Files:**
1. `WorkWithFaeWorkspace.swift` — WorkWithFaeConversationMessage struct
2. `CoworkWorkspaceController.swift` — all submission paths + conversion functions
3. `CoworkWorkspaceModels.swift` — related types and enums
4. `ConversationController.swift` — ChatMessage struct (mirror changes there too)

---

## Task 1: Add unit tests for backward-compatible JSON decoding
**Files:** `native/macos/Fae/Tests/CoworkTests/MessageMetadataDecodingTests.swift` (new)

**Description:** Create a unit test file that verifies WorkWithFaeConversationMessage can be decoded from JSON both with and without the new fields. This establishes the acceptance criteria before implementation.

Test cases:
1. Decode message JSON from old format (no modelID, no providerKind) → both fields are nil
2. Decode message JSON with modelID and providerKind populated → fields are present
3. Decode message JSON with only modelID → providerKind is nil
4. Decode message JSON with only providerKind → modelID is nil
5. Encode message with both fields → JSON round-trip preserves values
6. Encode message with nil fields → JSON contains null or omits keys

Use Codable's decodeIfPresent pattern to test graceful nil defaults.

**Acceptance:** All 6 test cases pass without implementation changes (tests should fail until Task 2 completes)

---

## Task 2: Add modelID and providerKind fields to WorkWithFaeConversationMessage
**Files:** `native/macos/Fae/Sources/Fae/Cowork/WorkWithFaeWorkspace.swift`

**Description:** Update the WorkWithFaeConversationMessage struct to include the new metadata fields with proper Codable support.

Changes (~50 lines):
1. Add properties: `let modelID: String?` and `let providerKind: String?`
2. Update init signature to accept these as parameters with nil defaults
3. Update CodingKeys enum (if needed) to include new keys
4. If using Codable derive, verify it auto-includes new fields
5. If manual Codable implementation, add encode/decode logic using decodeIfPresent

Maintain hashability and sendability. Keep backward compat by making fields optional and using decodeIfPresent.

**Acceptance:** 
- Task 1 unit tests pass
- `just build` succeeds
- Old JSON messages load with nil fields
- New messages encode/decode with values present

---

## Task 3: Update ChatMessage struct to mirror metadata
**Files:** `native/macos/Fae/Sources/Fae/ConversationController.swift`

**Description:** Mirror the changes to WorkWithFaeConversationMessage in the ChatMessage struct (which is the runtime, in-memory representation).

Changes (~40 lines):
1. Add properties: `let modelID: String?` and `let providerKind: String?`
2. Update init signature with nil defaults
3. Update any factory methods or conversion points that create ChatMessage instances
4. Maintain Equatable conformance (compare new fields too)

Note: ChatMessage is NOT persisted, so it doesn't need Codable. However, it needs to flow through the app when messages are created/displayed.

**Acceptance:**
- `just build` succeeds
- ChatMessage init compiles with new parameters
- Equatable comparison includes new fields
- Existing code that creates ChatMessage still works (parameters optional)

---

## Task 4: Update conversion functions in CoworkWorkspaceController
**Files:** `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift`

**Description:** Update the workspaceConversationMessage(from:) and chatMessage(from:) conversion functions to map the new metadata fields bidirectionally.

Changes (~60 lines total):
1. In workspaceConversationMessage(from message: ChatMessage): pass message.modelID and message.providerKind to the WorkWithFaeConversationMessage initializer
2. In chatMessage(from message: WorkWithFaeConversationMessage): pass message.modelID and message.providerKind to the ChatMessage initializer
3. Add a note/TODO that these will be populated by submission paths in subsequent tasks

These are the bridge functions between runtime messages and persisted workspace state.

**Acceptance:**
- `just build` succeeds
- Conversion functions compile with new parameters
- Round-trip conversion preserves modelID and providerKind values
- Nil values convert correctly in both directions

---

## Task 5: Wire modelID and providerKind into runSingleAgentSubmission
**Files:** `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift`

**Description:** Populate the new metadata fields in the single-agent submission path. This is the most common path.

Changes (~80 lines):
1. In runSingleAgentSubmission, when appending the user message: capture the model identifier and provider kind from executionAgent
   - modelID = executionAgent.modelIdentifier
   - providerKind = executionAgent.providerKind.rawValue (or similar enum to string conversion)
2. Modify the line that calls `self.conversation.appendMessage(role: .user, content: prompt)` to instead:
   - Create a ChatMessage directly with modelID and providerKind set to user message values (or nil for user messages)
   - OR: update appendMessage signature to accept optional modelID/providerKind parameters
3. When appending the assistant response (around line 1411), capture model metadata and pass it:
   - `self.conversation.appendMessage(role: .assistant, content: response.content, modelID: executionAgent.modelIdentifier, providerKind: executionAgent.providerKind.rawValue)`
4. Handle the fallback path (direct injection via faeCore) — mark with metadata if possible, or leave nil

**Acceptance:**
- User messages in single-agent flow have modelID and providerKind metadata
- Assistant messages from external providers have modelID and providerKind set
- Assistant messages from localhost fallback have appropriate metadata (or nil)
- `just build` succeeds
- Messages persist and load with metadata intact

---

## Task 6: Wire modelID and providerKind into runConsensus
**Files:** `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift`

**Description:** Populate metadata in the consensus/multi-agent comparison path. This is more complex because consensus involves multiple agents.

Changes (~100 lines):
1. When appending the initial user message (around line 1584): set modelID and providerKind to nil (user message has no model attribution)
2. In the task group that gathers consensus results (lines 1594-1643):
   - Each agent's response should be tagged with that agent's model metadata
   - Capture agentID, modelIdentifier, providerKind from the agent being queried
3. When building the consensus summary response (around line 1651):
   - The synthesized assistant message should have modelID = nil and providerKind = "consensus" (or similar marker)
   - OR: modelID = "consensus-synthesis" to indicate it's a synthesized response from multiple agents
4. Optional: add individual consensus results as separate messages with each agent's metadata, or keep summary-only

For simplicity, start with: user messages have nil metadata, consensus summary has providerKind="consensus-synthesis" and modelID=nil.

**Acceptance:**
- User message in consensus flow has no model attribution
- Consensus summary message has providerKind="consensus-synthesis"
- Flow works with 1 agent, 2 agents, or more
- Metadata persists correctly
- `just build` succeeds

---

## Task 7: Extract synthesis logic and wire metadata
**Files:** `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift`

**Description:** Locate and update any synthesis/agentic-summary code path (if it exists separately from consensus). This may be part of runConsensus or a distinct flow.

Changes (~60 lines):
1. Find synthesis-specific message appending (search for "synthesis" in the file)
2. Identify where synthesized responses are added to the conversation
3. Tag synthesized messages with: modelID = nil, providerKind = "synthesis" (or "agentic-synthesis")
4. Ensure the synthesis request message (if logged) is tagged with user/nil metadata

If synthesis is fully integrated into runConsensus, note that in the PR description and skip this task.

**Acceptance:**
- Synthesis messages have appropriate providerKind metadata
- Both synthesis and consensus flows tag responses correctly
- `just build` succeeds

---

## Task 8: Update appendMessage signature to accept optional metadata
**Files:** `native/macos/Fae/Sources/Fae/ConversationController.swift`

**Description:** Enhance the appendMessage method to accept the new metadata fields, making submission paths cleaner.

Changes (~30 lines):
1. Update appendMessage signature: `func appendMessage(role: ChatRole, content: String, modelID: String? = nil, providerKind: String? = nil)`
2. Create ChatMessage with all four parameters
3. Update any internal calls to appendMessage that now have metadata available

This makes it easier for submission paths to pass metadata when creating messages without needing to construct ChatMessage directly.

**Acceptance:**
- appendMessage signature accepts modelID and providerKind
- Default values allow backward compat with existing call sites
- Messages created via appendMessage have metadata set correctly
- `just build` succeeds

---

## Task 9: Add MessageOverride struct for ephemeral per-request settings
**Files:** `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceModels.swift`

**Description:** Create a reusable structure for per-request overrides (temperature, model, etc.) that can be applied at submission time without modifying the agent profile permanently.

Changes (~50 lines):
1. Define MessageOverride struct:
   ```
   struct MessageOverride: Sendable {
       let temperatureOverride: Double?
       let modelIDOverride: String?
       let providerKindOverride: String?
       let systemPromptOverride: String?
       let maxTokensOverride: Int?
   }
   ```
2. Make it Codable for potential persistence
3. Add convenience init with all-nil defaults
4. Add a method to "apply" overrides to a request (merge with defaults)
5. Store in CoworkWorkspaceState if needed for later replay

This sets up infrastructure for future adaptive sampling and model selection UI.

**Acceptance:**
- MessageOverride struct compiles and is Sendable
- Can be instantiated with partial overrides
- `just build` succeeds
- Struct is integrated into CoworkWorkspaceModels (even if not actively used yet)

---

## Task 10: Add migration/validation test for persistence round-trip
**Files:** `native/macos/Fae/Tests/CoworkTests/WorkspaceStatePersistenceTests.swift` (new or extend existing)

**Description:** Write integration tests that verify WorkWithFaeWorkspaceState with messages can be saved and loaded, preserving model metadata across app restarts.

Test cases:
1. Create WorkWithFaeWorkspaceState with messages containing modelID/providerKind
2. Encode to JSON and write to disk (simulate persistence)
3. Read JSON from disk and decode back
4. Verify all message metadata is preserved
5. Load an old workspace file (without metadata) and verify it loads without crashing
6. Verify metadata is correctly attributed to user vs assistant messages

~80 lines of test code covering the persistence layer.

**Acceptance:**
- All 6 test cases pass
- Old workspace files load correctly (backward compat verified)
- New metadata fields persist through save/load cycle
- `just test` includes and passes these tests

---

## Task 11: Document metadata semantics in code comments
**Files:** All modified files from Tasks 2-9

**Description:** Add code comments and doc strings explaining the semantics and expected values for modelID and providerKind fields.

Changes (~40 lines of comments):
1. On WorkWithFaeConversationMessage:
   - Explain that modelID should be nil for user messages
   - Explain providerKind values: "fae-localhost", "openai", "anthropic", "consensus-synthesis", etc.
   - Note that old messages will have nil values
2. On ChatMessage:
   - Mirror the documentation
3. On appendMessage in ConversationController:
   - Explain when to pass modelID/providerKind
4. On MessageOverride:
   - Explain use cases and when to apply

This aids future maintainers and API consumers.

**Acceptance:**
- All new/modified structures have clear doc comments
- Semantics of metadata values are documented
- No code changes needed (comments only)
- `just build` still succeeds

---

## Task 12: Verify metadata is correctly retrieved in workspace view/export
**Files:** `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift` (query/accessor methods)

**Description:** Ensure that when workspaces are viewed, exported, or queried (e.g., for UI display), the metadata is accessible and correct.

Changes (~40 lines):
1. Review any methods that fetch messages from workspaceState.conversationMessages
2. Ensure metadata fields are accessible (no filtering/stripping)
3. Add a helper method if needed: `func messageMetadata(for message: WorkWithFaeConversationMessage) -> (modelID: String?, providerKind: String?)`
4. Test in workspace list/detail views that metadata doesn't cause display issues

**Acceptance:**
- Messages with metadata load and display correctly in UI
- Metadata is preserved when workspaces are viewed/reopened
- No runtime crashes due to nil metadata
- `just build` succeeds

---

## Task 13: Integration test: end-to-end metadata flow
**Files:** `native/macos/Fae/Tests/IntegrationTests/MessageMetadataIntegrationTests.swift` (new)

**Description:** Write an end-to-end integration test simulating a realistic workflow: create messages via submission paths, verify metadata is set, persist workspace, reload, verify metadata is still there.

Test flow (~120 lines):
1. Create a CoworkWorkspaceController instance with a mock workspace
2. Simulate a single-agent submission: call runSingleAgentSubmission (or mock it)
3. Verify the conversation has user + assistant messages with correct metadata
4. Simulate a consensus submission with 2 agents
5. Verify consensus summary message is tagged correctly
6. Serialize workspaceState to JSON
7. Deserialize and verify all metadata is intact
8. Check that viewing the workspace re-loads metadata correctly

**Acceptance:**
- Test simulates realistic workflow end-to-end
- All metadata assertions pass
- Test runs in ~1-5 seconds (no real network calls)
- `just test` includes and passes this test

---

## Summary of Changes

### New Fields on WorkWithFaeConversationMessage
```
let modelID: String?              // e.g., "gpt-4", "claude-opus", nil for user messages
let providerKind: String?         // e.g., "openai", "anthropic", "consensus-synthesis", nil for user messages
```

### New Fields on ChatMessage
```
let modelID: String?
let providerKind: String?
```

### New MessageOverride Struct
```
struct MessageOverride: Sendable, Codable {
    let temperatureOverride: Double?
    let modelIDOverride: String?
    let providerKindOverride: String?
    let systemPromptOverride: String?
    let maxTokensOverride: Int?
}
```

### Updated Submission Paths
- **runSingleAgentSubmission**: User message tagged nil/nil, assistant message tagged with agent's model/provider
- **runConsensus**: User message tagged nil/nil, consensus summary tagged with "consensus-synthesis" as providerKind
- **Synthesis paths**: Tagged with "synthesis" or "agentic-synthesis" as providerKind

### Backward Compatibility
- All new fields are optional (String? instead of String)
- decodeIfPresent is used in Codable logic
- Old JSON messages load successfully with nil for new fields
- Existing code that creates ChatMessage/WorkWithFaeConversationMessage still works (parameters optional)

---

## Testing Strategy (TDD Order)

1. **Task 1**: Unit test for backward-compatible decoding (tests fail initially)
2. **Task 2**: Implement fields on WorkWithFaeConversationMessage (Task 1 tests pass)
3. **Task 3**: Mirror fields on ChatMessage
4. **Task 4**: Update conversion functions (bridge runtime and persistence)
5. **Task 5**: Wire metadata into runSingleAgentSubmission (verify with manual test)
6. **Task 6**: Wire metadata into runConsensus (verify with manual test)
7. **Task 7**: Wire metadata into synthesis (if separate path exists)
8. **Task 8**: Enhance appendMessage signature for cleaner API
9. **Task 9**: Add MessageOverride struct (infrastructure for future features)
10. **Task 10**: Integration test for persistence round-trip
11. **Task 11**: Documentation and code comments
12. **Task 12**: Verify UI/export don't break with metadata
13. **Task 13**: Full end-to-end integration test

---

## Acceptance Criteria (Overall Phase)

1. All 13 tasks complete and pass `just build` and `just test`
2. Old workspace JSON files load without error (backward compat verified)
3. New messages in all submission paths have correct modelID and providerKind
4. Metadata persists through save/load cycles
5. No UI crashes or regressions
6. Code is well-documented and maintainable
