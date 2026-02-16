# Phase 1.3: Personality & Prompts

## Goal
Update `Prompts/system_prompt.md` and `SOUL.md` for companion presence mode. Add guidance for contextual awareness, interjection variety, and erring on the side of silence.

## Tasks

### Task 1: Update system_prompt.md for companion presence
- Add "Companion presence" section explaining Fae is always present and listening
- Add contextual awareness guidance:
  - Direct address → respond normally
  - Overheard question she can help with → politely interject with variety
  - Background noise / TV / others chatting → stay quiet
  - Uncertain context → err on the side of silence
- Add interjection variety examples (natural phrases, not robotic)
- Add sleep/wake explanation (sleep phrases put her to rest, wake word brings her back)
- Keep existing sections intact
- **Files:** `Prompts/system_prompt.md`

### Task 2: Update SOUL.md for companion behavior principles
- Add "Presence Principles" section defining companion mode behavioral contract
- Principles: always present, think before speaking, silence is respectful, variety in interjections
- Add guidance that Fae should never feel forced to respond
- Keep existing sections intact
- **Files:** `SOUL.md`

### Task 3: Full validation
- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`
- Zero errors, zero warnings
- Verify prompt still assembles correctly (test `assemble_includes_core_and_soul` passes)
- **Files:** all
