# Task #10 — Orb Thinking liveness

Date: 2026-06-14 local / 2026-06-13 UTC
Branch: `task10-thinking-liveness`

## 1. What changed

```text
docs/CHANGELOG.md                                  |   7 +
docs/architecture/s18-kill-list-3of3-plan.md       |   9 +-
.../reports/task10-thinking-liveness-2026-06-14.md | 153 +++++++++++++++++++++
.../Fae/Pipeline/AssistantGenerationTracker.swift  |  59 ++++++++
.../Sources/Fae/Pipeline/PipelineCoordinator.swift | 143 +++++++++++++------
.../AssistantGenerationTrackerTests.swift          |  93 +++++++++++++
6 files changed, 421 insertions(+), 43 deletions(-)
```

Summary:

- Added `AssistantGenerationTracker` to separate token-stream liveness from the user-visible orb Thinking indicator.
- Silent proactive/awareness generations remain tracked and can be superseded, but they do not emit `assistantGenerating(true)`.
- Ending a stale generation now removes only that generation; it cannot clear a newer visible one, but quiescence forces the indicator idle when no visible generation or approval pause remains.
- Proactive awareness drains now check active tracked generations, not just the UI Thinking flag, so overlapping camera/screen chores defer instead of superseding each other.
- Deliberate user turns still supersede silent background generations.
- Added regression tests for overlapping silent proactive generations, visible overlap guard semantics, no resurrection of superseded older generations, visible+silent quiescence, and awaiting-approval liveness.

## 2. Validation

### `cd native/macos/Fae && swift test --filter AssistantGenerationTrackerTests`

```text
Test Suite 'AssistantGenerationTrackerTests' passed at 2026-06-14 00:55:49.528.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.004 (0.004) seconds
Test Suite 'Selected tests' passed at 2026-06-14 00:55:49.528.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
```

### `cd native/macos/Fae && swift test --filter RuntimeContractTests`

```text
Test Suite 'RuntimeContractTests' passed at 2026-06-14 00:11:03.007.
	 Executed 22 tests, with 0 failures (0 unexpected) in 3.751 (3.754) seconds
Test Suite 'Selected tests' passed at 2026-06-14 00:11:03.008.
	 Executed 22 tests, with 0 failures (0 unexpected) in 3.751 (3.754) seconds
```

### `cd native/macos/Fae && swift build`

```text
Build complete! (2.04s)
```

Known warnings were unchanged SwiftPM resource/exclude warnings for missing Metal source files and unhandled `Resources/VERSION`.

### `cd native/macos/Fae && swift test --skip VocabularyHarvestTests`

```text
Test Suite 'FaePackageTests.xctest' passed at 2026-06-14 00:58:06.780.
	 Executed 3093 tests, with 0 failures (0 unexpected) in 120.960 (121.127) seconds
Test Suite 'Selected tests' passed at 2026-06-14 00:58:06.780.
	 Executed 3093 tests, with 0 failures (0 unexpected) in 120.960 (121.128) seconds
```

### `just check`

Attempted and timed out after 30 minutes in the pre-existing Contacts/CoreData XPC/TCC path inside `VocabularyHarvestTests`:

```text
2026-06-14 00:36:15.848 xctest[15276:28981803] VocabularyHarvester: calendar permission not granted (status=0)
Test Case '-[IntegrationTests.VocabularyHarvestTests testHarvestDeduplicates]' passed (1204.554 seconds).
Test Case '-[IntegrationTests.VocabularyHarvestTests testHarvestIntoEmptyLexicon]' started.
CoreData: error: Failed to create NSXPCConnection
CoreData: XPC: Unable to load metadata: Error Domain=NSCocoaErrorDomain Code=134060 "A Core Data error occurred." UserInfo={Problem=Unable to send to server; failed after 8 attempts.}
Command timed out after 1800 seconds
```

This is the known local TCC/AddressBook validation blocker; the skipped full Swift suite above is the established local substitute.

### `cd crates && just check`

```text
Doc-tests fae_engine

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

All Rust crate unit/doc tests passed.

### `just check-ui-shell`

```text
cd native/rust/fae-ui-shell && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.20s
warning: the following packages contain code that will be rejected by a future version of Rust: block v0.1.6
cd native/rust/fae-ui-shell && cargo check --workspace --all-targets
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.10s
```

The `block v0.1.6` future-incompat warning is pre-existing.

## 3. Live evidence

Ran `just run-dev` after temporarily enabling dev awareness consent and short intervals in `~/Library/Application Support/fae-dev/config.toml` (restored afterwards). The app launched with the Rust orb shell and embedded daemon:

```text
✓ Bundle assembled: native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app (v0.8.189)
  → Embedded fae-ui-shell
  → Embedded fae-daemon
✓ Signed: native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app
native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app: valid on disk
native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app: satisfies its Designated Requirement
✓ Fae (DEV) launched — logs: tail -f /tmp/fae-dev.log
```

Then relaunched the same dev bundle with `--test-server` so the conversation/orb generation state could be polled while awareness ran. `/health` reached `{"pipeline":"running","status":"ok"}`.

Awareness tasks started and camera checks ran as silent proactive work:

```text
2026-06-14 01:07:49.293 Fae[15186:29153742] FaeScheduler: awareness tasks started (camera=on, screen=on)
2026-06-14 01:07:54.323 Fae[15186:29153746] FaeScheduler: camera_presence_check dispatching (mode=digest, silent=yes, consent=yes)
2026-06-14 01:08:22.385 Fae[15186:29153742] PipelineCoordinator: executing tool 'camera'
2026-06-14 01:08:29.394 Fae[15186:29153733] FaeScheduler: camera_presence_check dispatching (mode=digest, silent=yes, consent=yes)
2026-06-14 01:08:29.394 Fae[15186:29153733] PipelineCoordinator: proactive query deferred — assistant busy
2026-06-14 01:10:52.617Z Pipeline Proactive query: taskId=camera_presence_check silent=true
2026-06-14 01:10:52.619Z Pipeline Generation started id=4C1DA211
2026-06-14 01:11:17.334Z Tool id=EB279072 name=camera args={"prompt":"Observe the environment remotely"}
2026-06-14 01:11:19.840Z Tool Tool finished: camera success=true latency=2441ms
```

While those silent awareness generations and deferred camera jobs were active, the conversation endpoint stayed idle; this is the orb/pill-facing state used by the UI bridge:

```text
polls ts isGenerating isSpeaking background pipeline
01:08:03 False False False running
01:08:28 False False False running
01:09:03 False False False running
01:09:28 False False False running
01:09:47 False False False running
01:10:27 False False False running
01:11:42 False False False running
```

This proves the live behavior behind the fix: silent awareness jobs are still live/tracked (`assistant busy` defers overlapping camera jobs), camera tools complete, and the user-visible generation state returns/remains idle instead of stranding the orb/pill in Thinking. Direct screenshot capture was unavailable in this agent harness (`screencapture` failed with `could not create image from display`), so the proof uses the dev test-server conversation state plus runtime logs.

## 4. Deviations

- The original compacted instruction said "task 10"; an earlier pass mistakenly interpreted it as PR #10. This report covers the clarified Task #10 Thinking-liveness bug.
- The S18 plan previously listed Task #10 as test isolation. The user clarified Task #10 as the orb Thinking liveness issue; the plan now records that clarification and leaves test isolation as future CI debt.
- No flat liveness timeout was added. The fix is state-based and preserves token/tool activity for long real turns.

## 5. Known gaps / follow-ups

- Direct screenshot capture failed in this harness, but the dev test-server conversation state stayed idle during live awareness generations.
- Root `just check` still needs the separate VocabularyHarvest/Contacts test-isolation fix to avoid the local TCC/CoreData XPC timeout.

## 6. Docs touched + Obsidian notes updated

Docs touched:

- `docs/CHANGELOG.md`
- `docs/architecture/s18-kill-list-3of3-plan.md`
- `docs/reports/task10-thinking-liveness-2026-06-14.md`

Obsidian mirrors updated after this report was written.
