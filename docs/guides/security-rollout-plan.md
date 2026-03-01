# Security Rollout Plan (Canary -> Beta -> GA)

## Phase 0: Internal canary (team devices)

Duration: 1-2 weeks

Enable:
- broker enforcement
- capability tickets
- relay trust-on-first-use confirmation
- security event logging

Success checks:
- no unsafe-action escapes
- acceptable confirmation rate in Balanced mode
- no critical regressions in common tool workflows

Kill switches:
- disable relay pairing hardening
- fall back to legacy confirmation-only path

## Phase 1: Small beta cohort

Duration: 2-3 weeks

Cohort:
- privacy-focused users
- mixed technical and non-technical users

Enable:
- executable skill manifest enforcement
- domain allowlist checks
- secret sanitization in skill inputs

Observe:
- interruption rate
- denial reasons distribution
- user-reported friction

Rollback triggers:
- non-zero unsafe-action escape event
- severe regression in core workflows

## Phase 2: Broad release (GA)

Enable defaults:
- Autonomy style selector (Balanced default)
- advanced controls hidden under expert section
- append-only security logging + rotation

Release criteria:
- launch SLOs met for 7 consecutive days in beta
- no critical redaction failures
- support docs and contributor checklist published

## Operational controls

- Keep feature flags for:
  - capability ticket strictness
  - relay command deny-default mode
  - skill manifest strict mode

- Document emergency rollback playbook:
  - revert to previous app build
  - disable strict policy toggles
  - preserve logs for forensic review
