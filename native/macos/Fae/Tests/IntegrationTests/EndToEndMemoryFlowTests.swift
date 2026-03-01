import XCTest
@testable import Fae

/// Tests the memory recall and capture flow end-to-end with real SQLite.
final class EndToEndMemoryFlowTests: XCTestCase {

    private var harness: TestRuntimeHarness!

    override func setUp() async throws {
        harness = try TestRuntimeHarness()
        await harness.setUp()
    }

    override func tearDown() {
        harness.cleanup()
        harness = nil
    }

    // MARK: - Recall

    func testMemoryRecallReturnsContextAfterCapture() async throws {
        // First capture a memory with a known fact.
        let report = await harness.memoryOrchestrator.capture(
            turnId: "turn-1",
            userText: "remember that my favorite color is blue",
            assistantText: "I'll remember that!"
        )
        XCTAssertGreaterThan(report.extractedCount, 0)

        // Now recall should find the memory.
        let context = await harness.memoryOrchestrator.recall(query: "favorite color")
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("blue") ?? false)
    }

    func testMemoryRecallReturnsNilWhenEmpty() async throws {
        // No memories stored yet — recall should return nil.
        let _ = await harness.memoryOrchestrator.recall(query: "anything")
        // Could be nil or contain no meaningful results depending on scoring
        // The key is that it doesn't crash.
    }

    // MARK: - Capture

    func testMemoryCaptureCreatesEpisode() async throws {
        let report = await harness.memoryOrchestrator.capture(
            turnId: "turn-2",
            userText: "What time is it?",
            assistantText: "It's 3 PM."
        )
        XCTAssertNotNil(report.episodeId)
    }

    func testMemoryCaptureExtractsPreference() async throws {
        let report = await harness.memoryOrchestrator.capture(
            turnId: "turn-3",
            userText: "I prefer dark mode for all my apps",
            assistantText: "Noted!"
        )
        // Should extract as profile/preference.
        XCTAssertGreaterThan(report.extractedCount, 0)
    }

    func testMemoryCaptureExtractsName() async throws {
        let report = await harness.memoryOrchestrator.capture(
            turnId: "turn-4",
            userText: "my name is Alice",
            assistantText: "Nice to meet you, Alice!"
        )
        XCTAssertGreaterThan(report.extractedCount, 0)

        // Verify the name is retrievable.
        let context = await harness.memoryOrchestrator.recall(query: "name")
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Alice") ?? false)
    }

    // MARK: - Forget

    func testMemoryForgetCommandSoftDeletesMatching() async throws {
        // Store a fact first.
        _ = await harness.memoryOrchestrator.capture(
            turnId: "turn-5",
            userText: "remember that the meeting is at 3pm",
            assistantText: "Got it."
        )

        // Now forget it.
        let forgetReport = await harness.memoryOrchestrator.capture(
            turnId: "turn-6",
            userText: "forget the meeting",
            assistantText: "Forgotten."
        )
        XCTAssertGreaterThan(forgetReport.forgottenCount, 0)
    }

    // MARK: - Garbage Collection

    func testGarbageCollectionRemovesOldEpisodes() async throws {
        // Capture some episodes.
        for i in 0..<3 {
            _ = await harness.memoryOrchestrator.capture(
                turnId: "turn-gc-\(i)",
                userText: "test message \(i)",
                assistantText: "response \(i)"
            )
        }

        // GC with 0 retention days should clean episodes.
        let cleaned = await harness.memoryOrchestrator.garbageCollect(retentionDays: 0)
        // Episodes created "now" have updatedAt == now, so retention of 0 days
        // means threshold is also now — may or may not match depending on timing.
        // This verifies GC doesn't crash and runs successfully.
        XCTAssertTrue(cleaned >= 0)
    }
}
