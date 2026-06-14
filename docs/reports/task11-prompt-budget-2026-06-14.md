# Task #11 — Fae prompt budget

Date: 2026-06-14 local / 2026-06-14 UTC
Branch: `fae-prompt-budget`
Scope: Lever 1 from `docs/plans/fae-prompt-budget-2026-06-13.md` — native progressive tool disclosure + prompt-budget metrics. Prefix cache and memory recall byte-budgeting remain follow-ups.

## 1. What changed

```text
docs/CHANGELOG.md                                  |   7 +
docs/plans/fae-prompt-budget-2026-06-13.md         | 107 +++++++++++++
docs/reports/task11-prompt-budget-2026-06-14.md    | 168 +++++++++++++++++++++
.../macos/Fae/Sources/Fae/ML/DaemonLLMEngine.swift |  61 ++++++++
.../Sources/Fae/Pipeline/PipelineCoordinator.swift |  35 ++++-
.../Fae/Sources/Fae/Pipeline/TurnHelpers.swift     |  74 ++++++++-
.../macos/Fae/Sources/Fae/Tools/ToolRegistry.swift |  12 +-
.../IntegrationTests/DaemonLLMEngineTests.swift    |  84 +++++++++++
.../Tests/IntegrationTests/TurnHelpersTests.swift  |  92 +++++++++++
9 files changed, 628 insertions(+), 12 deletions(-)
```

Summary:

- Added progressive native tool disclosure: full JSON schemas are sent only for a conservative per-turn working set, while the prompt carries a compact allowed-tool index.
- Long-tail tools expand into full schemas when explicitly mentioned or inferred from user intent; proactive allowlists stay narrow and keep their compact index aligned with callable schemas.
- Conversation continuations with ambiguous text preserve the old all-schema behavior to avoid breaking short follow-ups like “yes, use that”.
- Added daemon prompt-budget metrics logging before every `conversation.inject_text` request.
- Added tests for generic working-set reduction, long-tail expansion, proactive narrowing, strict-local filtering, continuation preservation, and zero-tool metrics.

## 2. Validation

### `cd native/macos/Fae && swift test --filter TurnHelpersTests`

```text
Test Suite 'TurnHelpersTests' passed at 2026-06-14 08:53:55.035.
	 Executed 60 tests, with 0 failures (0 unexpected) in 0.009 (0.012) seconds
Test Suite 'Selected tests' passed at 2026-06-14 08:53:55.035.
	 Executed 60 tests, with 0 failures (0 unexpected) in 0.009 (0.013) seconds
```

### `cd native/macos/Fae && swift test --filter DaemonWireTests`

```text
2026-06-14 08:53:55.998 xctest[99005:30268973] PromptBudgetTest: generic all_tools=36 all_tool_tokens=5570 working_tools=15 working_tool_tokens=2665 reduction_tokens=2905
Test Suite 'DaemonWireTests' passed at 2026-06-14 08:53:55.999.
	 Executed 21 tests, with 0 failures (0 unexpected) in 0.007 (0.008) seconds
Test Suite 'Selected tests' passed at 2026-06-14 08:27:08.704.
	 Executed 21 tests, with 0 failures (0 unexpected) in 0.007 (0.009) seconds
```

### `cd native/macos/Fae && swift test --filter RuntimeContractTests`

```text
Test Suite 'RuntimeContractTests' passed at 2026-06-14 08:54:00.713.
	 Executed 22 tests, with 0 failures (0 unexpected) in 3.754 (3.756) seconds
Test Suite 'Selected tests' passed at 2026-06-14 08:54:00.714.
	 Executed 22 tests, with 0 failures (0 unexpected) in 3.754 (3.757) seconds
```

### `cd native/macos/Fae && swift test --skip VocabularyHarvestTests`

```text
Test Suite 'FaePackageTests.xctest' passed at 2026-06-14 08:56:11.327.
	 Executed 3103 tests, with 0 failures (0 unexpected) in 120.653 (120.823) seconds
Test Suite 'Selected tests' passed at 2026-06-14 08:56:11.327.
	 Executed 3103 tests, with 0 failures (0 unexpected) in 120.653 (120.824) seconds
```

### `cd crates && just check`

```text
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 5.87s
cargo test --all-features
...
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

### `just check-ui-shell`

```text
cd native/rust/fae-ui-shell && cargo fmt --all
cd native/rust/fae-ui-shell && cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.18s
cd native/rust/fae-ui-shell && cargo check --workspace --all-targets
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.09s
```

The `block v0.1.6` future-incompat warning is pre-existing.

## 3. Live evidence

Built and launched the dev bundle with embedded `fae-ui-shell` and `fae-daemon`:

```text
✓ Bundle assembled: native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app (v0.8.189)
  → Embedded fae-ui-shell
  → Embedded fae-daemon
✓ Signed: native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app
native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app: valid on disk
native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app: satisfies its Designated Requirement
✓ Fae (DEV) launched — logs: tail -f /tmp/fae-dev.log
```

Relaunched the same bundle with `--test-server`; `/health` reached:

```text
{"pipeline":"running","status":"ok"}
```

Injected a simple no-tool turn:

```text
inject: {"injected":"say ok in one short sentence","ok":true,"turn_id":"E8ECF417-0C7B-4133-BAD9-2437D685EDB3"}
```

Runtime events for the injected turn:

```text
26 2026-06-14T07:28:35.092Z QA === TURN START user=say ok in one short sentence ===
29 2026-06-14T07:28:35.192Z Pipeline Tool disclosure: index=36 full_schemas=15
37 2026-06-14T07:28:51.697Z Pipeline LLM done: 1 tokens total=16.5s first_token=16.5s decode=0.0s decode_tps=1000.0
40 2026-06-14T07:28:51.697Z QA Model raw response preview: Ok.
```

No `Found tool call` / `Tool id=` events occurred for the injected user turn. The daemon logged prompt-budget metrics for that request:

```text
2026-06-14 08:28:35.225 Fae[54869:30187412] DaemonLLMEngine: prompt_budget request=r3 estimated_text_tokens=10370 payload_bytes=42358 system_tokens=7552 message_tokens=153 tools=15 tool_tokens=2665 tool_bytes=10658
```

The same run also showed startup proactive work using the narrowed allowlist path:

```text
2026-06-14T07:28:18.209Z Pipeline Tool disclosure: index=6 full_schemas=1
2026-06-14 08:28:18.282 Fae[54869:30187184] DaemonLLMEngine: prompt_budget request=r2 estimated_text_tokens=7337 payload_bytes=30205 system_tokens=7037 message_tokens=228 tools=1 tool_tokens=72 tool_bytes=287
```

Test-side before/after metric for a generic turn, using all full schemas as the pre-change baseline:

```text
PromptBudgetTest: generic all_tools=36 all_tool_tokens=5570 working_tools=15 working_tool_tokens=2665 reduction_tokens=2905
```

The app was killed after verification.

## 4. Deviations / scope

- Implemented Lever 1 only. Lever 2 (memory recall token/byte budgeting) and Lever 3 (prefix cache re-enable) are left for separate PRs because prefix caching is explicitly high-risk for audio turns.
- The compact index still lists all allowed tools for ordinary user turns, but full callable schemas are reduced to the working set. Conversation continuations preserve all schemas when intent is ambiguous to avoid regressing follow-up turns.
- Root `just check` was not claimed green; local full Swift test remains blocked by the known `VocabularyHarvestTests` Contacts/CoreData/TCC path. The established local substitute, `swift test --skip VocabularyHarvestTests`, passed.

## 5. Known gaps / follow-ups

- Add Lever 2: hard budget for memory recall injection.
- Add Lever 3 behind a flag: prefix cache for safe text/tool prefixes only, with explicit audio-turn regression proof.
- Add a FaeBenchmark tool-call score gate before broader prompt-budget changes.

## 6. Docs touched + Obsidian notes

Docs touched:

- `docs/CHANGELOG.md`
- `docs/plans/fae-prompt-budget-2026-06-13.md`
- `docs/reports/task11-prompt-budget-2026-06-14.md`

Obsidian mirrors updated after this report was written.
