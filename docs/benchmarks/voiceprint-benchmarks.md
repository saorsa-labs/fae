# Voiceprint Benchmarks and Eval Plan

Date: 2026-02-23
Status: Active plan (with initial automated tests in-tree)

## Scope

This benchmark/eval suite validates voice identity behavior for:

- ambient-media rejection (TV/radio/YouTube spill)
- primary-speaker acceptance
- approval spoof resistance during privileged tool approvals
- latency impact of identity gating

## Runtime config under test

```toml
[voice_identity]
enabled = true
mode = "assist"               # also test "enforce"
threshold_accept = 0.82
threshold_hold = 0.76
hold_window_s = 12
min_enroll_samples = 3
approval_requires_match = true
store_raw_samples = false
```

## Eval matrix

| Category | Dataset | Expected |
|---|---|---|
| Primary clean speech | user mic clips | pass |
| Primary noisy speech | user + room noise | pass |
| Non-primary household speech | other speakers | block in `enforce`; direct-address fallback only in `assist` |
| Ambient media | TV/radio/YouTube audio | block |
| Approval spoof | non-primary saying yes/no during approval window | block |
| Missing voiceprint vector | clipped/invalid segment | block when enrolled + enforce, fallback only per mode |

## Metrics

- FAR (false accept rate): non-primary accepted / non-primary attempts
- FRR (false reject rate): primary rejected / primary attempts
- Approval spoof accept rate
- p95 identity gate stage cost (ms)

## Acceptance targets

- FAR (ambient + non-primary): `< 1%`
- FRR (primary): `< 5%`
- Approval spoof accept rate: `< 1%`
- Identity gate overhead p95: `< 5ms` added per transcription

## Benchmark procedure

1. Enroll primary voice with 3-5 clips.
2. Run eval batches in `assist` and `enforce`.
3. Capture runtime events:
   - `voice_identity.decision`
   - `onboarding.voiceprint.progress`
   - `pipeline.timing`
4. Aggregate FAR/FRR and latency deltas.

## In-repo automated coverage

- `identity_gate_enforce_drops_mismatch_and_accepts_match`
- `identity_gate_assist_allows_direct_address_fallback`
- `identity_gate_collects_enrollment_samples_and_finalizes`
- `approval_speaker_verification_rejects_mismatch`
- `voiceprint_start_finalize_and_reset_lifecycle`

These are guardrail tests, not a full acoustic benchmark corpus.
