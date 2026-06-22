# Handoff — retire the legacy Swift conversation UI (orb host is the only product UI)

> ## ✅ DONE — committed `4a482e35` on `retire-legacy-ui` (reviewer-verified, 2026-06-19)
> ~2071 lines deleted (ContentView, ConversationScrollView, InputBarView, VoiceHintsView,
> ThinkingTraceViews, old ConversationController/BridgeController); non-visual state split into
> ConversationRuntimeController + ConversationEventBridgeController; main window = license/status chrome
> only; "Ask Fae" fallback removed. KEPT (wired): Settings/About/Debug/MemoryImport/Receipts/InputOverlay.
> Verified: clean deletions (no dangling refs — grep + build), `swift build` clean, 44 targeted tests,
> live run-dev = orb active / main window hidden / orb-down→alert (no legacy window). **RESIDUAL before
> merge: a human visual click-through of the kept windows.** Ready to merge `retire-legacy-ui` →
> `llamacpp-serving-adapter` when the tracks integrate.

> **HANDOFF (2026-06-19): this is yours now.** B5 (audio-in) is DONE + PASS, so the team that built it
> picks up this track. **Your worktree already exists** — `/Users/davidirvine/Desktop/Devel/projects/
> fae-ui` on branch `retire-legacy-ui` (off the latest `llamacpp-serving-adapter`, includes B5 + the
> orb-first build fix). Just `cd` into it and work there (Setup below). Do NOT work in the main repo
> (`…/projects/fae`) or `fae-acp` (ACP team live). **Implement + test to completion, then HAND BACK with
> verbatim evidence — do NOT commit/push; the reviewer commits onto `retire-legacy-ui`.** The reviewer
> re-runs your evidence (live run + `git diff`) — static-only review has missed a release-blocking bug on
> this project, and an agent once fabricated a report, so claims are verified, not trusted.

Self-contained; verify every claim against the repo and a live run.

## Why
The Rust orb host (`native/rust/fae-ui-shell`) is the only product UI; the Swift app is the host
(pipeline/memory/tools/windows). But legacy Swift conversation UI still exists and keeps getting used by
teams (the recent `test-serve`/`run-native` recipes launched it; those build recipes are now fixed to
always embed the orb shell + daemon — commit dc67d90d). This phase removes the legacy *code* so the old
UI can't be reached at all, while KEEPING the genuine app windows.

## Setup (the worktree already exists — just enter it)
```bash
cd /Users/davidirvine/Desktop/Devel/projects/fae-ui   # branch retire-legacy-ui (already created for you)
git status                                            # confirm clean on retire-legacy-ui
just --list                                           # build recipes already embed the orb + daemon
```
Do ALL work here. Do NOT `git checkout` a branch in the main repo (`…/projects/fae`) — another team is
live there; the worktree shares `.git` but has its own working dir. Hand back when done; do NOT
commit/push (the reviewer commits onto `retire-legacy-ui`). If you want a fresh pull from the base,
`git merge llamacpp-serving-adapter` from inside this worktree.

## Scope — DELETE vs KEEP (verify before deleting)

**Candidate DELETE (legacy conversation surface — duplicates the orb/pill):**
- `ContentView.swift`, `ConversationController.swift`, `ConversationScrollView.swift`,
  `ConversationBridgeController.swift`, `InputBarView.swift` — the in-app conversation window/scroll/input.
- The **"Ask Fae" fallback window** + any "automatic fallback if the orb host dies" path
  (`FaeApp.swift` ~line 478; `RustUiShellController` notes "no window fallback" at line 52 — reconcile:
  there must be NO legacy conversation window, even when the orb host is down — instead surface a clear
  error/retry, which already exists: "orb host auto-restarts 3×→Retry/Quit alert").
- Legacy "Messages" / "Browser data" panels IF they are Swift-side (the orb host now owns
  `show_messages` / `open_browser_data_panel` — see `RustUiShellController:652`). Confirm they're handled
  in the orb host and remove any dead Swift counterparts. (Aligns with the orb-pill-ux P2 plan.)

**KEEP (genuine app surfaces — do NOT delete):**
- All `Settings*Tab.swift` + `SettingsView.swift` (settings window).
- `AboutWindow*`, `DebugConsoleWindowView`, `MemoryImportWindow*`, `ReceiptsWindow*`/`ReceiptsTimelineView`,
  `LicenseAcceptanceView`, `SkillImportView` — real secondary windows.
- `InputOverlayView.swift` — the approval/JIT-input overlay (the orb host requests it; needed).
- `OrbStateBridgeController.swift`, `OrbTypes.swift` — orb wiring (kept; note B5/orb-host-owns-state
  already trimmed the mode-drive logic here — don't regress it).
- `WindowStateController`, `NSWindowAccessor`, `AuxiliaryWindowManager`, `FaeApp.swift` — window plumbing
  + app entry (edit, don't delete).
- `VoiceHintsView`, `ThinkingTraceViews` — verify whether still used (by a kept window) before touching.
- The **main window per the orb-pill-ux decision is KEPT** (shown by hotkey + approval) — do NOT delete
  the main window outright; remove only the legacy *conversation content* if it duplicates the orb/pill.
  If unsure whether the "main window" still hosts legacy conversation views, STOP and ask the reviewer.

## The work
1. **Inventory precisely.** For each DELETE candidate, `rg` its symbol across the Swift sources to find
   references; map what's wired where (menus, `FaeApp`, controllers). Produce a short delete/keep
   decision list with the reference evidence BEFORE editing.
2. **Delete the legacy conversation UI** + remove its wiring (menu items, instantiations, observers).
   Ensure removing it leaves NO dangling references and the app still compiles.
3. **Reconcile the orb-host-down path**: no legacy conversation window resurrects on dock-reopen or orb
   crash — only the existing auto-restart + Retry/Quit alert. Verify the `FaeApp` dock-reopen guards
   (~lines 161/281) still hold and don't reference deleted views.
4. **Keep the app whole**: Settings/About/Debug/MemoryImport/Receipts/License/overlays all still open.

## Verify (capture verbatim)
- `git diff --stat` + the delete/keep decision list with `rg` evidence.
- `swift build` clean (the deletion must not leave dangling refs — this is the main risk).
- A **live run** via the fixed `just run-dev` (orb shell + daemon): the orb/pill is the conversation
  surface; confirm NO legacy conversation window appears, the kept windows (Settings, About, etc.) still
  open, and killing the orb host shows the Retry/Quit alert (not a legacy window). Capture the evidence.
- `just test` (or the relevant Swift tests) — fix/remove tests of deleted views.

## Gotchas
- Worktree only; do NOT touch the main repo (B5 live) or `fae-acp` (ACP live).
- The build recipes already embed the orb (dc67d90d) — `just run-dev`/`test-serve` are the right harness.
- Don't regress orb-host-owns-state (`OrbStateBridgeController` mode logic already retired) or the
  approval/input overlay (`InputOverlayView` is needed).
- `env -u RUSTFLAGS` if you touch any crate. *(Note: this doc predates [ADR-011](../../adr/011-headless-rust-core-runtime.md) (2026-06-22), which makes the headless Rust core canonical. The "you shouldn't touch crates" guidance was specific to this Swift-UI-retirement worktree and is NOT a general prohibition on Rust work.)*
- **autoresearch.jsonl** stays out of your diff.
- If a "delete" candidate turns out to be load-bearing for a kept window, KEEP it and note why.

## Done criteria
1. Delete/keep decision list with `rg` reference evidence.
2. Legacy conversation UI + its wiring removed; `swift build` clean (no dangling refs).
3. Live `run-dev`: orb/pill is the only conversation surface; kept windows still open; orb-down shows the
   alert, not a legacy window.
4. Tests green (deleted-view tests removed/updated).
5. Hand back (do NOT commit/push). Reviewer commits onto `retire-legacy-ui`, then merges.
