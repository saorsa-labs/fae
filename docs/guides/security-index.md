# Fae Security Index

This index is the entry point for Fae's security architecture, policy, rollout, and validation docs.

## Start here

- [Security Autonomy Boundary + Execution Plan](security-autonomy-boundary-and-execution-plan.md)  
  Canonical architecture boundary: what is enforced in core code vs what belongs in skills.

- [Security Launch SLOs](security-autonomy-launch-slos.md)  
  Quantitative release targets for safety, friction, and latency.

## Runtime policy and contributor guardrails

- [Security Contributor Guidelines](security-contributor-guidelines.md)  
  Non-bypassable invariants and engineering guardrails.

- [Security PR Review Checklist](../checklists/security-pr-review-checklist.md)  
  Required review gates for tool/skill/relay changes.

- [Security Confirmation Copy](security-confirmation-copy.md)  
  Plain-language prompts for confirms/denies.

- [User Security Behavior Contract](user-security-behavior-contract.md)  
  User-facing safety expectations and product behavior contract.

## Skills trust and migration

- [Skills Manifest Migration Plan](skills-manifest-migration-plan.md)  
  Migration and enforcement strategy for executable skill manifests.

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
1) Boundary + execution plan  
2) Contributor guidelines  
3) PR checklist  
4) Adversarial test plan
