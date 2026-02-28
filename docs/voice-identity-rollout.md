# Voice Identity Rollout Status

Date: 2026-02-27

Voice identity is now integrated in the Swift runtime.

## Current config surface

Voice identity settings are served through `config.patch` / `config.get` using:

- `voice_identity.enabled`
- `voice_identity.mode` (`assist` | `enforce`)
- `voice_identity.approval_requires_match`

Persisted config is mapped to:

- `[voiceIdentity]` in `config.toml`
- speaker gating fields under `[speaker]` where applicable

## Runtime behavior

- Speaker embeddings are produced by `CoreMLSpeakerEncoder`
- Matching/enrollment is managed by `SpeakerProfileStore`
- Tool access checks pass through `VoiceIdentityPolicy`

## Rollback

Disable via settings or config patch:

- `voice_identity.enabled = false`

Optional reset:

- remove `~/Library/Application Support/fae/speakers.json`
