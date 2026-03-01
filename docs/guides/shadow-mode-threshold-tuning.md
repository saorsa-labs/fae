# Shadow Mode Threshold Tuning Notes

## Baseline tuning targets (Balanced profile)

After internal dogfood shadow runs, tune for:

- confirm rate <= 12 per 100 tasks
- `run_skill` ambiguous medium-risk confirms retained
- low-risk actions should almost never produce confirms

## Reason-code tuning guidance

If `mediumRiskRequiresConfirmation` dominates:
- narrow medium-risk confirms to high-impact tools only
- require ambiguity signal before confirming

If `ownerRequired` spikes unexpectedly:
- audit voice identity calibration and liveness thresholds
- ensure false negatives are not forcing unnecessary denial

If `noCapabilityTicket` appears frequently:
- verify ticket issuance timing in turn lifecycle
- ensure ticket expiry window covers normal multi-tool turns

## Review checklist per tuning iteration

1. Compare reason-code histogram before/after changes.
2. Verify no increase in unsafe-action escape signal.
3. Validate confirmation copy remains short and concrete.
4. Keep hard-block invariants unchanged.

## Promotion rule

Promote profile tuning only after two consecutive internal runs with:
- stable confirm rate within target
- no critical safety regression
