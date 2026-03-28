# Phase 1.5: Full Test Suite

## Overview

Add 30 tests across 5 new test files covering the complete Invisible Permissions milestone.
Also adds MockReceiptStore, MockReceiptCapturingTool, and extends TestRuntimeHarness.

## Task 1: Add MockReceiptStore + MockReceiptCapturingTool to TestDoubles.swift

Files: `native/macos/Fae/Tests/IntegrationTests/Harness/TestDoubles.swift`
- Add `MockReceiptStore` actor with in-memory storage (no SQLite)
- Add `MockReceiptCapturingTool` struct that calls receiptStore.createReceipt after execution
- Track: receiptsCreated, undoCallCount, lastReceiptId

## Task 2: Extend TestRuntimeHarness with receiptStore

Files: `native/macos/Fae/Tests/IntegrationTests/Harness/TestRuntimeHarness.swift`
- Add `receiptStore: ReceiptStore` property (real GRDB-backed, using tmpDir/receipts.db)
- Init receiptStore in init()
- Expose helper: `func makeBroker(isOwner: Bool) -> DefaultTrustedActionBroker`

## Task 3: EndToEndOwnerSilentModeTests (tests 1-5: broker decisions)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndOwnerSilentModeTests.swift`
- testOwnerFullyReversibleAction_SkipsConfirmation
- testOwnerPartiallyReversibleAction_AllowsWithNarration
- testOwnerIrreversibleAction_RequiresCountdown
- testGuestFullyReversibleAction_UsesVoiceIdentityPath
- testDamageControlStillFiresForOwner

## Task 4: EndToEndOwnerSilentModeTests (tests 6-10: receipt creation)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndOwnerSilentModeTests.swift`
- testFileWriteCreatesReceipt
- testCalendarCreateCreatesReceipt
- testNewFileReceiptHasNoPreState
- testReadToolCreatesNoReceipt
- testReceiptCreationFailureDoesNotBlockTool

## Task 5: EndToEndOwnerSilentModeTests (tests 11-15: undo)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndOwnerSilentModeTests.swift`
- testUndoRestoresFileFromReceipt
- testUndoNewFileRemovesIt
- testUndoAlreadyUndoneReceipt_ReturnsError
- testUndoExpiredReceipt_FallsBackToVault (TTL already elapsed -> error)
- testUndoExpiredReceipt_NoVault_ReturnsError

## Task 6: EndToEndBashReversibilityTests (5 tests)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndBashReversibilityTests.swift`
- testEchoRedirectClassifiedAsReversible
- testMkdirClassifiedAsReversible
- testRmClassifiedAsIrreversible
- testCurlPipeBashClassifiedAsIrreversible
- testEmptyCommandClassifiedAsIrreversible

## Task 7: EndToEndNarrationAndBargeInTests (5 tests)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndNarrationAndBargeInTests.swift`
- testNarrationAfterFileWrite
- testNoNarrationForReadTool
- testBargeInDuringNarration_OffersUndo
- testBargeInUndoConfirmed_RestoresFile
- testBargeInUndoDeclined_ContinuesNormally

## Task 8: EndToEndIrreversibleCountdownTests (3 tests)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndIrreversibleCountdownTests.swift`
- testMailSendShowsCountdown
- testBargeInDuringCountdown_CancelsAction
- testCountdownCompletes_ActionExecutes

## Task 9: EndToEndBatchUndoTests (2 tests)

File: `native/macos/Fae/Tests/IntegrationTests/EndToEndBatchUndoTests.swift`
- testBatchUndoReverseChronological
- testBatchUndoPartialFailure_ContinuesAndReports

## Task 10: Build + full test suite verification

Run `cd native/macos/Fae && swift build && swift test` — all 30 new tests + existing suite must pass.
