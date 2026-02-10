# GSD (Get Stuff Done) Framework

> Execution framework for Claude Code to implement planned milestones systematically.

## Principles

1. **Read the plan first.** Always start by reading `.planning/STATE.json` to know
   where you are, then read the current phase plan (`PLAN-phase-X.Y.md`).
2. **One task at a time.** Complete each task fully before moving to the next.
   Each task has clear files, requirements, and acceptance criteria.
3. **Test as you go.** Run `cargo clippy` and `cargo test` after each task.
   Fix issues immediately — don't accumulate tech debt.
4. **Update state.** After completing each task, update `STATE.json` progress.
   After completing a phase, advance to the next phase.
5. **Commit atomically.** One commit per task. Message format:
   `phase X.Y task N: brief description`
6. **Don't skip ahead.** Respect dependency order in `STATE.json.phase_order`.
   Phases without dependencies can run in parallel.

## Workflow

```
1. Read STATE.json → identify current phase and task
2. Read PLAN-phase-{current}.md → understand task requirements
3. Read existing code referenced by the task (files to edit)
4. Implement the task
5. Run: cargo clippy && cargo test
6. Fix any warnings or test failures
7. Commit: git add <files> && git commit -m "phase X.Y task N: description"
8. Update STATE.json: increment completed_tasks, current_task
9. If phase complete: advance phase number in STATE.json
10. Repeat from step 1
```

## State Machine

```
ready → in_progress → task_complete → ... → phase_complete → next_phase → ... → milestone_complete
```

## Error Recovery

- **Clippy warning**: Fix immediately, re-run before commit
- **Test failure**: Debug, fix, re-run all tests
- **Compile error**: Read the error, check types, fix
- **Dependency conflict**: Check Cargo.toml versions, resolve
- **Blocked by missing dependency**: Check phase_order deps, implement prerequisite first

## Quality Gates

Each task must pass before moving on:
- [ ] Code compiles (`cargo build --features gui`)
- [ ] No clippy warnings (`cargo clippy --features gui`)
- [ ] All tests pass (`cargo test`)
- [ ] Task acceptance criteria met (from phase plan)
- [ ] Changes committed

## Phase Completion Checklist

- [ ] All tasks in phase complete
- [ ] `cargo clippy` zero warnings (full project)
- [ ] `cargo test` all passing
- [ ] STATE.json updated to next phase
- [ ] progress.md updated with completion status
