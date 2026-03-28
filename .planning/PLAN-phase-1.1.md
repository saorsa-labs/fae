# Phase 1.1: Prerequisites

## Task 1: Update SOUL.md narration clause
**Files:** `native/macos/Fae/Sources/Fae/Resources/SOUL.md`
**Spec:** In the `## Tools` section (after the existing bullet about confirming outcomes), add a clause about narration-as-transparency for the owner: "When acting on the owner's behalf for reversible actions, she narrates briefly after completion — not as a request for approval, but as quiet transparency. The owner can always say 'undo that' to reverse the action." Remove or soften the "always confirms before" language that implies pre-action approval popups. Keep the irreversible-action clause ("never does something irreversible without being clearly asked").
**Tests:** None (resource file).
**Done when:** SOUL.md reflects narrate-after-act model for reversible actions while preserving the irreversible-action gate.

## Task 2: Update HEARTBEAT.md invisible permissions
**Files:** `native/macos/Fae/Sources/Fae/Resources/HEARTBEAT.md`
**Spec:** Replace or update the `## Progressive Permissions` section (lines 24-32) with an "Invisible Permissions" section. Describe: owner voice identity auto-approves all reversible actions, narration is the disclosure mechanism (not confirmation), action receipts provide undo capability, only DamageControlPolicy disaster/confirmManual operations get hard gates. Keep it concise (10-15 lines).
**Tests:** None (resource file).
**Done when:** HEARTBEAT.md reflects invisible permissions model.

## Task 3: Add speakerId to ActionIntent and ToolExecutorContext
**Files:** `native/macos/Fae/Sources/Fae/Tools/TrustedActionBroker.swift`, `native/macos/Fae/Sources/Fae/Tools/ToolExecutorContext.swift`
**Spec:** Add `let speakerId: String?` to ActionIntent struct (after `livenessScore` at line 21). Add default `nil` value in init. Add `let speakerId: String?` to ToolExecutorContext (after `livenessScore` at line 31). Update both factory methods (`coworkExternal`, `restrictedFallback`) with `speakerId: nil`. This is plumbing for Phase 2 trust envelopes — not used in broker evaluation yet.
**Tests:** Existing tests must still compile. No new tests needed (additive field with default).
**Done when:** Both structs have speakerId, all call sites compile, `just check` passes.

## Task 4: Wire speakerId from PipelineCoordinator to ToolExecutor
**Files:** `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`, `native/macos/Fae/Sources/Fae/Tools/ToolExecutor.swift`
**Spec:** In PipelineCoordinator where ToolExecutorContext is constructed (search for `ToolExecutorContext(` in the file), populate `speakerId` from the current speaker profile. The pipeline already has `speakerGateState` which contains the current speaker's profile ID. Pass `speakerGateState.currentSpeakerId` (or equivalent) as `speakerId`. In ToolExecutor where ActionIntent is built from context (~line 259), pass `context.speakerId` through.
**Tests:** Existing tests must pass. No new behavior to test yet.
**Done when:** speakerId flows from speaker gate state through context to ActionIntent, `just check` passes.

## Task 5: Add receiptsFile path to FaeDirectories
**Files:** `native/macos/Fae/Sources/Fae/Core/FaeEnvironment.swift`
**Spec:** Add `static let receiptsFile: URL = root.appendingPathComponent("receipts.db")` to FaeDirectories, following the pattern of existing path declarations (after `recoveryDirectory` or similar). This is the path for the separate receipts.db database.
**Tests:** None needed (static path declaration).
**Done when:** `FaeDirectories.receiptsFile` exists and resolves to `~/Library/Application Support/fae/receipts.db`, `just check` passes.
