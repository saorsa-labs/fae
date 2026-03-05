# Skills-First Heartbeat + Adaptive Canvas — Merge Package

## Scope

This branch introduces a pre-launch architecture shift where proactive coaching is driven by skills and heartbeat contracts, while Swift remains a thin trusted host for scheduling, policy, and rendering.

## Change Summary

### 1) Heartbeat contract + schema
- Added `HeartbeatContract.swift` with typed models:
  - `HeartbeatRunEnvelope`, `HeartbeatAckPolicy`, `HeartbeatRunDecision`, `HeartbeatCanvasIntent`
  - progression state (`CapabilityProgressState`, `CapabilityProgressStage`)
  - parser (`HeartbeatDecisionParser`) with `HEARTBEAT_OK` no-op behavior.
- Added guide: `docs/guides/SKILLS_FIRST_HEARTBEAT_CONTRACT.md`.

### 2) Scheduler heartbeat lane
- Added `skills_heartbeat` timer lane to `FaeScheduler`.
- Includes:
  - active-hours gating,
  - busy deferral/retry,
  - delivery target controls (`none|voice|canvas`),
  - heartbeat envelope prompt construction,
  - capability progression persistence.
- Legacy `skill_proposals` daily run is suppressed when heartbeat is enabled.

### 3) Skills-first capability coaching
- Added skill: `Resources/Skills/capability-coach/SKILL.md`.
- Skill is activated/deactivated based on `scheduler.heartbeat_enabled`.
- Heartbeat prompt + skill contract now require structured decision output:
  - `<heartbeat_result>{...}</heartbeat_result>`
  - optional `<canvas_intent>{...}</canvas_intent>`

### 4) Typed canvas rendering (trusted host)
- `PipelineCoordinator` parses typed `<canvas_intent>` payloads.
- Canvas is rendered via trusted Swift templates only (no model-authoritative raw HTML).

### 5) Runtime progression + telemetry
- Heartbeat decisions are fed back from pipeline to scheduler via new callback.
- Scheduler tracks:
  - status metrics (`fae.heartbeat.status_*`),
  - muted-delivery reasons (`quiet_hours`, `cooldown`, `noise_budget`),
  - deferred/dropped/accepted,
  - ack suppression/schema misses.
- Progression updated via:
  - decision suggestions (`suggestedStage`),
  - interaction feedback (`recordHeartbeatInteraction`).

### 6) Config + self_config coverage
- Added/confirmed scheduler heartbeat config keys in parse/serialize.
- Added runtime patch handling in `FaeCore` for:
  - heartbeat active window,
  - ack token,
  - ack max chars,
  - cooldown/target/enabled.
- Added heartbeat keys to `self_config` adjustable settings.

## Migration Notes

- Existing configs load safely; defaults are provided for all heartbeat keys.
- `scheduler.heartbeat_enabled` now controls both scheduler behavior and `capability-coach` activation.
- Heartbeat active window now requires strict `HH:MM` validation on runtime patch updates.

## Validation

Executed in worktree:
- `swift build` ✅
- `swift test -q` ✅ (418 tests passing)

## Rollback Plan

If regression appears post-merge:
1. Disable heartbeat at runtime:
   - `scheduler.heartbeat_enabled = false`
2. Re-enable legacy daily proposals (automatic when heartbeat disabled).
3. Revert commit(s) touching:
   - `Scheduler/HeartbeatContract.swift`
   - `Scheduler/FaeScheduler.swift`
   - `Pipeline/PipelineCoordinator.swift`
   - `Core/FaeCore.swift`
   - `Tools/BuiltinTools.swift`
   - `Resources/Skills/capability-coach/SKILL.md`
4. Re-run:
   - `swift build`
   - `swift test -q`

## Merge-Back Steps

1. From repo root (main worktree):
   - `git fetch --all`
   - `git checkout main`
   - `git pull`
2. Merge feature branch:
   - `git merge --no-ff codex/skills-first-heartbeat-canvas`
3. Validate on `main`:
   - `cd native/macos/Fae`
   - `swift build`
   - `swift test -q`
4. Smoke checks:
   - heartbeat no-op ack suppression,
   - typed canvas intent render,
   - heartbeat enable/disable toggles capability-coach.
5. Push main.
