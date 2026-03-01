# Post-release Security Iteration Loop

## Weekly cadence

1. **Telemetry review**
   - interruption rate
   - broker deny/confirm distribution
   - relay denial events
   - skill manifest rejection counts

2. **Replay validation**
   - run recent action traces against latest policy build
   - compare would-allow/would-deny drift
   - flag regressions before shipping policy changes

3. **Red-team focus set**
   - prompt injection samples
   - local/private network targeting attempts
   - skill bypass attempts
   - relay ingress abuse paths

4. **Policy tuning**
   - reduce high-noise confirms in Balanced profile
   - preserve hard-block invariants unchanged
   - update plain-language confirmation copy as needed

5. **Release decision**
   - ship policy adjustments if SLOs remain healthy
   - hold changes if unsafe-action signal increases

## Monthly hardening

- expand adversarial corpus with real-world failures
- review sensitive-data redaction effectiveness
- audit new tools/features against contributor checklist

## Incident response trigger

Immediate cross-functional review when any of:
- unsafe-action escape > 0
- critical secret leak in persisted logs
- confirmed relay bypass of policy controls

## Feedback loop ownership

- Runtime/security: policy correctness and invariants
- Product/UX: confirmation quality and friction reduction
- Skills team: manifest hygiene and migration quality
