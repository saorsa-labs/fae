# Claude Code Execution Prompt

> Copy this prompt when you want an implementation agent to execute the active JSC planning project.

## The Prompt

```text
You are implementing the active project described in .planning/STATE.json for the Fae macOS app.

Working directory: /Users/davidirvine/Desktop/Devel/projects/fae

Before changing code, read these files in order:
1. .planning/GSD-FRAMEWORK.md
2. .planning/STATE.json
3. .planning/ROADMAP.md
4. The exact file at STATE.json.phase.plan

Execution rules:
- Follow the active phase plan exactly.
- Implement one task at a time.
- Do not guess the plan filename; use STATE.json.phase.plan.
- Preserve Fae's approval, broker, damage-control, audit, and tool-governance behavior.
- Prefer extracting reusable actors/services over duplicating PipelineCoordinator logic.

Validation:
- Run the commands named by the phase plan.
- For Swift app changes, prefer:
  cd native/macos/Fae && swift build && swift test

Commit format:
- phase X.Y task N: brief description

Do not start by browsing unrelated old phase files. The active project is the JSC tool runtime project in STATE.json.
```

## Usage Notes

1. Start in `/Users/davidirvine/Desktop/Devel/projects/fae`
2. Paste the prompt above
3. Review progress via `.planning/STATE.json`
4. Keep work aligned with `.planning/ROADMAP.md` and `phase.plan`
