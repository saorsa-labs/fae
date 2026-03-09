# Security PR Review Checklist (Tools & Skills)

Use this checklist for any PR that adds or changes:
- tools (`read/write/edit/bash/fetch/skills/scheduler/apple tools`)
- relay command routing
- skill execution pipeline
- policy/broker/approval logic

## A. Chokepoint and policy

- [ ] Action executes through `PipelineCoordinator.executeTool` (or equivalent brokered chokepoint)
- [ ] `TrustedActionBroker` decision is enforced before side effects
- [ ] Unknown/uncovered action is denied by default
- [ ] Decision reason code is present and stable

## B. Scope and capabilities

- [ ] Capability ticket is required and validated
- [ ] Tool mode/profile mapping is respected
- [ ] No alternate path bypasses capability or broker checks
- [ ] `run_skill` execution path enforces ticket requirement end-to-end

## C. Path and filesystem safety

- [ ] Canonicalized path handling is used
- [ ] Symlink/path traversal escape is blocked
- [ ] Protected paths cannot be modified
- [ ] Destructive edits have reversibility strategy or explicit rationale

## D. Network and outbound safety

- [ ] Local/private/metadata targets are blocked by default
- [ ] Domain allowlist logic is applied where declared
- [ ] Outbound actions use plain-language confirmation when needed
- [ ] Outbound novelty/payload risk guardrails are preserved for send-like actions

## E. Skills security

- [ ] Executable skills require valid `MANIFEST.json`
- [ ] Manifest schema/version validated
- [ ] Per-skill constraints enforced by core code (not skill self-enforcement)
- [ ] Skill input payload sanitizes obvious secrets
- [ ] Manifest integrity checksums/tamper verification are enforced

## F. Relay security

- [ ] Pairing uses trust policy (no blind auto-accept)
- [ ] Unknown relay commands are denied by default
- [ ] Relay-originated actions follow same broker/capability policy

## G. Telemetry and logs

- [ ] Security event is logged with ID, timestamp, reason code
- [ ] Logs are append-only and rotated per policy
- [ ] Redaction applied to sensitive fields before persistence
- [ ] Local security dashboard metrics stay consistent with emitted events

## H. Test coverage

- [ ] Unit tests for policy decisions added/updated
- [ ] Integration tests for execution path added/updated
- [ ] Regression test for bypass attempt included
- [ ] Build/tests pass in CI-local run

## I. Documentation and anti-drift

- [ ] Canonical architecture/security doc updated in the same PR
- [ ] User-visible behavior docs updated in the same PR when product behavior changed
- [ ] Confirmation/review copy docs updated when approval or export-review text changed
- [ ] Adversarial/security test plan docs updated when a new boundary or bypass surface was added
- [ ] [app-release-validation.md](/Users/davidirvine/Desktop/Devel/projects/fae/docs/checklists/app-release-validation.md) updated when a new live-flow, popup, model path, or remote boundary was added
- [ ] Docs clearly distinguish `planned`, `implemented baseline`, and `shipped` states

## Reviewer decision

- [ ] Approve
- [ ] Request changes
- [ ] Block (critical invariant violated)
