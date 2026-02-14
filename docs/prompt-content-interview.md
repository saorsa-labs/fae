# Prompt Content Interview Plan

Purpose:
- Finalize exact text for `Prompts/system_prompt.md`, `SOUL.md`, and `Prompts/onboarding.md`.
- Keep behavior prompt-driven (not hardcoded workflows), with memory used for state.

Outputs:
- Final system prompt text.
- Final SOUL text.
- Final onboarding checklist text.
- A short decision log for future revisions.

## Round 1: System Prompt Boundaries

Questions:
1. What is Fae's default response length in normal chat?
2. How proactive should Fae be by default: low, medium, or high?
3. How often should work-progress updates appear during multi-step tasks?
4. Should Fae always propose next steps, or only when confidence is high?
5. Should Fae ask before tool actions by default, or only for high-impact actions?

## Round 2: Voice and Relationship (SOUL)

Questions:
1. How warm vs direct should Fae feel on a 1-5 scale?
2. Should humor be rare, occasional, or frequent?
3. Should Fae challenge weak assumptions directly or softly?
4. How should Fae handle disagreement: brief correction first or exploratory dialogue first?
5. What must never appear in Fae's tone?

## Round 3: Onboarding and Consent

Questions:
1. What onboarding fields are required vs optional?
2. What privacy boundaries should onboarding enforce by default?
3. Should onboarding ask one question per turn always, or allow batching in specific moments?
4. What exact signal marks onboarding complete?
5. When is re-onboarding allowed?

## Round 4: Memory and Corrections

Questions:
1. Which facts should be durable by default?
2. What confidence threshold should gate profile updates?
3. Should corrections always supersede prior facts immediately?
4. What explicit forget/erase language should Fae recognize?
5. What memory details must stay off the main conversation surface?

## Round 5: Proactivity and Tools

Questions:
1. What categories should trigger proactive help suggestions?
2. What categories should never trigger proactive interruption?
3. Should Fae schedule timers/check-ins automatically or only with explicit user opt-in?
4. For local `claude`/`codex`, should permission be global or per-task?
5. If permission is denied once, can Fae ask again later and under what condition?

## Round 6: Final Wording Review

Checklist:
1. Verify no conflicting instructions across the 3 files.
2. Verify tool rules are explicit and testable.
3. Verify onboarding completion condition matches memory tags.
4. Verify proactive behavior is useful and quiet.
5. Freeze v1 text and record change policy.

## Decision Log Template

- Date:
- Topic:
- Decision:
- Reason:
- Files impacted:
