# Voice Identity Rollout Plan (Phase 7)

Date: 2026-02-23

## Rollout stages

1. Stage 0: Land code + tests behind config flag
- `voice_identity.enabled = false` by default.
- No behavioral change for existing users.

2. Stage 1: Onboarding-driven enrollment
- New onboarding commands:
  - `onboarding.voiceprint.get_state`
  - `onboarding.voiceprint.start_enrollment`
  - `onboarding.voiceprint.finalize`
  - `onboarding.voiceprint.reset`
- Identity gate captures enrollment samples from direct-address utterances.

3. Stage 2: Assist mode default for enrolled users
- Enable `voice_identity.enabled = true` for newly enrolled profiles.
- Use `mode = "assist"` so direct-address fallback remains available.

4. Stage 3: Enforce mode optional profile
- Offer `mode = "enforce"` as opt-in for security-sensitive workflows.
- Keep button-based approval path available.

## Safety guardrails

- Approval speaker hardening only applies when:
  - `voice_identity.enabled = true`
  - `approval_requires_match = true`
  - enrolled centroid exists
- If no enrolled voice exists, approval flow remains unchanged.
- `onboarding.voiceprint.reset` must be reversible and immediate.

## Monitoring

- Runtime events:
  - `voice_identity.decision`
  - `onboarding.voiceprint.progress`
  - `approval.resolved` (with `speaker_verified` where applicable)
- Track:
  - mismatch drops
  - direct-address fallback rate
  - approval mismatch rate
  - latency deltas

## Rollback

- Set `[voice_identity].enabled = false` in config.
- Optional cleanup: run `onboarding.voiceprint.reset` to remove stored voiceprint vectors/centroid.
