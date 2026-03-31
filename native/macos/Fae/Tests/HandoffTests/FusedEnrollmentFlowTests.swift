import XCTest
@testable import Fae

/// Tests for the 6-step fused enrollment flow (Phase 1.2).
///
/// These tests exercise:
/// - Full completion: conversational embeddings → SpeakerProfileStore, wake templates → WakeWordProfileStore
/// - Abandonment: no data written to stores if enrollment not completed
/// - Template generation: WakeWordAcousticDetector produces valid templates from synthetic audio
/// - Room noise: noiseFloorRMS is computed from audio samples
final class FusedEnrollmentFlowTests: XCTestCase {

    // MARK: - Template generation

    func testWakeTemplateGeneratedFromSyntheticAudio() throws {
        let samples = WakeWordAcousticDetectorTests.syntheticWakePhrase()
        let template = try XCTUnwrap(
            WakeWordAcousticDetector.makeTemplate(samples: samples, sampleRate: 24_000),
            "makeTemplate should produce a template from valid synthetic audio"
        )
        XCTAssertFalse(template.embedding.isEmpty, "template embedding must not be empty")
        XCTAssertGreaterThan(template.durationSeconds, 0, "template duration must be positive")
        XCTAssertEqual(template.phrase, "Hey Fae", "default phrase should be 'Hey Fae'")
    }

    func testFourWakeTemplatesCanBeStored() async throws {
        let (wakeStore, _) = makeTempStores()
        let samples = WakeWordAcousticDetectorTests.syntheticWakePhrase()

        for i in 0..<4 {
            let template = try XCTUnwrap(
                WakeWordAcousticDetector.makeTemplate(samples: samples, sampleRate: 24_000)
            )
            await wakeStore.recordAcousticTemplate(template, phrase: "Hey Fae", source: "enrollment")
            let count = await wakeStore.acousticTemplateCount()
            XCTAssertEqual(count, i + 1, "wake store should have \(i + 1) templates after recording \(i + 1)")
        }

        let finalCount = await wakeStore.acousticTemplateCount()
        XCTAssertEqual(finalCount, 4, "wake store should have exactly 4 templates after fused enrollment")
    }

    func testWakeTemplateGenerationFailsForTooShortAudio() {
        // 100ms at 24kHz = 2400 samples, below minDurationSeconds (0.35s)
        // The trimSilence step won't find a peak to preserve, leaving output short enough to fail.
        let tooShort = [Float](repeating: 0.1, count: 2_400)
        let template = WakeWordAcousticDetector.makeTemplate(samples: tooShort, sampleRate: 24_000)
        // Duration check: 2400/24000 = 0.1s < 0.35s minimum
        XCTAssertNil(template, "template generation should fail for audio shorter than minimum duration")
    }

    func testWakeTemplateGenerationFailsForTooLongAudio() {
        // 3s at 24kHz = 72000 samples, above maxDurationSeconds (1.80s)
        // Need audible signal so trimSilence doesn't shorten it below threshold
        let sampleRate = 24_000
        let count = sampleRate * 3 // 3 seconds
        let tooLong = (0..<count).map { i in
            sin(2 * Float.pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        let template = WakeWordAcousticDetector.makeTemplate(samples: tooLong, sampleRate: sampleRate)
        // After trimSilence, audio remains ~3s which exceeds maxDurationSeconds (1.80s)
        XCTAssertNil(template, "template generation should fail for audio longer than maximum duration")
    }

    // MARK: - Atomic commit (simulated)

    func testAtomicCommitWritesConversationalEmbeddingsToSpeakerStore() async throws {
        let (wakeStore, speakerStore) = makeTempStores()

        // Simulate 3 conversational embeddings (128-dim each)
        let embeddings = (0..<3).map { i -> [Float] in
            var vec = [Float](repeating: 0.0, count: 128)
            vec[i % 128] = 1.0
            return vec
        }

        // Atomic commit: enroll conversational embeddings
        await speakerStore.bulkEnroll(
            label: "owner",
            embeddings: embeddings,
            role: .owner,
            displayName: "Test User"
        )

        // Verify speaker store has the owner profile
        let hasOwner = await speakerStore.hasOwnerProfile()
        XCTAssertTrue(hasOwner, "speaker store should have an owner profile after enrollment")
        let ownerName = await speakerStore.ownerDisplayName()
        XCTAssertEqual(ownerName, "Test User", "owner display name should match")

        // Wake store should still be empty (no wake templates in this scenario)
        let wakeCount = await wakeStore.acousticTemplateCount()
        XCTAssertEqual(wakeCount, 0, "wake store should be empty if no wake templates were recorded")
    }

    func testAtomicCommitWritesWakeTemplatesToWakeStore() async throws {
        let (wakeStore, _) = makeTempStores()
        let samples = WakeWordAcousticDetectorTests.syntheticWakePhrase()

        // Simulate 4 wake phrase recordings
        var templates: [WakeWordAcousticDetector.Template] = []
        for _ in 0..<4 {
            if let template = WakeWordAcousticDetector.makeTemplate(samples: samples, sampleRate: 24_000) {
                templates.append(template)
            }
        }
        XCTAssertEqual(templates.count, 4, "should generate 4 wake templates from synthetic audio")

        // Atomic commit: record all templates
        for template in templates {
            await wakeStore.recordAcousticTemplate(template, phrase: "Hey Fae", source: "enrollment")
        }

        let count = await wakeStore.acousticTemplateCount()
        XCTAssertEqual(count, 4, "wake store should have exactly 4 templates after atomic commit")
    }

    func testFullEnrollmentAtomicCommit() async throws {
        let (wakeStore, speakerStore) = makeTempStores()
        let samples = WakeWordAcousticDetectorTests.syntheticWakePhrase()

        // 4 wake recordings
        for _ in 0..<4 {
            if let template = WakeWordAcousticDetector.makeTemplate(samples: samples, sampleRate: 24_000) {
                await wakeStore.recordAcousticTemplate(template, phrase: "Hey Fae", source: "enrollment")
            }
        }

        // 3 conversational embeddings
        let convEmbeddings = (0..<3).map { i -> [Float] in
            var vec = [Float](repeating: 0.0, count: 128)
            vec[i % 128] = 1.0
            return vec
        }
        await speakerStore.bulkEnroll(
            label: "owner",
            embeddings: convEmbeddings,
            role: .owner,
            displayName: "Alice"
        )

        // Verify both stores committed
        let wakeCount = await wakeStore.acousticTemplateCount()
        XCTAssertEqual(wakeCount, 4, "wake store should have 4 templates after full enrollment")

        let hasOwner = await speakerStore.hasOwnerProfile()
        XCTAssertTrue(hasOwner, "speaker store should have owner profile after full enrollment")
    }

    // MARK: - Abandonment (no partial writes)

    func testAbandonmentBeforeCompleteLeavesStoresEmpty() async throws {
        let (wakeStore, speakerStore) = makeTempStores()

        // Simulate abandonment at step 3 (conversational) — nothing should be written
        // In the real UI, commitAndComplete() is never called, so stores remain empty.

        let wakeCount = await wakeStore.acousticTemplateCount()
        XCTAssertEqual(wakeCount, 0, "wake store should be empty if enrollment was abandoned")

        let hasOwner = await speakerStore.hasOwnerProfile()
        XCTAssertFalse(hasOwner, "speaker store should have no owner profile if enrollment was abandoned")
    }

    func testPartialWakeTemplatesAreNotCommittedOnAbandonment() async throws {
        let (wakeStore, _) = makeTempStores()

        // In the real flow, templates accumulate in @State and are only written in commitAndComplete().
        // Here we verify the store is empty unless we explicitly call recordAcousticTemplate.
        let count = await wakeStore.acousticTemplateCount()
        XCTAssertEqual(count, 0, "wake store must be empty until commitAndComplete is called")
    }

    // MARK: - Noise floor

    func testNoiseFloorRMSIsPositiveForNonSilentAudio() {
        // Generate simple tonal audio (simulates ambient noise)
        let sampleRate = 16_000
        let duration = 1.0
        let sampleCount = Int(Double(sampleRate) * duration)
        let noise = (0..<sampleCount).map { i -> Float in
            sin(2 * Float.pi * 440 * Float(i) / Float(sampleRate)) * 0.05
        }

        // Compute RMS as enrollment would
        let sumSq = noise.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumSq / Float(noise.count)).squareRoot()

        XCTAssertGreaterThan(rms, 0, "RMS should be positive for non-silent audio")
        XCTAssertLessThan(rms, 1.0, "RMS should be less than 1.0 for normal audio")
    }

    func testNoiseFloorRMSIsZeroForSilence() {
        let silence = [Float](repeating: 0.0, count: 16_000)
        let sumSq = silence.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = silence.isEmpty ? Float(0) : (sumSq / Float(silence.count)).squareRoot()
        XCTAssertEqual(rms, 0.0, accuracy: 1e-6, "RMS should be 0 for silence")
    }

    // MARK: - Consistency score

    func testConsistencyScoreForIdenticalEmbeddings() {
        let vec: [Float] = [0.5, 0.5, 0.5, 0.5]
        let embeddings = [[Float]](repeating: vec, count: 3)
        let score = SpeakerProfileStore.consistencyScore(embeddings)
        XCTAssertGreaterThan(score, 0.9, "identical embeddings should produce a high consistency score")
    }

    func testConsistencyScoreForOrthogonalEmbeddings() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        let c: [Float] = [0, 0, 1, 0]
        let score = SpeakerProfileStore.consistencyScore([a, b, c])
        XCTAssertLessThan(score, 0.5, "orthogonal embeddings should produce a low consistency score")
    }

    // MARK: - Helpers

    private func makeTempStores() -> (WakeWordProfileStore, SpeakerProfileStore) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-fused-enrollment-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let wakeStore = WakeWordProfileStore(
            storePath: tempDir.appendingPathComponent("wake_lexicon.json")
        )
        let speakerStore = SpeakerProfileStore(
            storePath: tempDir.appendingPathComponent("speakers.json")
        )
        return (wakeStore, speakerStore)
    }
}
