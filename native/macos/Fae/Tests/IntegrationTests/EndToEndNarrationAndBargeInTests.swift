import Foundation
import XCTest
@testable import Fae

/// Tests for post-action narration and barge-in undo flow.
///
/// These tests exercise the narration text builder and reversibility classification
/// that drives the narration decision in ToolExecutor (step 17). Since the actual
/// TTS playback requires a running PipelineCoordinator, we test the decision logic
/// and text generation directly.
final class EndToEndNarrationAndBargeInTests: XCTestCase {

    private var harness: TestRuntimeHarness!

    override func setUp() async throws {
        harness = try TestRuntimeHarness()
        await harness.setUp()
    }

    override func tearDown() {
        harness.cleanup()
        harness = nil
    }

    // MARK: - Narration Text Tests

    /// Write tool completes → buildNarrationText returns a non-nil string.
    func testNarrationAfterFileWrite() throws {
        let text = ToolExecutor.buildNarrationText(
            toolName: "write",
            arguments: ["path": "/tmp/report.txt"]
        )
        XCTAssertNotNil(text, "Write tool should have narration text")
        XCTAssertTrue(text?.contains("report.txt") == true,
            "Narration should mention the filename")
    }

    /// Read tool completes → no narration (reversibility is .notApplicable).
    func testNoNarrationForReadTool() throws {
        let reversibility = ActionReversibility.classify(
            toolName: "read",
            arguments: ["path": "/tmp/notes.txt"]
        )
        XCTAssertEqual(reversibility, .notApplicable,
            "read is read-only and should never trigger narration")

        // In ToolExecutor step 17: narration guard is `reversibility != .notApplicable`.
        // Verify the guard condition is false for read.
        XCTAssertFalse(reversibility != .notApplicable,
            "Narration guard should be false for read tool")
    }

    /// Barge-in during narration should offer undo: verify the narration receipt tagging
    /// concept by confirming the ReceiptStore creates a valid receipt for the write tool
    /// that could be used as the narrationReceiptId.
    func testBargeInDuringNarration_OffersUndo() async throws {
        let testFile = harness.tmpDir.appendingPathComponent("narration_test.txt")
        try "original".write(to: testFile, atomically: true, encoding: .utf8)

        let store = harness.receiptStore
        let preState = store.capturePreStateForTool(
            toolName: "write",
            arguments: ["path": testFile.path]
        )
        try "updated".write(to: testFile, atomically: true, encoding: .utf8)

        // Simulate what ToolExecutor does at step 16: create receipt after successful execution.
        let receiptId = await store.createReceipt(
            toolName: "write",
            arguments: ["path": testFile.path],
            preState: preState,
            speakerId: "owner-1",
            sessionId: nil,
            turnId: nil
        )
        XCTAssertNotNil(receiptId, "Receipt ID must be set for barge-in undo to work")

        // The narrationReceiptId is what ToolExecutorDelegate.toolExecutorNarrateAction
        // receives. It's tagged so barge-in can undo the correct receipt.
        // Verify that the receipt is undoable.
        let undoResult = await store.undo(receiptId: receiptId!)
        if case .success = undoResult {
            let restored = try String(contentsOf: testFile, encoding: .utf8)
            XCTAssertEqual(restored, "original", "Barge-in undo should restore original content")
        } else {
            XCTFail("Narration receipt should be undoable: \(undoResult)")
        }
    }

    /// Barge-in undo confirmed → file is restored to pre-write content.
    func testBargeInUndoConfirmed_RestoresFile() async throws {
        let testFile = harness.tmpDir.appendingPathComponent("barge_undo_confirm.txt")
        let originalContent = "before barge-in undo"
        try originalContent.write(to: testFile, atomically: true, encoding: .utf8)

        let store = harness.receiptStore
        let preState = store.capturePreStateForTool(
            toolName: "write",
            arguments: ["path": testFile.path]
        )

        // Tool executes — overwrites file.
        try "after write".write(to: testFile, atomically: true, encoding: .utf8)

        let receiptId = await store.createReceipt(
            toolName: "write",
            arguments: ["path": testFile.path],
            preState: preState,
            speakerId: "owner-1",
            sessionId: nil,
            turnId: nil
        )
        guard let rid = receiptId else {
            XCTFail("Receipt must be created")
            return
        }

        // User confirms undo ("yes") during narration.
        let result = await store.undo(receiptId: rid)
        if case .failure(let err) = result {
            XCTFail("Confirmed undo should succeed, got: \(err)")
        }

        let content = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertEqual(content, originalContent, "File must be restored to original")
    }

    /// Barge-in undo declined → no change to file, receipt stays not-undone.
    func testBargeInUndoDeclined_ContinuesNormally() async throws {
        let testFile = harness.tmpDir.appendingPathComponent("barge_undo_decline.txt")
        try "original".write(to: testFile, atomically: true, encoding: .utf8)

        let store = harness.receiptStore
        let preState = store.capturePreStateForTool(
            toolName: "write",
            arguments: ["path": testFile.path]
        )

        try "new content".write(to: testFile, atomically: true, encoding: .utf8)

        let receiptId = await store.createReceipt(
            toolName: "write",
            arguments: ["path": testFile.path],
            preState: preState,
            speakerId: "owner-1",
            sessionId: nil,
            turnId: nil
        )
        guard let rid = receiptId else {
            XCTFail("Receipt must be created")
            return
        }

        // User declines undo ("no") — we simply do NOT call store.undo.
        // Verify file unchanged and receipt not undone.
        let content = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertEqual(content, "new content", "File should stay as-is when undo declined")

        // Verify receipt exists and is not undone (query without speakerId to avoid SQL edge cases).
        let receipts = await store.recentReceipts(speakerId: nil, limit: 5)
        XCTAssertEqual(receipts.first?.id, rid)
        XCTAssertNil(receipts.first?.undoneAt, "Receipt should not be undone when user declined")
    }

    // MARK: - Narration Text Coverage

    /// Edit tool narration includes filename.
    func testNarrationTextForEdit() {
        let text = ToolExecutor.buildNarrationText(
            toolName: "edit",
            arguments: ["path": "/home/user/notes.md"]
        )
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("notes.md") == true)
    }

    /// Calendar create narration.
    func testNarrationTextForCalendarCreate() {
        let text = ToolExecutor.buildNarrationText(
            toolName: "calendar",
            arguments: ["action": "create"]
        )
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("calendar") == true)
    }

    /// Read-only tools return nil narration.
    func testNarrationNilForReadOnlyTools() {
        for tool in ["read", "web_search", "screenshot", "fetch_url"] {
            let text = ToolExecutor.buildNarrationText(toolName: tool, arguments: [:])
            XCTAssertNil(text, "\(tool) should return nil narration (read-only)")
        }
    }
}
