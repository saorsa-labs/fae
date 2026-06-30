# B-Swift Phase C+ Handoff — fresh session (advisor context limit)

> **Why fresh:** the prior session's advisor hit its context window (context_length_exceeded)
> — the ONLY reason to start fresh, per the original handoff mandate. Work to the END of the
> project. Do not pause for per-phase hand-back. Merge each completed phase yourself after
> review passes. Push forward.

## 0. State right now (2026-06-30)

- Repo: `/Users/davidirvine/Desktop/Devel/projects/fae-b-swift-3b`, branch `b/swift-3b-routing`.
- `origin/main` @ `4a90523b` (Phase A MERGED — confined-fallback gate + fd-anchored TOCTOU fix).
- **Phase B is COMMITTED locally but NOT YET MERGED** (2 commits ahead of origin/main):
  - `85f4e328` feat(daemon): B-Swift Phase B — daemon crash-supervisor
  - `a297382f` fix(daemon): Phase B review fixes — restart accounting, leak, reentrancy, honest MLX copy
- HEAD = `a297382f`. Clean tree.

## 1. Phase B status — READY FOR FINAL ADVISOR GATE + MERGE

**Every gate except the final advisor project-complete review PASSED** (the advisor's context
filled up before that last call). Do the final advisor gate, then FF-merge:

```bash
cd /Users/davidirvine/Desktop/Devel/projects/fae-b-swift-3b
git fetch origin main
git merge --ff-only origin/main   # already up to date (Phase B not pushed)
# After advisor approval:
git push origin HEAD:main
```

**Validation evidence (all green):**
- Swift full suite: **3495 passed / 0 failures / 0 non-CoreData errors**
- Rust (Phase B touched no `.rs`/`.toml`): `cargo fmt --all -- --check` clean; `cargo check --workspace --all-targets` clean
- Targeted: `DaemonSupervisorTests` 12/0 + `DaemonToolHostTests` 54/0 = 66/0
- Code-review subagent: **PASS** — CRITICAL (restart double-count) + both MEDIUMs (process leak, terminationHandler reentrancy) RESOLVED
- Red-team subagent: **"safe to merge"** — HIGH (no MLX fallback wired → honest terminal-until-Retry copy), both MEDIUMs RESOLVED, no new critical/high
- Advisor (last substantive guidance before context limit): approved the fix plan (decideAfterFailedRelaunch, clearFailedLaunchState, identity guard, honest MLX copy) and said "After fixes: run swift test --filter DaemonSupervisorTests, swift build, re-run reviewer + red-team, only then resume full validation/advisor gate" — ALL DONE, all PASS.

**Phase B design summary** (so the advisor gate has the facts):
- `DaemonSupervisor` (pure, injectable clock/sleeper, no Process): bounded restart (3 attempts, 1/2/4s backoff, 60s stable-run reset). `decideOnUnexpectedExit` (crash path) + `decideAfterFailedRelaunch` (relaunch-failure path, increments once per actual launch attempt — NOT a re-count). `.exhausted` transition fires the callback once, then `.alreadyExhausted` no-op.
- `DaemonLLMEngine`: `terminationHandler` hops to actor; identity guard `guard let exiting, process === exiting`. `clearFailedLaunchState` (no disarm) for failed relaunch; `internalShutdown` (disarms) for intentional quit. `onEndpointsChanged` + `onRestartExhausted` `nonisolated(unsafe)` set-once callbacks.
- `FaeCore`: endpoint change → DaemonEndpointStore.set + TTS reconnect; exhaustion → loud Retry/Quit notification. **HONEST: no automatic post-startup MLX continuity** (PipelineCoordinator holds `private let llmEngine`); initial launch failure still falls back to MLX via start() catch.
- `FaeApp`: Retry/Quit alert (`presentDaemonExhaustionAlert`); `FaeCore.retryDaemonAfterExhausted` re-launches the lane.
- MLX stays as the loud last-resort for INITIAL launch; not removed (per settled decision).

## 2. Decisions ALREADY MADE (don't re-litigate)

- All Phase A decisions (see `bswift-3b-followups-2026-06-30.md` #2 RESOLVED, #4 updated).
- Phase B: post-startup exhaustion is **terminal-until-Retry** (no hot-swap to MLX — immutable PipelineCoordinator.llmEngine). Initial launch failure still falls back to MLX. Honest copy throughout; no false "backup engine" claims.
- MLX kept (net stays while daemon is green); destination = remove after a stable release.

## 3. Work REMAINING (Phase C–F, in priority order)

- **Phase C — Open follow-ups** (`docs/plans/bswift-3b-followups-2026-06-30.md`): #3 hardlinks (st_nlink>1 policy or document as accepted residual), **#4 O_NOFOLLOW/TOCTOU in the DAEMON read path + local ReadTool** (Phase A's LOCAL fallback is now fd-anchored, but the daemon path `confineValidatedReadPath` is still path-based — this is the open HIGH), #5 Swift audit gap for routed reads, #6 truncation parity, #7 concurrent-caller coverage, #9 routed-read error copy UX, #10 root-prompt-before-not-found UX. Mark each RESOLVED in the doc.
- **Phase D — Layer 4 write/edit routing** (`FAE_TOOLHOST_DANGEROUS_TOOLS`): same two-phase confinement + mandatory owner approval (DamageControlPolicy). Lean hard on the red team. write/edit route to daemon `tool.execute_dangerous` with `tool.confirm`; bash stays local.
- **Phase E — Layer 5 integration tests**: all routed tools, escape denial, daemon-down fallback (confined when intended), symlink reject, cancel mid-op, concurrency. Property tests for confinement invariants.
- **Phase F — A4 bundled-app proof + audit row**: `just rebuild` / `just run-native`, run the live scenario in `docs/checklists/app-release-validation.md`, screenshots, audit row.

## 4. Process (unchanged from original mandate)

- Advisor CONTINUALLY: before each phase's first write, whenever stuck, before every merge (commit first, then call), before declaring done. Contradiction → one reconcile call. If advisor context fills up again, open a new session with a fresh handoff (commits + doc persisted first).
- Review sub-agent team at every merge gate: code-review + red-team (adversarial) + Test/QA + advisor final.
- Validation order (all pass before merge): Rust `cargo fmt --all` → `cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used` → `cargo check --workspace --all-targets` → `cargo test --workspace`; Swift `cd native/macos/Fae && swift build && swift test` (target ≥ 3479 passed / 0 failures).
  - **Known Rust baseline exceptions (pre-existing on origin/main, NOT regressions):** `fae-acp` clippy `expect_used` failures are in TEST code (policy-permitted); `fae-acp` `mock_agent` test hangs in the full-workspace run (passes in isolation); `fae-engine` `llamacpp_adapter` 2 tests fail on env-var interference in the full suite (pass in isolation with `FAE_DEV=1`). Confirm any new failure against origin/main before treating as a regression.
- Swift full suite is SLOW (~25–45 min). Run targeted filters first, then kick off the full suite in the background (`nohup swift test > log 2>&1 &`) and poll.
- origin/main is NOT branch-protected — FF push is the merge mechanism.

## 5. Hard guardrails (unchanged)

- Never wrap blocking accept()/recv() in withTimeout.
- Reject ALL absolute paths in routing; confine against the daemon-RETURNED root AFTER ensureDefaultRooted().
- Symlinked root = hard-deny before any provisioning. Mutating tools: confinement + approval both mandatory.
- read is .low/legacy; write/edit never silently fall back.

## 6. Definition of DONE

Phases A–F all shipped; every merge passed Rust+Swift+code-review+red-team+advisor; origin/main
reflects all work; follow-ups doc accurate; final advisor project-complete review. Report:
commit SHAs, final test count, follow-up status table, owner-only decisions + resolutions.

---

**Immediate first action for the fresh session:** call `advisor()` with this handoff's Phase B
section (HEAD `a297382f`, Swift 3495/0, Rust clean, reviewer/red-team PASS) for the final
Phase B merge gate, then FF-merge Phase B and begin Phase C.
