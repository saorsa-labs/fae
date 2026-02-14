# Personalization, Interviews, and Proactive Automation Plan

This plan defines how Fae becomes continuously useful without becoming noisy.

## Outcomes

- Better personalization over time through explicit interview + correction loops.
- Reliable proactive assistance that improves life quality.
- Low-noise delivery model that avoids interruption fatigue.

## Current baseline

Already in place:

- durable memory model with audit and migration
- automatic recall/capture in conversation path
- scheduler-based recurring memory maintenance
- suppression of memory telemetry on primary conversation surface

## Design principles

- Quiet by default.
- Actionability over volume.
- Consent and correction first.
- Confidence-aware storage and recall.
- Progressive personalization (do not front-load every question).

## Interview architecture

### 1) Onboarding interview (consent-gated)

Capture:

- preferred name and pronouns
- communication style (concise/detail, direct/supportive)
- schedule preferences (focus windows, sleep hours)
- life optimization goals (health, work, family, learning)
- recurring obligations (meetings, routines, deadlines)

Write strategy:

- store as `profile` records with tags (`interview`, `identity`, `preferences`, `routine`)
- include `source_turn_id`, confidence, and timestamp

### 2) Continuous micro-interviews

Small follow-ups during natural conversation when signal is high:

- clarify ambiguous preferences
- detect changes in routine
- reconcile contradictions

### 3) Re-interview triggers

- stale critical profile data
- repeated contradictions on same topic
- explicit user request to refresh preferences
- model confidence below threshold

## Proactive assistance architecture

### Job classes

1. **Maintenance jobs**
- memory migrate/reindex/reflect/gc
- always silent unless failure severity is high

2. **Awareness jobs**
- check for meaningful changes in user context/memory patterns
- produce internal scoring only

3. **Delivery jobs**
- produce human-facing digest or intervention
- strict gating to prevent clutter

### Delivery channels

- Primary voice/screen: only urgent or explicitly requested updates.
- Canvas/inbox summary: normal proactive briefings.
- Deferred digest windows: non-urgent insights batched.

## Noise-control policy (must implement)

- **Signal threshold**: do not deliver low-confidence/low-impact items.
- **Batch window**: combine related items in one digest.
- **Cooldown**: enforce minimum interval between non-urgent interruptions.
- **Deduplication**: suppress repeats until new evidence appears.
- **Quiet hours**: no non-urgent interruptions during protected windows.
- **Escalation rules**: immediate alerts only for severe/urgent categories.

## Proposed scheduler model

Current scheduler is interval/daily-UTC based.

Recommended additions:

- add a proactive digest task (default: 2 times/day local time)
- add an interview-refresh task (default: weekly local time)
- add per-task delivery policy:
  - `silent`
  - `digest_only`
  - `interrupt_if_urgent`

## Better-than-baseline strategy

To exceed common assistant baselines:

- combine heartbeat-style awareness scoring with precise scheduled digests
- separate detection from delivery (compute often, deliver rarely)
- prioritize life-impactful recommendations over generic reminders
- keep a per-user annoyance budget and back off automatically when exceeded

## Memory schema extensions (planned)

Add optional fields:

- `importance_score` (`0..1`)
- `recall_priority` (`low|normal|high`)
- `sensitivity` (`normal|restricted`)
- `stale_after_secs`
- `interview_origin` (`onboarding|refresh|inferred`)

## TDD implementation plan

### Phase 1: Interview capture hardening

Tests first:

- consent-gated interview write behavior
- stable tagging and confidence assignment
- contradiction supersession from interview updates

Implementation:

- interview parser and tagger
- durable write + audit path

### Phase 2: Proactive digest engine

Tests first:

- digest dedupe
- cooldown enforcement
- quiet-hours suppression
- urgency bypass behavior

Implementation:

- scoring + batching engine
- delivery channel routing

### Phase 3: Annoyance budget and adaptive throttling

Tests first:

- repeated low-value alerts are throttled
- high-value alerts still pass

Implementation:

- per-user interruption budget
- automatic backoff policy

### Phase 4: Observability and evaluation

Track:

- proactive items generated vs delivered
- suppression reasons
- user corrections/undo rate
- accepted vs dismissed actions

Success criteria:

- higher accepted-action rate
- lower interruption count
- zero increase in user-friction signals

## Rollout and safety

- ship behind config flags
- start in digest-only mode
- enable voice/surface interruption only after acceptance metrics are healthy
- maintain explicit user controls for verbosity and quiet windows
