# Fae Security Contributor Guidelines

Status: Active draft  
Scope: Core runtime, tools, skills harness, relay paths

## Purpose

These guidelines keep Fae highly autonomous for non-technical users while ensuring hard safety boundaries remain non-bypassable.

## 1. Code vs Skills boundary

### Must be implemented in core code

- Final authorization decision (`allow / allow_with_transform / confirm / deny`)
- Default-deny behavior for uncovered actions
- Identity and step-up checks
- Path/network hard-block invariants
- Capability ticket issuance and validation
- Relay pairing and command trust policy
- Security logging, redaction, and retention controls

### May be implemented in skills harness

- Domain workflows and orchestration templates
- User-specific task decomposition
- Reusable automation playbooks
- Skill metadata and capability requests
- User-facing setup/configuration flows (**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.)

### Must never be skills-only

- Approval policy ownership
- Hard allow/deny enforcement
- Hard identity enforcement
- Path/network hard-block logic
- Any bypass around broker/capability checks

## 2. Non-bypassable invariants

1. Every executable action path passes through broker evaluation.
2. Unknown or uncovered action shapes are denied.
3. Capability ticket is required for executable actions (including `run_skill`).
4. Protected system/policy paths are never mutable by tool execution.
5. Local/private/metadata network targets are blocked by default.
6. Outbound send-like actions apply recipient-novelty + payload-risk checks.
7. Executable skills require valid manifest declarations + integrity checksums.
8. Relay commands cannot bypass local safety policy.
9. Security decisions are written to append-only local log records.
10. Sensitive data is redacted before persistence.
11. Tool-backed answers must be grounded in actual tool results (no fabricated fallback content).
12. Deferred/background tool execution must not bypass approval, identity, or broker checks.

## 3. Threat model assumptions

- LLM output is untrusted and may be adversarially influenced.
- Prompt injection and multi-turn drift are expected, not edge cases.
- Local-first reduces cloud leakage risk but does not remove local abuse risk.
- Safety must survive model upgrades and prompt changes.
- Security controls must remain effective even when users never touch advanced settings.

## 4. PR review checklist (required)

For any PR touching tools, skills, relay, scheduler actions, or config:

- [ ] Does the path pass through `TrustedActionBroker`?
- [ ] Is there a clear reason code for allow/confirm/deny outcomes?
- [ ] Are path and network invariants still enforced?
- [ ] Are capability tickets enforced for action execution?
- [ ] Are secrets redacted from logs/analytics?
- [ ] Are tests added for bypass attempts and edge cases?
- [ ] Is user-facing confirmation copy plain-language and non-technical?
- [ ] For new configurable workflows, did we apply the canonical preference: Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing?

If any answer is “no”, block merge.

## 5. Key implementation anchors (must review when changing security behavior)

- Broker/chokepoint: `PipelineCoordinator.swift`, `TrustedActionBroker.swift`
- Capability: `CapabilityTicket.swift`
- Reversibility: `ReversibilityEngine.swift`
- Safe execution: `SafeBashExecutor.swift`, `SafeSkillExecutor.swift`
- Network/outbound guardrails: `NetworkTargetPolicy.swift`, `OutboundExfiltrationGuard.swift`
- Skills trust: `SkillManifest.swift`, `SkillManager.swift`, `SkillMigrator.swift`
- Logging/analytics: `SecurityEventLogger.swift`, `SensitiveDataRedactor.swift`, `ToolAnalytics.swift`

## 6. Rollout safety rules

- Ship broker-affecting changes behind staged rollout when possible.
- Run replay/shadow validation before broad enablement.
- Preserve kill-switches for high-risk features (relay/skills execution profiles).
- Prefer reversible defaults for destructive operations.
