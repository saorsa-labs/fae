# World-Class Regression Roadmap for Fae

## Goal

Build a regression program that protects:

- the main Fae conversation experience
- Work with Fae workspace conversations
- local/remote trust boundaries
- tools and approvals
- skills and manifests
- scheduler and proactive behavior
- heartbeat and personality contracts
- memory durability and docs truthfulness

This roadmap is intentionally product-facing, not just code-facing: if Fae claims a behavior in docs or UX copy, we should have automated coverage or an explicit manual verification checklist for it.

## Current baseline

As of this snapshot:

- `swift test` passes
- **551 tests** pass
- roughly **60 Swift test files** exist across:
  - `Tests/HandoffTests`
  - `Tests/IntegrationTests`
  - `Tests/SearchTests`

Current strengths already include:

- security hardening and prompt-safety regressions
- tool mode filtering and broker policy
- Work with Fae registry, prompt preparation, provider requests, streaming, and fork stability
- scheduler persistence and reliability basics
- voice pipeline regressions
- memory orchestrator and runtime contract coverage

## Gaps to close next

The most important remaining gaps are:

1. **Conversation-shell routing coverage**
   - main Fae vs Work with Fae routing
   - streaming state transitions
   - model-label propagation
   - background-lookup lifecycle

2. **Personality and truth-source contracts**
   - `SOUL.md`
   - `HEARTBEAT.md`
   - system prompt alignment
   - docs that describe trust boundaries and optional remote providers

3. **Heartbeat / proactive behavior testing**
   - user heartbeat save/load/reset behavior
   - modified-state detection
   - prompt injection into assembled personality prompt
   - scheduler/heartbeat interaction expectations

4. **Main-app continuity testing**
   - message trimming
   - restore/replace flows
   - handoff snapshot behavior
   - typed input and notification wiring

5. **Expanded scheduler + skills scenario coverage**
   - user-created scheduler tasks
   - built-in immutability guarantees
   - skill CRUD + manifest integrity + activation/update/delete sequences
   - scheduler-to-tool allowlist behavior under realistic task payloads

6. **Docs-as-contract coverage**
   - README and Work with Fae guide should not drift from shipped behavior
   - remote-provider claims must stay honest
   - local-only / strict-local / approval behavior must remain explicit

## Test program phases

### Phase 1 — Contracts and routing

Purpose: lock down the product truths that are easiest to accidentally regress.

Add or expand tests for:

- `ConversationBridgeController`
- `ConversationController`
- `SoulManager`
- `HeartbeatManager`
- prompt assembly truth sources
- README / Work with Fae trust-boundary wording

Success criteria:

- cowork routing is covered by tests
- SOUL / HEARTBEAT persistence and defaults are covered by tests
- trust-boundary docs assertions exist for the most critical user-facing guarantees

### Phase 2 — Main Fae conversation reliability

Purpose: harden the primary companion experience.

Cover:

- streaming lifecycle edge cases
- user/assistant/tool event ordering
- message replacement and restoration
- handoff restore invariants
- background tool job accounting
- approval-window routing invariants when cowork is active

Success criteria:

- conversation state changes remain deterministic under route switches
- no duplicate or lost messages in common recovery paths

### Phase 3 — Tools, approvals, and security fuzzing

Purpose: treat the tool boundary like safety-critical infrastructure.

Cover:

- broader broker decision matrices
- property-style tests for mode filtering and risk mapping
- exfiltration and sensitive-content guard edge cases
- path policy traversal cases
- capability ticket replay/expiry behavior
- approval persistence and revoke behavior

Success criteria:

- critical allow/deny paths are table-driven and exhaustively asserted
- high-risk inputs get regression fixtures

### Phase 4 — Skills, scheduler, heartbeat, and proactive flows

Purpose: validate the autonomous systems that quietly keep Fae useful.

Cover:

- skill create/update/delete/activate flows end-to-end
- manifest migration and tamper detection
- scheduler user task lifecycle, mutation, and persistence
- heartbeat contract editing and prompt inclusion
- morning briefing / skill proposal / relationship maintenance trigger behavior where testable

Success criteria:

- proactive and extensibility layers have both unit and scenario coverage
- user-facing automation claims are tied to automated checks where practical

### Phase 5 — Docs truthfulness and long-run reliability

Purpose: ensure the shipped app and the written claims stay aligned over time.

Cover:

- docs contract tests for key claims
- long-run persistence/reload loops
- repeated workspace switch/fork/restore scenarios
- stress tests for conversation trimming and registry persistence
- focused manual QA checklist where automation is not appropriate

Success criteria:

- docs drift is caught early
- long-running stateful workflows have replayable regression coverage

## Coverage principles

1. **Prioritize user-visible breakage over line coverage.**
2. **Prefer deterministic tests over flaky timer-based tests.**
3. **Add seams for filesystem/runtime overrides where needed.**
4. **Treat docs and bundled prompt contracts as testable product surface.**
5. **Keep security and privacy boundaries under explicit regression checks.**
6. **When a bug is fixed, capture the exact failing scenario in tests before moving on.**

## Near-term execution order

1. Phase 1: contracts and routing
2. Phase 2: main conversation reliability
3. Phase 3: security + approval matrix expansion
4. Phase 4: scheduler/skills/heartbeat automation coverage
5. Phase 5: docs drift + long-run stress harnesses

## Metrics to track

For each phase, track:

- test file count
- total test count
- flaky test count
- runtime of targeted suites
- runtime of full `swift test`
- number of product claims explicitly covered by automated tests

## Definition of “world class” for this project

For Fae, world class means:

- regressions in conversation continuity are caught before shipping
- remote/local trust-boundary drift is caught automatically
- tools and approvals are tested like security boundaries
- personality and proactive behavior contracts are not treated as untestable prose
- docs stop being marketing text and become verifiable product contracts
- every major user-reported bug gains a durable regression test
