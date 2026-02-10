# Phase 1.1: Skill System Implementation

## Overview
Build a skill system for fae: rewrite the saorsa-canvas SKILL.md as an AI-consumable
tool reference, create a built-in canvas skill for fae, implement a skill loader module,
wire skills into the system prompt, and add a skills info section to the GUI settings.

## Tasks

### Task 1: Rewrite saorsa-canvas `canvas-skill/SKILL.md`
**Files:** `../saorsa-canvas/canvas-skill/SKILL.md`

Replace the current developer-oriented doc with a concise AI-agent tool reference.
This is the canonical reference that any AI model (Fae, Claude via MCP, etc.) can consume.

Requirements:
- Example-driven, not prose-heavy
- Show exact JSON for each tool call (canvas_render, canvas_interact, canvas_export)
- Cover every content type with a working example (bar, line, pie, scatter, image, text)
- List all MCP tools with one-line descriptions in a quick reference table
- Keep under 200 lines (small model friendly)
- Include scene management patterns (clear, update position)

**Acceptance:**
- SKILL.md exists at `../saorsa-canvas/canvas-skill/SKILL.md`
- Under 200 lines
- Every tool has at least one JSON example

### Task 2: Create `Skills/canvas.md` (fae built-in canvas skill)
**Files:** `Skills/canvas.md` (new)

Fae-specific behavioural skill for voice conversations. Must be concise (40-60 lines)
since it goes into the system prompt of a small local model.

Content:
- When to use canvas (visual data, charts, comparisons) and when NOT to use it
- Session ID is always "gui"
- Chart type to data format quick reference (bar, line, pie, scatter)
- Image and text annotation formats
- Tips: short titles, clear labels, render new element for follow-ups

**Acceptance:**
- File exists at `Skills/canvas.md`
- 40-60 lines
- Covers all content types concisely

### Task 3: Create `src/skills.rs` (skill loading module)
**Files:** `src/skills.rs` (new), `src/lib.rs` (edit to add `pub mod skills;`)

Implement the skill loading module:
- `CANVAS_SKILL: &str = include_str!("../Skills/canvas.md")` built-in canvas skill
- `skills_dir() -> PathBuf` returns `~/.fae/skills/`
- `list_skills() -> Vec<String>` builtins + user files (*.md in skills_dir)
- `load_all_skills() -> String` concatenates CANVAS_SKILL + user skill files

Tests:
- `CANVAS_SKILL` is non-empty
- `list_skills()` includes "canvas" in builtins
- `load_all_skills()` returns content containing canvas skill
- Missing `~/.fae/skills/` directory handled gracefully (no error)

**Acceptance:**
- `src/skills.rs` exists with all 4 functions
- `lib.rs` has `pub mod skills;`
- All tests pass
- `cargo clippy` zero warnings

### Task 4: Wire skills into `assemble_prompt()` in `src/personality.rs`
**Files:** `src/personality.rs` (edit)

Add skills as the third layer in prompt assembly:
1. CORE_PROMPT
2. Personality
3. Skills (NEW via `crate::skills::load_all_skills()`)
4. User add-on

Update existing tests that check `assemble_prompt` output so the skills content
now appears between personality and add-on.

**Acceptance:**
- `assemble_prompt()` includes skills content
- Skills appear between personality and add-on in the output
- Existing personality tests updated and passing
- `cargo clippy` zero warnings

### Task 5: Add "Skills" info section to GUI settings
**Files:** `src/bin/gui.rs` (edit)

Add a read-only "Skills" section in Settings showing:
- "Active Skills" header
- List skill names from `fae::skills::list_skills()`
- Note: "Add .md files to ~/.fae/skills/ for custom skills"
- Path display of the skills directory

**Acceptance:**
- Skills section visible in settings
- Lists both built-in and user skills
- Shows the skills directory path
- `cargo clippy` zero warnings
- GUI builds successfully
