# GSD (Get Stuff Done) Framework

> Execution framework for the active `.planning/STATE.json` project.

## Principles

1. **Read state, then the exact plan path.** Start with `.planning/STATE.json`, then
   read `phase.plan` from state. Do not guess plan filenames from the phase number.
2. **One task at a time.** Each task must name files, acceptance criteria, and tests.
3. **Use project-appropriate validation.** For Fae Swift work, prefer:
   `cd native/macos/Fae && swift build && swift test`
4. **Keep governance intact.** Refactors must preserve approvals, broker checks,
   damage control, audit logging, and existing user-visible safety behavior.
5. **Update state deliberately.** Advance `progress` and `phase` only after the
   current task or phase is actually complete.
6. **Respect dependency order.** Use `STATE.json.phase_order[*].depends_on`.

## Workflow

```
1. Read STATE.json → identify current phase, milestone, and plan path
2. Read the exact file at STATE.json.phase.plan
3. Read referenced code before editing
4. Implement one task
5. Run the validation named by the phase plan
6. Fix failures immediately
7. Commit atomically: "phase X.Y task N: brief description"
8. Update STATE.json progress
9. If the phase is complete, advance to the next phase in phase_order
10. Repeat
```

## State Machine

```
designed → ready → in_progress → task_complete → phase_complete → next_phase → milestone_complete
```

## Error Recovery

- **Plan mismatch**: Stop and fix planning docs before implementation.
- **Build/test failure**: Fix before changing phase status.
- **Dependency block**: Check `phase_order.depends_on`; do not skip prerequisites.
- **Spec ambiguity**: Update the active phase plan or roadmap, then continue.

## Quality Gates

Each task must pass before moving on:
- [ ] Task acceptance criteria met
- [ ] Build/test commands from the phase plan pass
- [ ] No new warnings introduced
- [ ] Relevant docs/tests updated
- [ ] Changes committed

## Phase Completion Checklist

- [ ] All tasks in the phase complete
- [ ] Validation commands pass for the touched area
- [ ] `STATE.json` advanced to the next phase
- [ ] Roadmap/state remain consistent
