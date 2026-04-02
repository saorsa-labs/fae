# CoWork Evolution — Onyx-Inspired Improvements

> Evolve Fae's CoWork module with battle-tested patterns from Onyx's chat architecture,
> preserving workspace isolation, threading, mid-conversation model switching, and security egress.

## Problem

Users can't maintain long conversation context (120-msg hard cap drops silently), consensus comparison is batch-mode (waits for all agents), and there's no audit trail of which model generated which response. Missing functionality that limits CoWork's usefulness for real work sessions.

## Success Criteria

Production ready — all features complete, tested, documented, with unit and integration coverage.

---

## Milestone 1: CoWork Intelligence

Foundation improvements: message metadata, context compression, and long-session support.

### Phase 1.1: Per-Message Model Metadata

**Goal:** Add model provenance to every conversation message.

- Add `modelID: String?`, `providerKind: String?` to `WorkWithFaeConversationMessage`
- Add optional `MessageOverride` struct for ephemeral per-request settings (temperature, model)
- Populate metadata on every submission path (single agent, consensus, synthesis)
- Backward-compatible: existing conversations load with nil metadata (no migration crash)
- Support per-request model/temperature overrides without changing workspace agent binding

**Key files:**
- `Cowork/WorkWithFaeWorkspace.swift` (message type, store)
- `Cowork/CoworkWorkspaceController.swift` (submission paths)

### Phase 1.2: Context Compression Engine

**Goal:** Build the compression actor that summarizes old messages using the local LLM.

- Create `ConversationCompressor` actor
- Progressive summarization: when history exceeds 75% of model context, compress older messages
- Keep recent 20% of messages verbatim
- Summary stored as special message with `role: "summary"` and metadata
- Subsequent compressions incorporate previous summary + new messages
- Branch-aware: workspace duplication preserves/respects compression state
- Uses `FaeLocalhostCoworkProvider` to invoke local LLM for summarization

**Key files:**
- New: `Cowork/ConversationCompressor.swift`
- `Cowork/WorkWithFaeWorkspace.swift` (summary message type, constants)
- `Cowork/CoworkLLMProvider.swift` (local LLM invocation)

### Phase 1.3: Context Compression Integration

**Goal:** Wire the compressor into the submit flow and add UI feedback.

- Auto-compress before provider calls when history exceeds threshold
- Replace hard 120-message cap with compression-first, then cap as fallback safety
- UI indicator showing compression state (e.g., "42 messages compressed into summary")
- Configurable ratios via `WorkWithFaeWorkspacePolicy`
- Compression respects model context window from `CoworkKnownModelRegistry`

**Key files:**
- `Cowork/CoworkWorkspaceController.swift` (submit flow)
- `Cowork/CoworkWorkspaceView.swift` (UI indicator)
- `Cowork/CoworkModelRegistry.swift` (context window lookup)
- `Cowork/WorkWithFaeWorkspace.swift` (policy fields)

### Phase 1.4: Tests for Milestone 1

**Goal:** Full test coverage for metadata and compression.

- Unit tests: message serialization with new fields, backward compatibility
- Unit tests: compression trigger logic, ratio calculations, summary message creation
- Unit tests: workspace duplication with compression state
- Integration tests: submit-with-compression flow (mock provider)
- Property tests: compression preserves most recent messages invariant

**Key files:**
- New/updated test files in Tests/

---

## Milestone 2: CoWork Streaming

Real-time streaming consensus and prompt optimization.

### Phase 2.1: Streaming Consensus Engine

**Goal:** Replace batch `runConsensus()` with streaming multi-agent comparison.

- Create `TaggedChunk` type with agent ID + content delta
- Replace `TaskGroup` batch collection with `AsyncStream<TaggedChunk>`
- Each agent streams independently; fastest shows immediately
- Independent failure: one agent error doesn't block others
- Cancel propagation: `Task.cancel()` + `withTaskCancellationHandler` for all in-flight requests
- Partial result preservation: completed agents keep results on cancel

**Key files:**
- `Cowork/CoworkWorkspaceController.swift` (runConsensus replacement)
- New: `Cowork/CoworkStreamingConsensus.swift` (engine)
- `Cowork/CoworkLLMProvider.swift` (streaming protocol usage)

### Phase 2.2: Streaming Consensus UI

**Goal:** Live multi-column rendering as tokens arrive.

- Multi-column view with per-agent streaming text
- Loading/error/complete states per agent column
- Partial results preserved visually on cancel
- Per-agent error display (not blocking other columns)
- Smooth scrolling during streaming

**Key files:**
- `Cowork/CoworkWorkspaceView.swift` (consensus UI)
- `Cowork/CoworkWorkspaceModels.swift` (streaming state models)

### Phase 2.3: Prompt Positioning Optimization

**Goal:** Apply research findings to improve external provider instruction following.

- Place critical instructions at end of context (90% vs 30% follow rate)
- Reminders as last user message in prompt construction
- Topic change boundaries at message splits
- Update `CoworkPromptEgressPolicy` for optimized positioning

**Key files:**
- `Cowork/CoworkExportPacket.swift` (prompt assembly)
- `Cowork/CoworkLLMProvider.swift` (system prompt positioning)

### Phase 2.4: Tests for Milestone 2

**Goal:** Full test coverage for streaming and positioning.

- Unit tests: streaming consensus with mock providers (fast/slow/error scenarios)
- Unit tests: cancel propagation and partial result preservation
- Unit tests: prompt positioning order verification
- Integration tests: multi-agent streaming end-to-end

**Key files:**
- New/updated test files in Tests/

---

## Auto-Selected Standards

| Decision | Selection |
|----------|-----------|
| Testing | Unit + Integration + Property |
| Error handling | Typed Swift errors (existing CoworkToolExecutorError pattern) |
| Task size | ~50 lines per task |
| Approach | TDD — tests first |
| Async | async/await + TaskGroup + AsyncStream (match existing) |
| Docs | Full public API docs on new types |
