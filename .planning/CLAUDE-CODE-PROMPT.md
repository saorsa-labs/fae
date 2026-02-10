# Claude Code Execution Prompt

> Copy this prompt and give it to Claude Code to begin implementing Milestone 5.

---

## The Prompt

```
You are implementing Milestone 5 (Pi Integration, Self-Update & Autonomy) for the
Fae project — a Rust desktop voice assistant.

## Setup

Working directory: ~/Desktop/Devel/projects/fae-worktree-pi

Before you begin, read these files in order:
1. .planning/GSD-FRAMEWORK.md — your execution framework
2. .planning/STATE.json — current progress and phase order
3. .planning/ROADMAP.md — Milestone 5 overview and architecture
4. .planning/specs/pi-integration-spec.md — comprehensive technical spec
5. The current phase plan (PLAN-phase-{N}.md as indicated by STATE.json)

## GSD Protocol

Follow the GSD (Get Stuff Done) framework strictly:
1. Read STATE.json to find the current phase and task number
2. Read the corresponding PLAN-phase-X.Y.md
3. Implement ONE task at a time
4. After each task: cargo clippy --features gui && cargo test
5. Fix any warnings or failures immediately
6. Commit: git add <changed files> && git commit -m "phase X.Y task N: description"
7. Update STATE.json (increment completed_tasks and current_task)
8. Move to next task

## Phase Dependencies (from STATE.json)

Phases 5.1 and 5.3 have NO dependencies — start with either.
- 5.1: Local LLM HTTP Server (expose Qwen 3 as OpenAI-compatible endpoint)
- 5.2: Drop saorsa-ai (depends on 5.1)
- 5.3: Pi Manager — detect/install Pi (no dependencies)
- 5.4: Pi RPC Session & Skill (depends on 5.3)
- 5.5: Self-Update System (depends on 5.3)
- 5.6: Scheduler (depends on 5.5)
- 5.7: Installer Integration & Testing (depends on all above)

Start with Phase 5.1 (Local LLM HTTP Server) as indicated by STATE.json.

## Key Technical Context

- Fae is Rust with Dioxus 0.6 GUI, uses mistralrs for local LLM inference
- Pi is a coding agent (badlogic/pi-mono) that communicates via JSON-RPC over stdin/stdout
- Pi's config lives at ~/.pi/agent/models.json (OpenAI-compatible provider format)
- saorsa-ai is being REMOVED — replaced by direct ~/.pi/agent/models.json parsing
- saorsa-agent is KEPT — provides Tool trait, ToolRegistry, AgentLoop
- Fae's existing agent module is at src/agent/mod.rs
- Fae's skill system is at src/skills.rs (loads Skills/*.md into system prompt)
- Canvas integration (M1-M3) is already complete — don't touch canvas code

## Quality Requirements

- cargo clippy --features gui: ZERO warnings
- cargo test: ALL tests pass
- Every public function has a doc comment
- Error handling via Fae's Result/SpeechError types
- No unwrap() in non-test code
- Async where appropriate (tokio runtime is available)

## What NOT to Do

- Don't modify canvas code (src/canvas/, Skills/canvas.md)
- Don't modify voice pipeline code (src/audio/, src/stt/, src/tts/, src/vad/)
- Don't change the Dioxus GUI framework version
- Don't add Python, Node.js, or other runtime dependencies
- Don't store API keys in code — they come from ~/.pi/agent/models.json

Begin by reading the GSD framework and STATE.json, then start implementing.
```

---

## Usage Notes

1. **Start Claude Code** in `~/Desktop/Devel/projects/fae-worktree-pi`
2. **Paste the prompt above** as your first message
3. Claude Code will read the planning docs and begin implementing
4. Monitor progress via `STATE.json` and git log
5. If Claude Code gets stuck, point it to the specific phase plan file
6. After each phase completes, you can review the changes and continue

## Resuming After Interruption

If Claude Code's session ends mid-phase, give it this shorter prompt:

```
Continue implementing Milestone 5 for Fae. Read .planning/STATE.json to see
where we left off, then read .planning/GSD-FRAMEWORK.md and the current phase
plan. Pick up from the current task and continue following GSD protocol.
Working directory: ~/Desktop/Devel/projects/fae-worktree-pi
```
