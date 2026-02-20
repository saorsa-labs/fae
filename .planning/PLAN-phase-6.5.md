# Phase 6.5 — Integration Validation

**Status:** Planning
**Milestone:** 6 — Dogfood Readiness

---

## Overview

Phase 6.5 is the final validation phase before team-wide dogfood release:
- Verify all 11 dogfood findings are resolved
- Update project documentation (CLAUDE.md, architecture docs)
- Run full validation (Rust + Swift build)
- Release prep: version is already 0.7.0

All verification, no new features.

---

## Tasks

### Task 1 — Run full Rust validation (15 min)

**Goal:** Verify zero errors, zero warnings across all Rust checks.

**Subtasks:**
1. `cargo fmt --all -- --check` — zero diffs
2. `cargo clippy --all-targets -- -D warnings` — zero warnings
3. `cargo test` — all pass (note: use plain `cargo test`, NOT `--all-features`)
4. `cargo check` — zero errors
5. Document any flaky tests (session store test is known flaky)

**Files:** None (verification only)

**Dependencies:** None

---

### Task 2 — Run full Swift build (15 min)

**Goal:** Verify Swift package builds with zero errors.

**Subtasks:**
1. `swift build --package-path native/macos/FaeNativeApp` — zero errors
2. Verify no Swift compiler warnings related to our code (linker warnings from libfae.a are expected)

**Files:** None (verification only)

**Dependencies:** None (parallel with Task 1)

---

### Task 3 — Verify dogfood findings resolution (30 min)

**Goal:** Check each of the 11 original dogfood findings is resolved.

**Subtasks:**
1. "show conversation" opens conversation panel — Phase 6.2 (PipelineAuxBridgeController)
2. "show canvas" opens canvas panel — Phase 6.2 (PipelineAuxBridgeController)
3. Download progress visible — Phase 6.3 (progress bar JS + ConversationBridgeController)
4. Partial STT visible — Phase 6.3 (setSubtitlePartial JS)
5. Streaming assistant text — Phase 6.3 (appendStreamingBubble JS)
6. Orb audio level response — Phase 6.3 (setAudioLevel JS)
7. Right-click context menu — Phase 6.3 (NSMenu in ContentView)
8. Tool mode settings — Phase 6.4 (SettingsToolsTab)
9. Channel settings (Discord/WhatsApp) — Phase 6.4 (SettingsChannelsTab)
10. CameraSkill removed — Phase 6.4 (builtins.rs)
11. API/Agent code removed — Phase 6.1 (backend cleanup)

**Files:** Verification only — read files to confirm changes exist

**Dependencies:** Tasks 1 and 2

---

### Task 4 — Update CLAUDE.md (30 min)

**Goal:** Update project CLAUDE.md to reflect current state after Milestone 6.

**Subtasks:**
1. Update Swift-side files table with new files (SettingsToolsTab, SettingsChannelsTab)
2. Update NotificationCenter names if any were added
3. Note that CameraSkill was removed
4. Document config.patch keys (tool_mode, channels.enabled, channels.discord.*, channels.whatsapp.*)
5. Update "Completed Milestones" section
6. Verify all file paths in tables are still accurate

**Files:** `CLAUDE.md`

**Dependencies:** Task 3

---

### Task 5 — Commit validation and push (15 min)

**Goal:** Final commit with documentation updates, push to remote.

**Subtasks:**
1. Stage and commit documentation changes
2. Push all Phase 6.1-6.5 commits to main
3. Verify CI passes (or note if manual trigger needed)

**Files:** Git operations only

**Dependencies:** Task 4

---

## Dependency Graph

```
Task 1 (Rust validation)
Task 2 (Swift validation)
    └── Task 3 (Verify findings)
        └── Task 4 (Update CLAUDE.md)
            └── Task 5 (Commit and push)
```

Tasks 1 and 2 run in parallel. Everything else is sequential.

---

## Acceptance Criteria

- [ ] `cargo fmt`, `cargo clippy`, `cargo test`, `cargo check` all pass
- [ ] `swift build` passes
- [ ] All 11 dogfood findings confirmed resolved
- [ ] CLAUDE.md updated with Phase 6.1-6.4 changes
- [ ] All commits pushed to main
- [ ] Milestone 6 marked complete in STATE.json
