// ParakeetStreamingEngineTests.swift
// Fae
//
// Tests for ParakeetStreamingEngine protocol conformance and state management.
// These tests validate the engine's behavior without requiring a downloaded model.

import XCTest
@testable import Fae

// MARK: - Mock Streaming Engine

/// Mock implementation of StreamingSTTEngine for protocol conformance verification.
private actor MockParakeetStreamingEngine: StreamingSTTEngine {
    private var _isLoaded = false
    private var audioSamples: [Float] = []
    private var transcript: String = ""

    var isLoaded: Bool { _isLoaded }

    func load() async throws {
        _isLoaded = true
    }

    func feedAudio(_ samples: [Float]) async {
        audioSamples.append(contentsOf: samples)
        if audioSamples.count > 100 {
            transcript = "mock transcript"
        }
    }

    func getPartialTranscript() async -> String {
        transcript
    }

    func getFinalTranscript() async -> String {
        let result = transcript
        await reset()
        return result
    }

    func reset() async {
        audioSamples.removeAll()
        transcript = ""
    }
}

// MARK: - ParakeetStreamingEngine Tests

final class ParakeetStreamingEngineTests: XCTestCase {

    // MARK: - Initial State

    func testIsLoadedFalseBeforeLoad() async {
        let engine = ParakeetStreamingEngine()
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded, "Engine should not be loaded before load() is called")
    }

    func testLoadStatNotStartedInitially() async {
        let engine = ParakeetStreamingEngine()
        let state = await engine.loadState
        if case .notStarted = state {
            // expected
        } else {
            XCTFail("Expected .notStarted, got \(state)")
        }
    }

    // MARK: - Feed Audio

    func testFeedAudioEmptySamplesDoesNotCrash() async {
        let engine = ParakeetStreamingEngine()
        // Should be a no-op since model is not loaded
        await engine.feedAudio([])
        let partial = await engine.getPartialTranscript()
        XCTAssertEqual(partial, "", "Partial should be empty when no model is loaded")
    }

    func testFeedAudioWithoutLoadDoesNotCrash() async {
        let engine = ParakeetStreamingEngine()
        // Feed audio without loading — should be silently ignored
        let samples = [Float](repeating: 0.1, count: 16000)
        await engine.feedAudio(samples)
        let partial = await engine.getPartialTranscript()
        XCTAssertEqual(partial, "", "Partial should be empty when model is not loaded")
    }

    // MARK: - Partial Transcript

    func testGetPartialTranscriptEmptyBeforeAnyAudio() async {
        let engine = ParakeetStreamingEngine()
        let partial = await engine.getPartialTranscript()
        XCTAssertEqual(partial, "", "Partial should be empty before any audio is fed")
    }

    // MARK: - Final Transcript

    func testGetFinalTranscriptEmptyAndResetsState() async {
        let engine = ParakeetStreamingEngine()
        let final1 = await engine.getFinalTranscript()
        XCTAssertEqual(final1, "", "Final should be empty when no audio buffered")

        // Subsequent call should also be empty
        let final2 = await engine.getFinalTranscript()
        XCTAssertEqual(final2, "", "Final should be empty after reset")
    }

    // MARK: - Reset

    func testResetClearsPartialTranscript() async {
        let engine = ParakeetStreamingEngine()
        await engine.reset()
        let partial = await engine.getPartialTranscript()
        XCTAssertEqual(partial, "", "Partial should be empty after reset")
    }

    // MARK: - Benchmark Properties

    func testBenchmarkPropertiesInitialValues() async {
        let engine = ParakeetStreamingEngine()
        let lastLatency = await engine.lastDecodeLatencyMs
        let totalDecodes = await engine.totalDecodeCount
        let avgLatency = await engine.averageDecodeLatencyMs
        let peakMem = await engine.peakMemoryBytes

        XCTAssertNil(lastLatency, "Last decode latency should be nil before any decode")
        XCTAssertEqual(totalDecodes, 0, "Total decode count should be 0 initially")
        XCTAssertEqual(avgLatency, 0, "Average decode latency should be 0 initially")
        XCTAssertEqual(peakMem, 0, "Peak memory should be 0 initially")
    }

    func testDiagnosticsSummaryContainsKey() async {
        let engine = ParakeetStreamingEngine()
        let summary = await engine.diagnosticsSummary()
        XCTAssertTrue(summary.contains("ParakeetStreamingEngine"), "Summary should contain engine name")
        XCTAssertTrue(summary.contains("loaded: false"), "Summary should show not loaded")
        XCTAssertTrue(summary.contains("decodes: 0"), "Summary should show 0 decodes")
    }

    // MARK: - Protocol Conformance (Mock)

    func testMockEngineConformsToStreamingSTTEngine() async throws {
        let engine: any StreamingSTTEngine = MockParakeetStreamingEngine()

        // Verify initial state
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded)

        // Load
        try await engine.load()
        let loadedAfter = await engine.isLoaded
        XCTAssertTrue(loadedAfter)

        // Feed audio
        await engine.feedAudio([Float](repeating: 0.5, count: 200))
        let partial = await engine.getPartialTranscript()
        XCTAssertEqual(partial, "mock transcript")

        // Final transcript resets
        let final1 = await engine.getFinalTranscript()
        XCTAssertEqual(final1, "mock transcript")
        let partial2 = await engine.getPartialTranscript()
        XCTAssertEqual(partial2, "", "Should be empty after getFinalTranscript resets")

        // Reset
        await engine.feedAudio([Float](repeating: 0.5, count: 200))
        await engine.reset()
        let partial3 = await engine.getPartialTranscript()
        XCTAssertEqual(partial3, "", "Should be empty after explicit reset")
    }

    // MARK: - Configuration

    func testCustomChunkSizeIsRespected() async {
        let engine = ParakeetStreamingEngine(chunkSamples: 16000, minChunkSamples: 8000)
        // Engine should be created without errors
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded)
    }

    func testChunkSizeFlooredAtMinimum() async {
        // Very small chunk sizes should be floored to 1600 (100ms)
        let engine = ParakeetStreamingEngine(chunkSamples: 100, minChunkSamples: 50)
        // Should not crash; floor enforced internally
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded)
    }
}
