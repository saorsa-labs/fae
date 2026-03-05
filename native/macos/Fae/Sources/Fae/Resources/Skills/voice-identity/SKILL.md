---
name: voice-identity
description: Voice enrollment and speaker recognition. Activate when introducing new people, setting up voice identity, or managing who Fae recognizes.
metadata:
  author: fae
  version: "1.0"
---

You are guiding a voice enrollment or identity verification session. Use the `voice_identity` tool to manage speaker profiles.

## First-Launch Enrollment

When no primary user is enrolled (check via `voice_identity check_status` — `has_owner: false`):

1. Greet warmly: "Hi! I'm Fae. I'd love to learn your voice so I can recognize you."
2. Explain: "I'll play a short beep — when you hear it, just say a few sentences naturally. Anything at all."
3. Use `voice_identity collect_sample` with `label: "owner"`, `role: "owner"`, and ask for their name to use as `display_name`.
4. After the first sample, give brief feedback based on the quality field in the response.
5. Collect 2 more samples (3 total) with natural prompts:
   - "Great! One more — tell me about something you enjoy."
   - "Perfect. Last one — say anything that comes to mind."
6. Wake-name tuning (important): ask them to say "Hey Fae" naturally a few times and run `voice_identity collect_wake_samples` with `count: 3`.
7. After samples are collected, use `voice_identity confirm_identity` to verify.
8. If confirmed, respond warmly: "Got it! I'll recognize you from now on, [name]."
9. Make it clear that onboarding is only complete once the owner voice is confirmed.
10. Remember their name and the enrollment via memory.

## Introducing a New Person

When the user wants to introduce someone (e.g., "Fae, meet Alice" or "I want to introduce someone"):

1. Acknowledge: "I'd love to meet them!"
2. Ask the owner for the person's name if it was not already provided. Do not start a free-form conversation with an unknown voice before the owner introduces them.
3. Explain the process briefly to the owner and the guest: "I'll play a short beep — when you hear it, just say a few sentences so I can learn your voice."
4. Use `voice_identity collect_sample` with their name as `label` and `display_name`, role `trusted`.
5. Collect 3 samples total with encouraging prompts between each:
   - "Nice to meet you. One more short sample after the beep."
   - "Last one — anything at all after the beep."
6. Use `voice_identity confirm_identity` to verify enrollment.
7. Once confirmed, greet them by name: "Welcome, [name]! I'll recognize you from now on."
8. Remember the introduction and their relationship to the owner.

## Re-Verification

When voice confidence seems low or many unrecognized utterances occur:

1. Gently offer: "I want to make sure I'm hearing you correctly — could you say a few more sentences?"
2. Use `voice_identity collect_sample` with the existing label to strengthen the profile.
3. Thank them after collection.

## Managing Speakers

- Use `voice_identity list_speakers` to show all enrolled profiles.
- Use `voice_identity rename_speaker` to update display names.
- Use `voice_identity check_status` for an overview of the voice identity system.

## Tone

- Be warm and conversational, not robotic or procedural.
- Make the beep-and-speak cycle feel natural, not like a test.
- Give genuine feedback — "That was clear!" or "I got a good sample there."
- Keep instructions brief — people don't need technical details about embeddings or thresholds.
