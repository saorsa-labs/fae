# ADR-004: Fae Identity and Personality System

**Status:** Superseded (historical)
**Date:** 2026-02-10
**Scope:** Rust-era identity/personality architecture (`SOUL.md`, `Prompts/system_prompt.md`, `src/personality.rs`, `src/intelligence/`)

> Historical note: this ADR is archival context from pre-Swift-rebuild implementation.
> Active personality assembly is implemented in `native/macos/Fae/Sources/Fae/Core/PersonalityManager.swift`.

## Context

Fae is not a generic assistant — she is a specific character with a consistent identity, voice, and relationship with her user. The personality system must:

- Define a stable identity that persists across conversations and updates
- Support personalization that adapts to individual users over time
- Scale from a condensed ~2KB voice prompt to a full ~18KB system prompt
- Enable proactive behavior without becoming annoying

## Decision

### Identity architecture

Fae's identity is defined in two truth sources:

1. **`SOUL.md`** — Behavioral contract defining identity, memory principles, tool use rules, presence behavior, and proactive intelligence guidelines. Human-authored, version-controlled.

2. **`Prompts/system_prompt.md`** — Operational system prompt with tool schemas, safety policy, and skill instructions. Generated/maintained alongside code.

### Character definition

**Core identity**: Fae is a personal AI companion — warm, direct, knowledgeable, and occasionally playful. She listens continuously and decides when to speak. She remembers everything that matters and learns forward from conversations.

**Voice characteristics**:
- Warm but not saccharine
- Direct but not curt
- Knowledgeable but not lecturing
- Occasionally playful, never performative
- Challenges weak assumptions gently
- Never uses corporate language, filler phrases, or excessive hedging

**Presence modes**:
- **Direct conversation** — responds with warmth and clarity
- **Overheard conversations** — may politely offer useful information
- **Background noise** — stays quiet (TV, music, irrelevant chatter)
- **Listening control** — always-listening unless user presses Stop Listening

### Prompt scaling

Three prompt variants serve different contexts:

| Variant | Size | Contents | Channel |
|---------|------|----------|---------|
| `VOICE_CORE_PROMPT` | ~2KB | Identity, style, companion presence | Voice (fast) |
| `CORE_PROMPT` | ~18KB | Full: tools, scheduler, skills, coding policy | Background |
| `BACKGROUND_AGENT_PROMPT` | ~1KB | Task-focused, tool-heavy, spoken-friendly | Background agents |

The voice channel stays fast by using the condensed prompt. The `assemble_prompt()` function in `src/personality.rs` selects the appropriate variant based on a `voice_optimized` flag and conditionally includes skills/permissions.

### Personalization system

Personalization happens through three mechanisms:

**1. Memory-driven context** (automatic):
- Before each response, hybrid retrieval injects relevant memories into the prompt
- After each turn, durable facts are captured with confidence scoring
- Conflict resolution supersedes old facts with lineage tracking

**2. Proactive intelligence** (configurable):

| Level | Behavior |
|-------|----------|
| Off | Disabled |
| Digest Only | Extract but deliver only on request |
| Gentle | Scheduled briefings (default) |
| Active | Briefings + timely reminders |

Background extraction after each conversation turn analyzes for: dates, birthdays, events, people, interests, commitments. Results feed into scheduler tasks and morning briefings.

**3. Noise control** (automatic):
- Daily delivery budget (default: 5 proactive items)
- Cooldown periods between deliveries
- Deduplication of similar items
- Quiet hours (default: 23:00-07:00)

### Onboarding

Structured interview flow with consent:
- Collects name, preferences, work context, relationships
- One question per turn (never batching)
- Outputs stored as tagged durable memory records with confidence/source
- Completion signal when core profile is populated
- Periodic re-interview triggers (staleness/conflict/user request)
- Accessible via Settings > About > Reset Onboarding

### Relationship tracking

Fae tracks people mentioned in conversation:
- Who the user knows, how they know them
- Last mention date, relationship context
- Weekly stale-relationship detection (scheduler task)
- Gentle check-in suggestions in morning briefings

## Consequences

### Positive

- **Consistent character** across all interactions via SOUL.md
- **Scalable prompts** — voice stays fast, background gets full context
- **User-adaptive** — personality layer learns without changing core identity
- **Non-intrusive** — noise control prevents proactive features from becoming annoying

### Negative

- **Prompt budget tension** — more personality context = less room for conversation history
- **Extraction quality** — relies on deterministic parsing, no dedicated extractor model yet
- **Identity drift risk** — SOUL.md changes must be reviewed carefully to maintain character coherence

## Future directions

- Model-assisted extraction/validation pass for higher-quality memory capture
- Voice cloning integration for personalized TTS voice
- Reinforcement from correction signals over time
- Per-memory sensitivity classes and restricted recall policy

## References

- `SOUL.md` — Behavioral contract
- `Prompts/system_prompt.md` — Operational system prompt
- `src/personality.rs` — Prompt assembly and variants
- `src/intelligence/` — Proactive extraction and briefing
- `docs/guides/Memory.md` — Memory system details
