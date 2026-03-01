# Shadow Mode Dogfood Runbook

## Objective

Use shadow mode to measure would-block/would-confirm rates without enforcing them, then tune policy thresholds before broader rollout.

## Enablement

Set local flag:
- `UserDefaults key: fae.security.shadowMode = true`

Behavior:
- broker decisions are logged
- confirm/deny paths are bypassed for execution
- `shadow_decision` events are written to security log

## Dogfood window

Recommended minimum:
- 5 internal users
- 7 days
- mixed workflows (coding, scheduler use, skills, web fetch)

## Metrics to collect

- `broker_decision` counts by reason code
- `shadow_decision` counts by tool
- false-positive estimate from manual review samples
- high-risk decision distribution

## Tuning loop

1. Export security-events JSONL
2. Aggregate by reason code and tool
3. Identify noisy confirms (high volume, low risk)
4. Tighten/relax classifier thresholds
5. Re-run shadow window

## Exit criteria

- low false-positive confirmation pressure in Balanced profile
- no concerning deny bypass categories in sampled review
- launch SLO targets remain healthy

## Safety note

Shadow mode is for controlled internal testing only. Do not enable by default for production users.
