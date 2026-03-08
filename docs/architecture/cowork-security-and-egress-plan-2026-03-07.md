# Cowork security and remote egress plan — 2026-03-07

**Status:** Implemented baseline (Phase 1 export hardening)  
**Audience:** Product, Cowork runtime, security reviewers, UX  
**Scope:** `native/macos/Fae/Sources/Fae/Cowork/*` and any main-runtime code that governs remote delegation, export, or approval for Cowork

---

## Read this first

This document defines the canonical security model for Cowork.

Read in this order:

1. `docs/architecture/cowork-security-and-egress-plan-2026-03-07.md`
   - trust model
   - export contract
   - implementation phases
   - documentation requirements
2. `docs/guides/work-with-fae.md`
   - current product behavior and user-visible Cowork model
3. `docs/guides/security-autonomy-boundary-and-execution-plan.md`
   - core boundary between mutable workflows and non-bypassable enforcement
4. `docs/checklists/security-pr-review-checklist.md`
   - merge gate for security-sensitive changes

---

## 1) Current reality in code

The current Swift implementation already has a strong starting shape:

- `Fae Local` in Cowork routes to the same trusted local runtime path used by main Fae.
- the trusted local runtime currently delegates operator and concierge generation to device-local worker subprocesses
- Remote Cowork providers receive a packet-backed shareable export, not the full local prompt.
- Remote Cowork providers do not get arbitrary local tools.
- raw recent conversation history stays local by default for remote sends
- absolute attachment and focused-item path metadata is stripped from remote sends
- Remote sends are locally blocked when the prompt appears to contain likely credentials.

The current weaknesses are also clear:

- the remote egress blocker is mainly a secret detector, not a full personal-data policy
- trust tier handling is still conservative and coarse for external providers
- export review receipts and brokered follow-up intents are not implemented yet
- the user-facing hold/send-anyway experience is too blunt and does not explain the actual data boundary

This plan tightens those areas without weakening Cowork usefulness.

---

## 2) Golden security invariant

No secret, personal memory, privileged local state, or sensitive workspace context leaves the Mac unless local Fae intentionally exports a minimized packet under a policy the user can understand.

Corollaries:

1. `Local Fae` is the only privileged principal.
2. `Remote models` are advisory reasoning workers, not operators.
3. `Authority` stays local even when `reasoning` is delegated.
4. Remote use is governed by explicit export policy, not by prompt convention.

---

## 3) Trust tiers

All remote policy decisions must key off trust tier, not provider API shape.

### 3.1 `device_local`

Used for:

- Fae Local
- the main on-device runtime
- device-local operator and concierge worker subprocesses launched by the app
- localhost Cowork routing

Allowed:

- full local tool authority
- memory recall
- local-only workspace context
- scheduler writes
- skill execution

### 3.2 `user_controlled_local_network`

Used for future self-hosted LAN endpoints.

Allowed:

- explicit export packets
- brokered follow-up intents

Not allowed by default:

- raw local tools
- direct memory recall
- raw Keychain access

### 3.3 `user_controlled_remote_server`

Used for user-owned remote infrastructure.

Policy:

- treated as remote for egress purposes
- may receive more generous defaults later, but not in v1

### 3.4 `third_party_cloud`

Used for:

- OpenAI
- Anthropic
- OpenRouter
- similar hosted model providers

Policy:

- lowest trust
- strictest remote export defaults

---

## 4) Data classes

Every durable or exported datum should carry one of these classes.

### 4.1 `secret`

Examples:

- passwords
- API keys
- bearer tokens
- cookies
- OTP / MFA / recovery codes
- SSH private keys

Rule:

- never auto-export
- never remote by memory recall
- never included from Keychain or hidden local state

### 4.2 `private_local_only`

Examples:

- personal memories
- family details
- health, finance, or relationship facts
- private conversation history
- behavioral patterns and routines

Rule:

- local by default
- remote only via an explicit user-directed summary flow if later supported

### 4.3 `workspace_confidential`

Examples:

- absolute file paths
- local usernames and hostnames
- workspace inventory
- internal documents
- local environment details

Rule:

- not remote by default
- remote only as selected excerpts or redacted summaries

### 4.4 `shareable_context`

Examples:

- user-selected snippets
- approved attachment excerpts
- sanitized workspace summaries
- non-sensitive structured tool results

Rule:

- eligible for remote export when the destination trust tier permits it

### 4.5 `public`

Examples:

- public facts
- user-authored text with no protected content
- public web material

Rule:

- eligible for remote export

---

## 5) Egress policy model

Data class alone is not enough. Each item should also carry an egress policy.

### 5.1 `never_remote`

Used for:

- secrets
- Keychain values
- raw memory records marked local-only

### 5.2 `local_summary_only`

Used for:

- private memories
- Apple-app data that should remain local but may be summarized locally

### 5.3 `explicit_user_export_only`

Used for:

- file excerpts
- sensitive attachments
- high-context prior conversation

### 5.4 `allowed_redacted_remote`

Used for:

- sanitized summaries
- path-stripped file excerpts
- selected text attachments

### 5.5 `allowed_remote`

Used for:

- public content
- current user prompt when no higher-risk content is present

---

## 6) Export packet contract

All remote sends must be built locally as an explicit `ExportPacket`.

Remote providers must not receive ad hoc prompt assembly from scattered call sites.

### 6.1 Required fields

```json
{
  "packet_id": "uuid",
  "workspace_id": "uuid",
  "created_at": "2026-03-07T12:00:00Z",
  "destination": {
    "provider_id": "anthropic",
    "model": "claude-sonnet",
    "trust_tier": "third_party_cloud"
  },
  "purpose": "compare_code_review",
  "export_mode": "redacted_remote",
  "sections": [],
  "excluded": [],
  "allowed_followup_intents": [],
  "constraints": {},
  "receipt_id": "uuid"
}
```

### 6.2 Section fields

Each exported section should carry:

- `section_id`
- `kind`
- `source`
- `sensitivity`
- `egress_policy`
- `transform`
- `artifact_handle`
- `content`

### 6.3 Supported section kinds

- `user_prompt`
- `conversation_summary`
- `attachment_excerpt`
- `workspace_summary`
- `memory_summary`
- `tool_output_summary`
- `web_results`

### 6.4 Required transforms

Supported initial transforms:

- `trimmed`
- `redacted`
- `summarized`
- `path_stripped`
- `truncated`
- `user_selected`

### 6.5 Packet rules

1. Remote packets must use artifact handles instead of absolute local paths.
2. Remote packets must declare what was excluded, not only what was included.
3. A packet must be reviewable before send for non-local destinations.
4. Every remote packet must generate a local receipt.
5. Compare fanout must use the same packet-building path as normal remote send.

---

## 7) Brokered intent model for remote usefulness

Remote models remain useful by requesting brokered follow-up intents, not by receiving raw local authority.

### 7.1 Allowed v1 intent types

- `request_attachment_excerpt`
- `request_workspace_summary`
- `request_web_results`
- `request_calendar_summary`
- `request_memory_summary`
- `propose_schedule`

### 7.2 Enforcement rules

1. The remote model requests an intent.
2. Local Fae evaluates the request against trust tier, data class, and workspace policy.
3. Local Fae either denies it or returns a sanitized result.
4. The sanitized result may itself become a new export section.

### 7.3 Explicit non-goals

Remote models must not directly call:

- `read`
- `write`
- `edit`
- `bash`
- `run_skill`
- `calendar`
- `mail`
- `notes`
- `scheduler_create`
- `scheduler_update`

---

## 8) UX contract

The current “possible secret detected” hold/send-anyway flow is not sufficient as the long-term UX.

It should be replaced by an `Export Review` surface for non-local sends.

### 8.1 Export Review must show

- destination provider and model
- trust tier
- why remote help is being used
- which data classes are included
- which high-sensitivity classes were excluded
- which transforms were applied
- whether follow-up intents are allowed

### 8.2 Export Review actions

- `Keep local`
- `Send redacted`
- `Send selected excerpts`
- `Send this turn only`
- `Always keep this workspace local`

### 8.3 UX rule

Warn less often, but be much more precise when a boundary is actually crossed.

---

## 9) Documentation contract

Documentation updates are a required part of implementation, not post-hoc cleanup.

### 9.1 Merge rule

Any PR that changes Cowork remote behavior, export behavior, review UX, sensitivity classification, or brokered remote capabilities must update the relevant docs in the same PR.

If the behavior changes and the docs are not updated, the PR is incomplete.

### 9.2 Canonical docs to keep in sync

- `docs/architecture/cowork-security-and-egress-plan-2026-03-07.md`
  - technical source of truth for trust tiers, data classes, export packets, and brokered intents
- `docs/guides/work-with-fae.md`
  - user-visible Cowork behavior and current-vs-planned status
- `docs/guides/security-index.md`
  - entry point to the security model
- `docs/guides/security-autonomy-boundary-and-execution-plan.md`
  - boundary between enforcement and workflow flexibility
- `docs/guides/security-confirmation-copy.md`
  - review and confirmation copy used in product
- `docs/checklists/security-pr-review-checklist.md`
  - review gate
- `docs/tests/adversarial-security-suite-plan.md`
  - attack and bypass coverage

### 9.3 Required doc status language

When a feature is not yet shipped, docs must explicitly say one of:

- `planned`
- `implemented baseline`
- `shipped`

Do not write future-state behavior as if it is already live.

---

## 10) Implementation phases

### Phase 1 — Export-path hardening

Runtime work:

- strip absolute paths from remote packets
- remove broad prior conversation from remote-default context
- route all remote send assembly through a single packet builder
- wire non-local model locality where relevant

Docs required in same PR:

- this plan
- `docs/guides/work-with-fae.md`
- `docs/checklists/security-pr-review-checklist.md`

### Phase 2 — Sensitivity and egress metadata

Runtime work:

- add `sensitivity` and `egress_policy` to messages, attachments, memory records, and eligible tool outputs
- replace secret-only remote blocking with policy-driven export review

Docs required in same PR:

- this plan
- `docs/guides/work-with-fae.md`
- `docs/guides/security-confirmation-copy.md`
- `docs/tests/adversarial-security-suite-plan.md`

### Phase 3 — Export review UX and receipts

Runtime work:

- replace blunt remote-block card with `Export Review`
- write local export receipts

Docs required in same PR:

- this plan
- `docs/guides/work-with-fae.md`
- `docs/guides/user-security-behavior-contract.md`
- `docs/guides/security-confirmation-copy.md`

### Phase 4 — Brokered remote intents

Runtime work:

- implement remote intent request/fulfillment flow
- keep raw local tools unavailable to remote providers

Docs required in same PR:

- this plan
- `docs/guides/work-with-fae.md`
- `docs/guides/security-autonomy-boundary-and-execution-plan.md`
- `docs/tests/adversarial-security-suite-plan.md`

### Phase 5 — Skill and execution hardening

Runtime work:

- move executable skills toward real sandboxing / stronger process isolation
- align skill data-class declarations with enforced policy

Docs required in same PR:

- this plan
- `docs/guides/security-autonomy-boundary-and-execution-plan.md`
- `docs/guides/security-contributor-guidelines.md`
- `docs/tests/adversarial-security-suite-plan.md`

---

## 11) Recommended first code slice

The first implementation PR should stay narrow:

1. introduce trust-tier and export-packet types
2. strip path leakage from remote sends
3. stop sending broad prior conversation remotely by default
4. ensure compare fanout uses the same packet builder
5. add regression tests for path leakage and history leakage

This first slice improves security immediately without blocking later classification work.

---

## 12) Code anchors

- `native/macos/Fae/Sources/Fae/Cowork/WorkWithFaeWorkspace.swift`
- `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceController.swift`
- `native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceView.swift`
- `native/macos/Fae/Sources/Fae/Cowork/CoworkLLMProvider.swift`
- `native/macos/Fae/Sources/Fae/Core/SensitiveContentPolicy.swift`
- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
- `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift`
- `native/macos/Fae/Sources/Fae/Skills/SkillManifest.swift`
- `native/macos/Fae/Sources/Fae/Skills/SkillManager.swift`
