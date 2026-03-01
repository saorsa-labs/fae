# Fae Security Autonomy: Code vs Skills Harness Boundary + Execution Plan

**Status:** Implemented baseline (v1 complete)  
**Audience:** Product, runtime, tools, skills, security reviewers  
**Last updated:** 2026-03-01

---

## 1) Findings from current research and code review

### 1.1 External research findings (IronCurtain + related work)

Validated from primary sources (`provos.org`, `ironcurtain.dev`, `github.com/provos/ironcurtain`, Anthropic and Cloudflare code-mode docs):

1. Treat the agent as **untrusted by default**.
2. Enforce policy **outside the model** with deterministic runtime logic.
3. Route all actions through a **single chokepoint**.
4. Use explicit decisions: **allow / deny / escalate**.
5. Prefer **default-deny** when no policy match exists.
6. Keep credentials out of untrusted execution contexts.
7. Maintain append-only **audit logs** for every decision.

### 1.2 Current Fae strengths (Swift runtime)

- Existing tool risk and approval flow (`ToolRiskPolicy`, `ApprovalManager`, `PipelineCoordinator`).
- Existing rate limiting (`ToolRateLimiter`).
- Existing write-path controls (`PathPolicy`).
- Existing voice identity controls (`VoiceIdentityPolicy`).
- Existing rescue mode forcing read-only behavior.
- Local-first storage and local model runtime.

### 1.3 Implemented security baseline (now in core runtime)

- Unified non-bypassable broker at `PipelineCoordinator.executeTool`.
- Capability-ticket enforcement for tool execution and `run_skill` launch path.
- Default-deny on unknown and known-but-unmodeled tools.
- Safe executors:
  - `SafeBashExecutor` (restricted env/cwd, denylist, timeout)
  - `SafeSkillExecutor` (restricted env, timeout, CPU/memory limits)
- Reversibility controls:
  - `ReversibilityEngine` checkpoints
  - `allow_with_transform` hooks for mutation flows
- Network controls expanded with `NetworkTargetPolicy` and skill input URL checks.
- Outbound exfiltration guardrails:
  - recipient novelty confirmation
  - payload sensitivity deny
- Relay hardening:
  - TOFU + local confirmation challenge
  - companion allowlist + revocation
  - same broker/capability checks as local path
- Skills trust hardening:
  - required executable `MANIFEST.json`
  - integrity checksums + tamper detection
- Observability hardening:
  - append-only security event log
  - redaction, rotation/retention, forensic mode
  - local analytics and security dashboard surfacing

---

## 2) Boundary Charter (immutable controls vs flexible workflows)

## 2.1 Core principle

Fae is split into two layers:

1. **Code Enforcement Plane (immutable safety spine)**
2. **Skills Workflow Plane (mutable utility brain)**

> Skills may request behavior. Core code grants, transforms, confirms, or denies.

## 2.2 What MUST be in core code (non-bypassable)

The following controls are **security invariants** and may not be implemented only in skills:

- Final action authorization (`allow`, `allow_with_transform`, `confirm`, `deny`)
- Default-deny on uncovered action shapes
- Identity checks and step-up logic
- Path canonicalization and protected-path enforcement
- Network target policy (localhost/RFC1918/link-local/metadata blocking by default)
- Credential redaction and secret handling boundaries
- Reversibility primitives for destructive actions (checkpoint/trash/rollback metadata)
- Safe execution wrappers for high-risk runtimes (`bash`, executable skills)
- Relay trust onboarding, allowlist, revocation
- Append-only security event logging + redaction + retention controls
- Capability ticket issue/validation/expiry

## 2.3 What MAY live in skills harness

Skills are for high-utility behavior that does not define hard safety boundaries:

- Domain workflows (e.g., “set up X integration”, “research + summarize + draft”)
- User-facing orchestration/decomposition
- Template automation and reusable playbooks
- Skill-level capability declarations/intent metadata
- Tool sequencing logic under granted capabilities

## 2.4 What MUST NEVER live in skills harness

- Global or final allow/deny enforcement
- Approval policy or escalation policy ownership
- Hard identity/voice privilege checks
- Hard path/network blocklists or self-protection controls
- Any bypass path around core broker or capability tickets

---

## 3) Placement Decision Rubric

Use this rubric for every new feature/tool path:

| Criterion | Question | If YES => belongs in |
|---|---|---|
| Safety-critical | Could failure cause data loss, exfiltration, or irreversible external impact? | Core code |
| Determinism required | Must behavior be predictable/replayable independent of model output? | Core code |
| Bypass impact | Would bypassing this logic materially weaken security? | Core code |
| Latency-sensitive utility | Is this mostly workflow convenience where occasional failure is tolerable? | Skills |
| User variability | Is this highly user-specific domain behavior/preferences? | Skills |
| Audit necessity | Must this decision be provable in logs with reason codes? | Core code |

**Tie-breaker rule:** if uncertain, place in core code first.

---

## 4) Ownership Matrix (current tool surface)

| Tool / action path | Skills own workflow? | Core owns enforcement? | Notes |
|---|---:|---:|---|
| `read` | Optional | ✅ | Low-risk but still rate/audit in core |
| `write` | Optional | ✅ | Path policy + reversibility + broker decision |
| `edit` | Optional | ✅ | Path policy + checkpoint/rollback wrappers |
| `bash` | Optional | ✅ | Safe executor required in core |
| `self_config` | Optional | ✅ | Self-protection + anti-jailbreak remains core |
| `web_search` | Optional | ✅ | Broker + egress policy + telemetry in core |
| `fetch_url` | Optional | ✅ | Core network target guard (metadata/local/internal) |
| `activate_skill` | ✅ | ✅ | Skills body loading is skill concern; trust boundaries are core |
| `run_skill` | ✅ | ✅ | Skill workflow + manifest in skills; execution safety in core |
| `manage_skill` | ✅ | ✅ | Skill lifecycle UX in skills; install validation + policy in core |
| Apple tools (`calendar`, `reminders`, `contacts`, `mail`, `notes`) | Optional | ✅ | Permissions + outbound guardrails + broker in core |
| Scheduler tools | Optional | ✅ | Trigger/update semantics + safety controls in core |
| Relay commands/audio injection | No | ✅ | Must follow same broker/capability policy as local inputs |

---

## 5) Non-bypassable invariants (MUST hold at runtime)

1. Every tool invocation passes through a single broker chokepoint.
2. If no explicit allow/transform/confirm rule matches, decision is deny.
3. Protected paths and policy/config integrity paths are never mutable by tools/skills.
4. Network targets to localhost, RFC1918, link-local, metadata are blocked unless explicitly granted by capability ticket.
5. Executable skills cannot run without valid manifest + broker grant.
6. Relay-originated commands are policy-equivalent to local commands (no weaker path).
7. All security decisions produce an append-only event with reason code.
8. Log/telemetry redact secrets before persistence.

---

## 6) Core data model design

## 6.1 `ActionIntent` schema (core)

Proposed canonical action envelope passed to broker:

```swift
struct ActionIntent: Sendable {
    let requestId: String
    let source: ActionSource            // voice | text | scheduler | relay | skill
    let toolName: String
    let arguments: [String: AnySendable]

    // Derived target metadata
    let targetPaths: [String]
    let targetHosts: [String]
    let recipientIds: [String]

    // Risk attributes
    let reversibility: Reversibility    // reversible | partially_reversible | irreversible
    let externality: Externality        // local_only | outbound_data | outbound_action
    let blastRadius: BlastRadius        // single_object | bounded_set | broad

    // Intent quality
    let intentConfidence: Double        // 0.0 ... 1.0
    let explicitUserAuthorization: Bool

    // Identity and capability context
    let actorIdentity: ActorIdentityContext
    let capabilityTicket: CapabilityTicket?
    let policyProfile: PolicyProfile
}
```

## 6.2 `TrustedActionBroker` interface (core)

```swift
enum BrokerDecision: Sendable {
    case allow(reason: DecisionReason)
    case allowWithTransform(transform: SafetyTransform, reason: DecisionReason)
    case confirm(prompt: ConfirmationPrompt, reason: DecisionReason)
    case deny(reason: DecisionReason)
}

protocol TrustedActionBroker: Sendable {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision
}
```

`DecisionReason` is a stable reason-code enum for audit/replay.

---

## 7) Policy profiles (product defaults)

Profiles are implemented in core policy tables (not skill logic):

- **Balanced (default):** silent for safe actions, confirm only high-impact ambiguity.
- **More autonomous:** broader allow_with_transform, fewer confirms, same hard blocks.
- **More cautious:** narrower allow sets, confirms earlier, same hard blocks.

Hard-block invariants remain constant across all profiles.

---

## 8) UX contract for non-technical users

- Safety is mostly invisible.
- Confirmations are short and plain-language.
- Destructive actions are reversible by default where possible.
- No security jargon in conversational prompts.

Example prompt style:
- “I’m about to send this to a new recipient at `example.com`. Send now?”

---

## 9) Full execution plan (all steps)

This execution plan maps to tilldone tasks #1-#60.

## Wave 0 — Architecture contract and scope

1. Boundary charter (this document)
2. Placement rubric
3. Ownership matrix across tools/paths
4. Non-bypassable invariants
5. Skills-allowed scope
6. Skills-forbidden scope
7. ActionIntent schema
8. Broker interface

## Wave 1 — Core policy kernel implementation

9. Broker hook at `PipelineCoordinator.executeTool` chokepoint
10. Centralize existing ToolRiskPolicy through broker
11. Feed VoiceIdentityPolicy into broker signals
12. Add capability tickets (task-scoped)
13. Enforce default-deny on uncovered actions
14. Add profile presets (Balanced/Autonomous/Cautious)
15. Add confirm classifier (high-impact ambiguity only)
16. Add plain-language confirmation templates
17. Add allow_with_transform wrappers
18. Add reversibility primitives
19. Strengthen hard path controls
20. Expand network egress guard

## Wave 2 — High-risk runtime containment + telemetry

21. Safe Bash Executor
22. Safe Skill Executor
23. Enforce broker before skill launch paths
24. Outbound exfiltration guardrails
25. Risk-tier-aware rate limiting
26. Wire ToolAnalytics at startup
27. Add append-only security event log
28. Add redaction pipeline
29. Add secure retention + forensic mode
30. Harden relay pairing flow
31. Add companion allowlist/revoke
32. Route relay commands through same broker/capabilities

## Wave 3 — Skills harness trust model

33. Define skill manifest schema
34. Parse/validate manifests
35. Require manifests for executable skills
36. Enforce per-skill allowlists in core
37. Add skill install provenance/lint checks
38. Add built-in skill integrity checks
39. Split trust levels: instruction vs executable
40. Add skill runtime context sanitization

## Wave 4 — Security test harness + rollout controls

41. Adversarial prompt-injection/test suite
42. Broker unit tests by risk/profile
43. Transform/reversibility integration tests
44. Regression tests for non-bypass guarantees
45. Property/fuzz tests for path/network edge cases
46. Policy replay harness from historical traces
47. Shadow mode (would-block/would-confirm)
48. Dogfood threshold tuning via shadow mode
49. Launch SLOs (friction/safety/latency)
50. Runtime metrics dashboard

## Wave 5 — Migration and release operations

51. Skill migration plan to manifests
52. Automated migrator for legacy skills
53. User-facing behavior contract copy
54. Confirmation/denial UX copy set
55. One-tap profile selector
56. Hide advanced controls under expert mode
57. Contributor boundary guidelines
58. Security review checklist for tools/skills PRs
59. Staged rollout plan with kill switches
60. Post-release weekly telemetry/replay/red-team iteration

---

## 9.1) Implementation map (current)

Core enforcement paths:

- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
- `native/macos/Fae/Sources/Fae/Tools/TrustedActionBroker.swift`
- `native/macos/Fae/Sources/Fae/Tools/CapabilityTicket.swift`
- `native/macos/Fae/Sources/Fae/Tools/ReversibilityEngine.swift`
- `native/macos/Fae/Sources/Fae/Tools/SafeBashExecutor.swift`
- `native/macos/Fae/Sources/Fae/Tools/SafeSkillExecutor.swift`
- `native/macos/Fae/Sources/Fae/Tools/NetworkTargetPolicy.swift`
- `native/macos/Fae/Sources/Fae/Tools/OutboundExfiltrationGuard.swift`

Skills trust/enforcement:

- `native/macos/Fae/Sources/Fae/Skills/SkillManifest.swift`
- `native/macos/Fae/Sources/Fae/Skills/SkillMigrator.swift`
- `native/macos/Fae/Sources/Fae/Skills/SkillManager.swift`

Observability:

- `native/macos/Fae/Sources/Fae/Tools/SecurityEventLogger.swift`
- `native/macos/Fae/Sources/Fae/Tools/SensitiveDataRedactor.swift`
- `native/macos/Fae/Sources/Fae/Tools/ToolAnalytics.swift`
- `native/macos/Fae/Sources/Fae/SettingsDeveloperTab.swift`

Test coverage highlights:

- `native/macos/Fae/Tests/HandoffTests/TrustedActionBrokerTests.swift`
- `native/macos/Fae/Tests/HandoffTests/SkillBypassRegressionTests.swift`
- `native/macos/Fae/Tests/IntegrationTests/EndToEndAllowWithTransformTests.swift`

---

## 10) Acceptance criteria (release gate)

A release may enable default autonomous behavior only when:

1. 100% of tool/relay execution paths pass through broker.
2. Hard-block invariants are covered by regression tests.
3. Shadow mode false-positive rate is below agreed SLO.
4. Reversibility flows pass integration tests for destructive operations.
5. Security event logging and redaction are enabled by default.

---

## 11) Governance model

- Product owns profile defaults and UX copy.
- Runtime/security owns broker, invariants, and enforcement.
- Skills team owns workflow capabilities + manifests under core constraints.
- Any PR touching tool execution, relay routing, or skill execution must pass security checklist and policy replay tests.

---

## 12) Contributor checklist (short form)

Before merging any new tool or skill-execution feature:

1. Does it pass through broker chokepoint?
2. Are path/network/identity invariants preserved?
3. Is there a reason-code and audit event for each decision?
4. Is reversibility applied where destructive?
5. Are tests added for bypass attempts and edge cases?

If any answer is “no”, block merge.
