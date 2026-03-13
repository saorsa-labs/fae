# Session search and staged skill distillation plan - 2026-03-13

**Status:** Proposed  
**Audience:** Runtime, memory, skills, scheduler, security, UX  
**Scope:** Main Fae assistant runtime in `native/macos/Fae`; excludes Cowork-specific conversation history except where noted for comparison

---

## Read this first

This document proposes two additions to the current Swift runtime:

1. a first-class local `session_search` capability
2. a staged skill-distillation pipeline that produces reviewable drafts instead of silently mutating skills

Read in this order:

1. `docs/architecture/session-search-and-skill-distillation-plan-2026-03-13.md`
   - target model
   - data boundaries
   - implementation phases
2. `docs/guides/Memory.md`
   - current memory storage and recall contract
3. `docs/guides/self-modification.md`
   - current skills and self-modification model
4. `docs/guides/scheduler-tooling-and-permissions.md`
   - scheduler authority and approval boundaries
5. `docs/guides/security-autonomy-boundary-and-execution-plan.md`
   - immutable local enforcement model

---

## 1) Problem statement

Fae already has strong structured memory:

- per-turn capture into `episode` plus durable memory records
- hybrid ANN + FTS recall
- digest synthesis
- explicit supersession and audit lineage

That is the right foundation for durable user knowledge.

What Fae does not currently have is:

- a first-class searchable transcript/session layer for "what did we say last week about X?"
- a workflow trace layer rich enough to distill repeated successful procedures into reviewable skills

The current gap shows up in two places:

1. `episode` memory is a useful fallback for transcript fragments, but it is not a real session model.
2. `skill_proposals` are currently interest-driven, not evidence-driven from successful workflows.

This plan closes those gaps without weakening the current local-first and approval-gated architecture.

---

## 2) Current reality in code

### 2.1 Main conversation state is transient

The main assistant keeps short context-window history in memory, synchronized into model session caches:

- `Pipeline/ConversationState.swift`
- `Pipeline/PipelineCoordinator.swift`
- `Core/MLProtocols.swift`

That state is intentionally resettable and bounded for prompt budget reasons. It is not a durable search index.

### 2.2 Durable recall is memory-centric, not session-centric

Completed turns are persisted through the memory system:

- `Memory/MemoryOrchestrator.swift`
- `Memory/SQLiteMemoryStore.swift`
- `Memory/MemoryDigestService.swift`

Each turn becomes an `episode` memory record and may also produce `profile`, `fact`, `interest`, `commitment`, `event`, or `person` records.

This gives Fae a weak form of transcript recall because episode text is searchable. It does not provide:

- session boundaries
- grouped conversation retrieval
- transcript windows around matches
- explicit tool-call history per turn
- session summaries
- search-only provenance distinct from durable memory

### 2.3 Current skill learning is proposal-only

The current self-modification path is intentionally conservative:

- `Scheduler/FaeScheduler.swift` surfaces `skill_proposals`
- `Tools/TrustedActionBroker.swift` prevents scheduler auto-use of `manage_skill`
- `Tools/SkillTools.swift` exposes `manage_skill`
- `Skills/SkillManager.swift` applies create/update/delete to personal skills
- `Skills/SkillSecurityReview.swift` scans imported or drafted skill content

This means background automation can suggest, but cannot silently install or edit skills.

That boundary is correct and should remain.

### 2.4 Observability is too shallow for distillation

Current telemetry is helpful for diagnostics, not enough for procedural learning:

- `Tools/ToolAnalytics.swift` records tool name, success, approval, latency, and error
- `Tools/SecurityEventLogger.swift` records append-only local events with hashed arguments

What is missing is a structured per-turn workflow trace with ordered steps, sanitized inputs, sanitized outputs, and end-state quality signals.

---

## 3) Golden invariants

These are the non-negotiable rules for the design.

### 3.1 Memory, session search, and skills remain separate systems

- **Memory** is for durable extracted knowledge and digests.
- **Session search** is for searchable transcript/session recovery.
- **Skills** are reusable operational procedures.

Do not collapse these into one table or one abstraction.

### 3.2 Session search is local-first and on-demand

Session search should not be injected into every prompt by default.

It is a targeted retrieval path for queries like:

- "what did we say about that last Tuesday?"
- "find the earlier chat where I mentioned the supplier"
- "what was the exact wording you suggested before?"

### 3.3 Distillation is draft-first, never silent mutation

Background analysis may produce:

- candidate evidence
- draft skill content
- a proposed update target

It may not:

- directly call `manage_skill`
- silently modify an installed skill
- overwrite a skill without user review

### 3.4 Scheduler denylist stays intact

The current restriction that scheduler tasks cannot use `manage_skill`, `write`, `edit`, or `bash` should remain in place.

Distillation must work within that model by creating drafts, not by gaining new mutation authority.

### 3.5 Local trust model remains the source of truth

- no remote transcript export by default
- no remote draft-skill generation for private workflows by default
- no credential-bearing tool inputs stored in raw form

---

## 4) Target architecture

The target model is three stacked subsystems:

1. **Memory layer** for durable facts, preferences, commitments, entity knowledge, and digests
2. **Session layer** for local transcript storage and search
3. **Workflow/distillation layer** for trace capture and draft skill generation

The systems should interoperate, but none of them should substitute for the others.

---

## 5) Session search design

### 5.1 Why Fae needs this

Episode memory already captures each turn, but it is the wrong abstraction for transcript retrieval.

Episode memory is:

- optimized for recall relevance, not transcript fidelity
- bounded and summarized in prompt use
- mixed together with durable memory records
- not grouped into sessions

`session_search` should be the transcript recovery layer that complements memory, not replaces it.

### 5.2 Storage decision

**Decision:** store session-search data in the same `fae.db` file, but in separate tables managed by a separate Swift actor/service.

Reasoning:

- keeps backup/restore aligned with the existing app support storage contract
- avoids inventing a second primary database
- preserves logical separation from `memory_records`
- allows phased migration without reworking the whole memory stack first

Implementation note:

- use a dedicated `SessionStore` actor with its own GRDB `DatabaseQueue` against the same SQLite file for the first iteration
- if cross-store transaction needs grow later, introduce a shared `AppDatabase` wrapper in a separate follow-up

### 5.3 Proposed schema

Add new tables alongside memory tables:

| Table | Purpose |
|------|---------|
| `conversation_sessions` | Session metadata for main Fae conversations |
| `session_messages` | Durable message log for user, assistant, and tool events |
| `session_message_fts` | FTS5 index over searchable message text |
| `session_summaries` | Rolling local summaries for closed or long sessions |

Recommended columns:

#### `conversation_sessions`

- `id TEXT PRIMARY KEY`
- `kind TEXT NOT NULL` (`main`, `proactive`, `system`)
- `started_at INTEGER NOT NULL`
- `ended_at INTEGER`
- `last_message_at INTEGER NOT NULL`
- `speaker_id TEXT`
- `title TEXT`
- `message_count INTEGER NOT NULL DEFAULT 0`
- `status TEXT NOT NULL DEFAULT 'open'`

#### `session_messages`

- `id TEXT PRIMARY KEY`
- `session_id TEXT NOT NULL REFERENCES conversation_sessions(id) ON DELETE CASCADE`
- `turn_id TEXT`
- `role TEXT NOT NULL` (`user`, `assistant`, `tool`, `system`)
- `tool_name TEXT`
- `tool_call_id TEXT`
- `content TEXT NOT NULL`
- `content_class TEXT NOT NULL DEFAULT 'private_local_only'`
- `created_at INTEGER NOT NULL`

#### `session_summaries`

- `id TEXT PRIMARY KEY`
- `session_id TEXT NOT NULL REFERENCES conversation_sessions(id) ON DELETE CASCADE`
- `summary_text TEXT NOT NULL`
- `message_count_covered INTEGER NOT NULL`
- `created_at INTEGER NOT NULL`
- `model_label TEXT`

### 5.4 Session lifecycle

Add session ownership to `PipelineCoordinator`.

Rules:

1. Start a session when the first accepted user turn arrives and no active session exists.
2. Reuse the active session until one of these happens:
   - explicit reset
   - long inactivity timeout
   - app shutdown
3. Close the session by writing `ended_at` and generating or refreshing a bounded summary.
4. Proactive scheduler turns should use `kind = proactive` and should be excluded from normal user-facing `session_search` unless the query explicitly asks for them.

### 5.5 What gets stored

Persist these message types:

- accepted user turns
- final assistant responses
- tool results actually surfaced to the model or user
- system markers for approvals/denials only when needed for context

Do not persist:

- partial STT fragments
- hidden reasoning traces
- raw secrets
- full unredacted tool arguments

### 5.6 Search behavior

Add a low-risk tool:

`session_search(query, limit = 5, days = 180, include_proactive = false)`

Search algorithm for v1:

1. FTS5 over `session_messages.content`
2. recency weighting at the session level
3. group hits by `session_id`
4. extract a small message window around each match
5. summarize each session hit locally

Important design choice:

- start with lexical FTS5 plus session-level recency and window extraction
- do **not** add embeddings in v1 unless search quality proves insufficient

Transcript search is usually lexical and provenance-sensitive. FTS5 plus local summarization is the right first step.

### 5.7 Search result contract

`session_search` should return:

- session date or date range
- short session title
- why it matched
- compact summary
- 1 to 3 short excerpts

It should **not** dump entire transcripts into the prompt unless the user explicitly asks for that.

### 5.8 When the model should use it

Prompt/tool guidance should encourage `session_search` when:

- the user asks about a previous conversation
- the query asks for exact wording or prior decisions
- memory recall is thin but the request is clearly transcript-oriented
- the user corrects Fae with "no, we talked about this before"

Prompt guidance should **not** tell the model to use `session_search` for durable facts that memory already answers well.

---

## 6) Workflow trace and skill-distillation design

### 6.1 Why this must be separate from memory

Memory answers:

- what matters durably about the user
- what facts, commitments, or entities Fae should remember

Procedural distillation answers:

- which successful repeated workflows are worth turning into a reusable skill
- whether an existing skill should be refined

Those are different products with different safety rules.

### 6.2 New workflow-trace store

Add a dedicated store for per-turn workflow traces.

New tables:

| Table | Purpose |
|------|---------|
| `workflow_runs` | One row per completed turn or proactive workflow candidate |
| `workflow_steps` | Ordered sanitized steps taken during a workflow run |
| `skill_draft_candidates` | Draft skill create/update proposals awaiting review |

Recommended columns:

#### `workflow_runs`

- `id TEXT PRIMARY KEY`
- `session_id TEXT`
- `turn_id TEXT`
- `source TEXT NOT NULL` (`conversation`, `scheduler`, `manual_review`)
- `user_goal TEXT`
- `assistant_outcome TEXT`
- `tool_sequence_signature TEXT`
- `step_count INTEGER NOT NULL DEFAULT 0`
- `success INTEGER NOT NULL`
- `user_approved INTEGER`
- `created_at INTEGER NOT NULL`

#### `workflow_steps`

- `id TEXT PRIMARY KEY`
- `run_id TEXT NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE`
- `step_index INTEGER NOT NULL`
- `step_type TEXT NOT NULL` (`tool_call`, `tool_result`, `approval`, `message`)
- `tool_name TEXT`
- `sanitized_input_json TEXT`
- `output_preview TEXT`
- `success INTEGER`
- `approved INTEGER`
- `latency_ms INTEGER`
- `created_at INTEGER NOT NULL`

#### `skill_draft_candidates`

- `id TEXT PRIMARY KEY`
- `status TEXT NOT NULL` (`pending`, `accepted`, `dismissed`, `applied`, `superseded`)
- `action TEXT NOT NULL` (`create`, `update`)
- `target_skill_name TEXT`
- `title TEXT NOT NULL`
- `rationale TEXT NOT NULL`
- `evidence_json TEXT NOT NULL`
- `draft_skill_md TEXT NOT NULL`
- `draft_manifest_json TEXT`
- `draft_script TEXT`
- `created_at INTEGER NOT NULL`
- `updated_at INTEGER NOT NULL`
- `confidence REAL NOT NULL DEFAULT 0.0`

### 6.3 Capture path

`PipelineCoordinator` should create a `workflow_run` for turns that meet at least one condition:

- at least one tool was called
- the workflow required explicit approval
- the user asked for a repeated or multi-step task
- the assistant referenced an existing skill

Each tool event then appends ordered `workflow_steps`.

This should happen inline with existing tool execution accounting, but store only sanitized payloads:

- redact or drop sensitive arguments
- keep short previews, not raw full results
- never persist Keychain material or secrets

### 6.4 Distillation eligibility heuristics

A run becomes a candidate for skill distillation only if all of these are true:

1. the run succeeded
2. the run was not blocked by damage-control or disaster policy
3. the sequence is non-trivial
4. the same or highly similar workflow appears more than once, or is clearly expensive enough to merit reuse

Recommended initial heuristics:

- `step_count >= 3`
- at least 2 successful similar runs in the last 30 days
- or 1 high-complexity run with repeated user correction or explicit "save this workflow" intent
- no candidate if an existing skill already cleanly covers the same sequence

Similarity should start simple:

- normalized user-goal token overlap
- identical or near-identical tool sequence signature
- optional same target domains or output shape

Do not start with a heavy embedding pipeline for workflow similarity in v1.

### 6.5 Candidate generation

Add a scheduler task such as `skill_distill` that:

1. scans recent `workflow_runs`
2. groups eligible runs into candidate clusters
3. decides whether to create a new skill draft or update an existing personal skill
4. writes a `skill_draft_candidates` row
5. optionally writes a low-noise reminder memory or inbox item so the assistant can surface it later

Critical boundary:

- this task creates drafts only
- it must not invoke `manage_skill`

### 6.6 Draft format

Each candidate should include:

- proposed skill name
- concise description
- draft `SKILL.md`
- optional script draft
- optional manifest draft
- rationale
- supporting run IDs and simplified evidence

This gives Fae a real procedural-memory artifact without installing anything yet.

### 6.7 Review and apply flow

The user-facing flow should be:

1. Fae notices a draft candidate
2. Fae says she drafted a possible skill based on repeated successful work
3. Fae shows the full draft for review
4. user accepts, edits, or dismisses
5. only after explicit acceptance does Fae call `manage_skill`

This matches the current self-modification contract and keeps review auditable.

### 6.8 Mutator improvements

The current `manage_skill` API is sufficient for v1 draft adoption, but not ideal for long-term distillation quality.

Recommended follow-up additions:

- `patch`
- `update_script`
- `write_reference_file`
- `replace_manifest`

These should still be:

- limited to personal skills
- approval-gated
- reviewable before apply

Do not let background automation call these directly.

---

## 7) Safety and privacy model

### 7.1 Session-search safety

Session transcripts are private local context by default.

Rules:

- not auto-exported remotely
- not used as generic prompt ballast
- not retrieved unless the query is session-oriented or the model chooses the explicit tool

### 7.2 Trace-capture safety

Workflow traces must store sanitized inputs and output previews only.

Never persist:

- secrets
- raw tokens
- private keys
- full hidden prompts
- unredacted credential-bearing HTTP headers

### 7.3 Distillation safety

Before surfacing a draft skill:

- run `SkillSecurityReviewer` on the draft body and script
- mark obvious risky patterns in the candidate metadata
- require explicit user approval before applying

### 7.4 Built-in skill immutability remains

Distillation may:

- create a new personal skill
- update an existing personal skill
- create a personal override of a built-in skill name if that remains the chosen override model

It may not mutate built-in packaged skills in place.

---

## 8) Runtime touchpoints

Primary code areas expected to change:

| Area | Expected change |
|------|-----------------|
| `Pipeline/PipelineCoordinator.swift` | session lifecycle, message persistence, workflow trace capture |
| `Pipeline/ConversationState.swift` | no major semantic change; remains short-context runtime state |
| `Tools/ToolRegistry.swift` | register `session_search` |
| `Tools/TrustedActionBroker.swift` | allow low-risk `session_search`; keep scheduler denylist unchanged |
| `Scheduler/FaeScheduler.swift` | add `skill_distill` draft-generation task |
| `Memory/SQLiteMemoryStore.swift` | no semantic reuse for transcripts; avoid shoehorning session data into `memory_records` |
| `Skills/SkillManager.swift` | later support finer-grained update operations |
| `Tools/ToolAnalytics.swift` | remain diagnostics-only unless some fields are promoted into workflow traces |

---

## 9) Phased implementation order

### Phase 1 - Session foundation

- add `SessionStore`
- add session tables and migrations
- persist accepted user turns and final assistant turns
- close/open sessions on reset, inactivity, and startup boundaries

### Phase 2 - `session_search` tool

- add `SessionSearchTool`
- add FTS search and grouped result formatting
- add local summary generation with deterministic fallback
- add prompt guidance for transcript-oriented queries

### Phase 3 - Workflow traces

- add `WorkflowTraceStore`
- persist tool sequence traces from `PipelineCoordinator`
- redact and truncate payloads

### Phase 4 - Draft skill distillation

- add `skill_distill` scheduler task
- generate `skill_draft_candidates`
- surface candidates conversationally with low-noise reminders

### Phase 5 - Better skill mutation ergonomics

- extend `manage_skill` with patch/script/reference operations
- keep all mutation approval-gated
- add diff-oriented review UX if desired

---

## 10) What this plan deliberately does not do

This plan does **not**:

- replace structured memory with transcript storage
- let the scheduler silently install skills
- use remote models as the default distillation engine
- add full transcript embeddings in v1
- merge Cowork transcript storage into main assistant session storage yet

Those may become future extensions, but they are not required to ship a useful first version.

---

## 11) Recommended product language

When exposed to users, these concepts should be described simply:

- **Memory**: things Fae should remember durably
- **Session search**: search earlier conversations
- **Skill draft**: a reusable workflow Fae drafted for review

Avoid calling any of this "self-modifying AI" in the product surface. The implementation is safer and clearer when described as local memory, conversation search, and reviewable workflow drafts.

---

## 12) Bottom line

Fae should learn from Hermes at the architectural boundary, not by copying its internals.

The correct fit for the current Swift runtime is:

1. keep `memory_records` focused on durable knowledge
2. add a separate local transcript/session store
3. add a separate workflow trace and draft-candidate store
4. keep skill mutation explicit, reviewable, and approval-gated

That gives Fae:

- better answerability for prior-conversation questions
- stronger recoverability when memory extraction misses something
- a real path from repeated successful work to reusable skills
- no weakening of the existing trust and safety model
