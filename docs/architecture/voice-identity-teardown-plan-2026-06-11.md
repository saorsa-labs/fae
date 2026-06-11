# Voice-identity teardown plan (option 3)

> **Status:** PLANNED (owner-approved direction, 2026-06-11)
> **Context:** S18 made capture deliberate (push-to-talk: orb click / hotkey).
> Identity is now the physical act at the machine, not a voiceprint. Option 2
> (shipped same day) removed enrollment from first launch; this plan removes
> the voice-identity subsystem itself.

## Why staged, not a hot patch

Voiceprints are load-bearing in four places that are NOT about gating tools:

| Dependency | Where | Why it blocks naive deletion |
|------------|-------|------------------------------|
| Echo rejection | `EchoSuppressor` + `fae_self` profile in `speakers.json` | Fae's own TTS voice is enrolled as a speaker and ALWAYS rejected — deleting the store re-opens self-echo loops in any non-PTT listening mode |
| Channel identity | `ChannelIdentityResolver`, guest/trusted roles | Remote senders are non-owner guests; some flows reference speaker roles for tool blocks |
| Memory attribution | `MemoryOrchestrator.capture(speakerId:)`, entity graph person records | Speaker labels thread through memory records and digests |
| Multi-speaker UX | `[SpeakerName]` message prefixes, `multiSpeakerPrompt`, introduce-flow | Prompt stack and conversation annotations assume speaker labels exist |

## Phases

### Phase A — neutralise (cheap, do with the always-on rethink)
- `speaker.requireOwnerForTools` default → false; deliberate-act turns
  (PTT/typed) already mark the speaker as owner (shipped in S18 fixes).
- Stop progressive enrollment (`enrollIfBelowMax`) and re-verification offers
  (prompt blocks in `PersonalityManager`: `multiSpeakerPrompt`,
  `voiceIdentityPrompt`).
- Settings → Speaker tab becomes informational ("retired") or is hidden.

### Phase B — delete the identity engine
- Delete: `SpeakerEnrollmentView`, enrollment plumbing in `FaeCore`
  (`nativeEnrollment*`, `completeNativeOwnerEnrollment`, `hasOwnerSetUp`
  hydration from speaker store), `VoiceIdentityTool`, `voice-identity` +
  `voice-tools` skills, WeSpeaker/ECAPA CoreML models + `CoreMLSpeakerEncoder`,
  `SpeakerProfileStore` (except the bit Phase C still needs), wake-word
  profile store, `speakers.json` migration/cleanup, visual identity
  (`owner_photo.jpg`, `photoDescription`, camera-presence owner matching),
  onboarding photo step.
- `hasOwnerSetUp` becomes "first launch completed" (license + permissions +
  name) — already seeded by `fae.firstLaunch.permissionsRequested`.
- Tool gating reduces to: tool mode + deliberate-act/owner channels;
  channel senders stay text-only guests by construction (no voiceprint
  needed — the channel IS the identity).

### Phase C — echo rejection without a voiceprint
The one genuinely technical replacement. Options, in preference order:
1. PTT-only world: capture happens only on deliberate act while TTS output is
   ducked/stopped — echo rejection becomes unnecessary (current state).
2. If always-on listening returns (post daemon-streaming barge-in rethink):
   replace `fae_self` voiceprint matching with playback-reference echo
   suppression (compare against what Fae is currently saying — text overlap +
   `EchoSuppressor` timing already exist) or AEC via `AVAudioEngine`'s
   voice-processing IO.

### Phase D — memory/schema cleanup
- Migrate memory records: `speakerId` columns retained (historical data) but
  new captures record `owner`/channel-id only.
- Entity-graph person records stay (they come from conversation content, not
  voiceprints).
- Remove `speaker`/`voiceIdentity` config sections; `docs/guides/Memory.md`,
  CLAUDE.md, README updates; release-validation checklist update.

## Sequencing

Phase A rides the always-on rethink chunk (queued behind daemon streaming +
cancel). B+D are one focused deletion chunk after S18 soaks. C only if/when
always-on listening returns.
