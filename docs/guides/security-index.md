# Fae Security Index

This index is the entry point for Fae's security architecture, policy, rollout, and validation docs.

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

## Start here

- [Cowork Security and Remote Egress Plan](../architecture/cowork-security-and-egress-plan-2026-03-07.md)  
  Canonical Cowork trust model: local authority, remote export packets, brokered intents, and documentation gates.

- [Security Autonomy Boundary + Execution Plan](security-autonomy-boundary-and-execution-plan.md)  
  Canonical architecture boundary: what is enforced in core code vs what belongs in skills.

- [Security Launch SLOs](security-autonomy-launch-slos.md)  
  Quantitative release targets for safety, friction, and latency.

## Runtime policy and contributor guardrails

- [**Damage Control Policy**](damage-control.md)
  Layer-zero pre-broker safety net: three-tier block/disaster/confirm-manual model, dual trust model for local vs. non-local co-work, physical-click-only approval for catastrophic operations.

- [Security Contributor Guidelines](security-contributor-guidelines.md)
  Non-bypassable invariants and engineering guardrails.

- [Security PR Review Checklist](../checklists/security-pr-review-checklist.md)  
  Required review gates for tool/skill/relay changes.

- [Security Confirmation Copy](security-confirmation-copy.md)  
  Plain-language prompts for confirms/denies.

- [Deferred Tool Execution](deferred-tool-execution.md)  
  Non-blocking read-only tool jobs and their safety constraints.

- [User Security Behavior Contract](user-security-behavior-contract.md)  
  User-facing safety expectations and product behavior contract.

## Skills trust and migration

- [Skills Manifest Migration Plan](skills-manifest-migration-plan.md)  
  Migration and enforcement strategy for executable skill manifests.

- [Channels Setup Guide](channels-setup.md)  
  Skill-first conversational channel onboarding and guided forms.

- [Self-Modification Guide](self-modification.md)  
  How users ask Fae to change behavior/settings with skills-first preferences.

## Testing and adversarial validation

- [Adversarial Security Suite Plan](../tests/adversarial-security-suite-plan.md)  
  Prompt-injection, misuse, relay, and bypass test strategy.

## Rollout and ongoing operations

- [Security Rollout Plan](security-rollout-plan.md)  
  Canary/beta/full release rollout controls.

- [Shadow Mode Dogfood Runbook](shadow-mode-dogfood-runbook.md)  
  Operational runbook for non-enforcing safety telemetry.

- [Shadow Mode Threshold Tuning](shadow-mode-threshold-tuning.md)  
  Tuning guidance for confirm/deny thresholds.

- [Security Post-Release Iteration Loop](security-postrelease-iteration-loop.md)  
  Weekly telemetry/replay/red-team feedback loop.

## Related implementation files (code anchors)

- `native/macos/Fae/Sources/Fae/Tools/DamageControlPolicy.swift`
- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
- `native/macos/Fae/Sources/Fae/Tools/TrustedActionBroker.swift`
- `native/macos/Fae/Sources/Fae/Tools/CapabilityTicket.swift`
- `native/macos/Fae/Sources/Fae/Tools/ReversibilityEngine.swift`
- `native/macos/Fae/Sources/Fae/Tools/SafeBashExecutor.swift`
- `native/macos/Fae/Sources/Fae/Tools/SafeSkillExecutor.swift`
- `native/macos/Fae/Sources/Fae/Tools/NetworkTargetPolicy.swift`
- `native/macos/Fae/Sources/Fae/Tools/OutboundExfiltrationGuard.swift`
- `native/macos/Fae/Sources/Fae/Skills/SkillManifest.swift`
- `native/macos/Fae/Sources/Fae/Skills/SkillManager.swift`
- `native/macos/Fae/Sources/Fae/Tools/SecurityEventLogger.swift`
- `native/macos/Fae/Sources/Fae/Tools/SensitiveDataRedactor.swift`
- `native/macos/Fae/Sources/Fae/Tools/ToolAnalytics.swift`

---

If you are making a security-sensitive code change, read in this order:
1) Cowork remote egress plan (for Cowork/export changes)  
2) Boundary + execution plan  
3) Contributor guidelines  
4) PR checklist  
5) Adversarial test plan
