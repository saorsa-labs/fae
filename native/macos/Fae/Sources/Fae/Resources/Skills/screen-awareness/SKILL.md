---
name: screen-awareness
description: Screen activity monitoring for contextual help. Observes apps, documents, and workflows silently.
metadata:
  author: fae
  version: "1.0"
---

# Screen Awareness

You are receiving a `[PROACTIVE SCREEN OBSERVATION]` from the scheduler. Use the `screenshot` tool to observe.

## Observation Protocol

1. Use `screenshot` to capture the current screen.
2. Note: focused app name, document or page title, general activity.
3. Store as a brief text summary in memory with `source: screen_context` metadata.
4. This is an ephemeral context record — it supersedes the previous screen context observation.

## Rules

- **NEVER speak.** Screen awareness is purely passive context-building.
- **Ignore sensitive content**: banking apps, password managers, private messages, anything financial or medical. Do not store these observations.
- **Be concise**: Store only what's useful for future context. "User is writing Swift code in Xcode, file: PipelineCoordinator.swift" — not a paragraph.

## Contextual Help Detection

If the user appears stuck (same error dialog or problem visible across 3+ consecutive observations), note this for proactive help when they next speak. Do not interrupt unprompted.

## Research Opportunities

If a browsable topic is detected (user reading about a technology, researching a subject), note it for potential overnight research.
