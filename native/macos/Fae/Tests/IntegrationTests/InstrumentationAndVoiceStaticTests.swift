import XCTest
@testable import Fae

/// Coverage for two 0%-covered files: PipelineInstrumentation (pure timing actor
/// — every mark method takes an optional explicit duration, so calling without a
/// configured store is a no-op, not a crash) and VoiceLibrary.sanitizeName (pure
/// static string cleaner — name normalization).
final class InstrumentationAndVoiceStaticTests: XCTestCase {

    // MARK: - PipelineInstrumentation

    func testInstrumentationStartEndNoStoreIsNoop() async {
        // Without configure(store:) the mark calls record nothing but must not crash.
        let instr = PipelineInstrumentation()
        await instr.markTurnStart()
        await instr.markTurnEnd()
        await instr.markSTTStart()
        await instr.markSTTEnd()
        await instr.markLLMStart()
        await instr.markLLMFirstToken()
        await instr.markLLMEnd()
        await instr.markTTSStart()
        await instr.markTTSFirstChunk()
        await instr.markTTSEnd()
        XCTAssertTrue(true) // completed without crash
    }

    func testInstrumentationAcceptsExplicitDurations() async {
        // Explicit durations should be used directly (no crash without store).
        let instr = PipelineInstrumentation()
        await instr.markSTTEnd(durationMs: 120.0)
        await instr.markLLMEnd(durationMs: 500.0, tokenCount: 100)
        await instr.markTTSFirstChunk(latencyMs: 80.0)
        await instr.markTTSEnd(durationMs: 300.0)
        XCTAssertTrue(true)
    }

    func testInstrumentationEndWithoutStartIsGuardedNoop() async {
        // markEnd/markFirst* without a prior start must return early (no crash).
        let instr = PipelineInstrumentation()
        await instr.markTurnEnd()
        await instr.markSTTEnd()
        await instr.markLLMFirstToken()
        await instr.markLLMEnd()
        await instr.markTTSFirstChunk()
        await instr.markTTSEnd()
        XCTAssertTrue(true)
    }

    func testInstrumentationConfigureAcceptsStore() async throws {
        // configure(store:) just stashes the store; verify it doesn't throw.
        let instr = PipelineInstrumentation()
        if let store = try? QualityMetricStore(path: NSTemporaryDirectory() + "qi-\(UUID().uuidString).db") {
            await instr.configure(store: store)
            await instr.markTurnStart()
            await instr.markTurnEnd()
        }
        XCTAssertTrue(true)
    }

    // MARK: - VoiceLibrary.sanitizeName

    func testSanitizeNameLowercasesAndKeepsAlphanumerics() {
        XCTAssertEqual(VoiceLibrary.sanitizeName("My Voice 2"), "my-voice-2")
    }

    func testSanitizeNameReplacesNonAlphanumericWithDash() {
        // Runs of disallowed chars collapse to a single dash.
        XCTAssertEqual(VoiceLibrary.sanitizeName("a!@#b$%^c"), "a-b-c")
    }

    func testSanitizeNamePreservesHyphenAndUnderscore() {
        XCTAssertEqual(VoiceLibrary.sanitizeName("Test-Name_1"), "test-name_1")
    }

    func testSanitizeNameEmptyBecomesUnnamed() {
        XCTAssertEqual(VoiceLibrary.sanitizeName(""), "unnamed")
    }

    func testSanitizeNameOnlySymbolsBecomesUnnamed() {
        // All-symbol input collapses to empty -> "unnamed".
        XCTAssertEqual(VoiceLibrary.sanitizeName("!@#$%"), "unnamed")
    }
}
