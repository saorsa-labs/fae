# Phase 5.7: Integration Hardening & Pi Bundling

## Overview
Fix tracked review findings from Phase 5.4 (Codex P1/P2), bundle Pi binary
in existing release archives for offline first-run, add bundled-Pi extraction
to PiManager, cross-platform integration tests, and user documentation.

Full platform installers (.dmg, .deb, .AppImage, .msi) deferred to Milestone 4
(Publishing & Polish) — this phase delivers the core value using existing
tar.gz release infrastructure.

## Dependencies
- All previous Phase 5.x phases

## Tasks

### Task 1: Wrap PiDelegateTool in ApprovalTool (Codex P1 safety fix)
**Files:** `src/agent/mod.rs`

The PiDelegateTool is registered without approval gating (line 185). Pi can
execute arbitrary code (bash, file writes, etc.), so it MUST go through the
same ApprovalTool wrapper used by BashTool, WriteTool, and EditTool.

- Wrap `PiDelegateTool::new(session)` in `ApprovalTool::new(...)` using the
  existing `tool_approval_tx` and `approval_timeout` variables
- Ensure it's only registered when `tool_mode` is `Full` (not ReadOnly/ReadWrite)
  since Pi has write capabilities
- Add test verifying PiDelegateTool is approval-gated

### Task 2: Use working_directory in PiDelegateTool (Codex P2 schema fix)
**Files:** `src/pi/tool.rs`, `src/pi/session.rs`

The input schema defines `working_directory` but `execute()` ignores it.

- Parse `working_directory` from input JSON in `execute()`
- Pass it to `PiSession::send_prompt()` (or set it before sending)
- If PiSession doesn't support working directory, add a `set_working_dir()`
  method or include it in the RPC request
- Update tests to verify working_directory is used

### Task 3: Add timeout to Pi polling loop (Codex P2 timeout fix)
**Files:** `src/pi/tool.rs`

The polling loop (lines 84-91) has no timeout or cancellation. If Pi hangs,
the tool blocks forever.

- Add a configurable timeout (default 5 minutes) to the polling loop
- Return a descriptive error when timeout is exceeded
- Clean up the Pi session on timeout (kill the hanging process)
- Add test for timeout behavior

### Task 4: CI pipeline — download and bundle Pi in release archive
**Files:** `.github/workflows/release.yml`

Add steps to the existing release workflow:
- Download Pi's latest release binary for the target platform (macOS arm64)
- Include `pi` binary in the release `staging/` directory alongside `fae`
- The tar.gz archive already packages everything in staging/
- Cache downloaded Pi binary between CI runs
- Pin Pi version for reproducible builds (use env var)

### Task 5: First-run bundled Pi extraction in PiManager
**Files:** `src/pi/manager.rs`

When Fae starts and Pi not found on PATH:
- Before trying GitHub download, check if a bundled Pi exists alongside the
  Fae binary (same directory, or `../Resources/` on macOS .app bundles)
- If found, copy to standard install location (~/.local/bin/pi)
- Mark as Fae-managed
- This enables offline-friendly first run from the release archive
- Add `bundled_pi_path()` helper that returns the expected bundled location

### Task 6: Cross-platform integration tests
**Files:** `tests/pi_integration.rs` (new), update `tests/pi_session.rs`

Integration tests (mock-based, runnable in CI):
- PiManager finds bundled Pi at expected path
- PiManager installs from bundled Pi to standard location
- PiDelegateTool approval gating works
- Timeout fires when Pi doesn't respond
- working_directory is passed through correctly
- Bundled path detection on all platforms

### Task 7: User documentation
**Files:** `README.md`

Documentation additions:
- Pi integration section: what Pi does, why Fae uses it
- Getting started for non-technical users
- Troubleshooting: Pi not found, update failures, LLM server issues
- Configuration: models.json, scheduler, update preferences
- Platform notes (macOS Gatekeeper, Linux permissions)

### Task 8: Final verification and cleanup
**Files:** All Phase 5.x files

Verification checklist:
- `just lint` zero warnings
- `just test` all tests pass
- No `saorsa-ai` references remain except trait imports
- All Codex findings resolved
- PiDelegateTool properly gated
- Bundled Pi path detection works
- CI workflow syntax valid
