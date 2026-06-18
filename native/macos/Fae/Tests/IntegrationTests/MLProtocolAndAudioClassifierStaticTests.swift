import AVFoundation
import CoreGraphics
import XCTest
import FaeInference
@testable import Fae

final class MLProtocolAndAudioClassifierStaticTests: XCTestCase {
    func testTTSEngineDefaultVoiceCloningHooksAreNoOps() async throws {
        let engine = FakeTTSEngine()
        let url = URL(fileURLWithPath: "/tmp/reference.wav")

        let initiallyVoiceLoaded = await engine.isVoiceLoaded
        XCTAssertFalse(initiallyVoiceLoaded)
        try await engine.loadVoice(referenceAudioURL: url, referenceText: "hello")
        try await engine.loadCustomVoice(url: url, referenceText: nil)
        let finallyVoiceLoaded = await engine.isVoiceLoaded
        XCTAssertFalse(finallyVoiceLoaded)
    }

    func testTTSEngineVoiceInstructSynthesizeDelegatesToPlainSynthesize() async throws {
        let engine = FakeTTSEngine()
        let stream = await engine.synthesize(text: "Hello", voiceInstruct: "warm")
        for try await _ in stream {}

        let recordedTexts = await engine.recordedTexts()
        XCTAssertEqual(recordedTexts, ["Hello"])
    }

    func testVLMEngineDefaultWarmupIsNoOp() async {
        let engine = FakeVLMEngine()
        await engine.warmup()
        let isLoaded = await engine.isLoaded
        XCTAssertFalse(isLoaded)
    }

    func testClassifierConfigDecodesSnakeCaseJSON() throws {
        let data = Data(#"{"num_classes":3,"input_features":80,"target_frames":64,"sample_rate":16000,"label_names":["a","b","c"]}"#.utf8)

        let config = try JSONDecoder().decode(CoreMLAudioClassifier.ClassifierConfig.self, from: data)

        XCTAssertEqual(config.numClasses, 3)
        XCTAssertEqual(config.inputFeatures, 80)
        XCTAssertEqual(config.targetFrames, 64)
        XCTAssertEqual(config.sampleRate, 16_000)
        XCTAssertEqual(config.labelNames, ["a", "b", "c"])
    }

    func testClassificationResultStoresFields() {
        let result = CoreMLAudioClassifier.ClassificationResult(
            labelIndex: 2,
            labelName: "speech",
            confidence: 0.875
        )

        XCTAssertEqual(result.labelIndex, 2)
        XCTAssertEqual(result.labelName, "speech")
        XCTAssertEqual(result.confidence, 0.875, accuracy: 0.0001)
    }

    func testTimeNormalizeMelReturnsEmptyForInvalidDimensions() {
        XCTAssertTrue(CoreMLAudioClassifier.timeNormalizeMel([1, 2], numFrames: 0, numMels: 2, targetFrames: 4).isEmpty)
        XCTAssertTrue(CoreMLAudioClassifier.timeNormalizeMel([1, 2], numFrames: 2, numMels: 0, targetFrames: 4).isEmpty)
    }

    func testTimeNormalizeMelReturnsInputWhenFrameCountAlreadyMatches() {
        let mel: [Float] = [1, 2, 3, 4]

        XCTAssertEqual(CoreMLAudioClassifier.timeNormalizeMel(mel, numFrames: 2, numMels: 2, targetFrames: 2), mel)
    }

    func testTimeNormalizeMelInterpolatesEachMelBandIndependently() {
        let mel: [Float] = [0, 10, 100, 200]

        let normalized = CoreMLAudioClassifier.timeNormalizeMel(
            mel,
            numFrames: 2,
            numMels: 2,
            targetFrames: 3
        )

        XCTAssertEqual(normalized, [0, 5, 10, 100, 150, 200])
    }

    func testTimeNormalizeMelDownsamplesToEndpoints() {
        let mel: [Float] = [0, 10, 20, 30]

        let normalized = CoreMLAudioClassifier.timeNormalizeMel(
            mel,
            numFrames: 4,
            numMels: 1,
            targetFrames: 2
        )

        XCTAssertEqual(normalized, [0, 30])
    }
}

private actor FakeTTSEngine: TTSEngine {
    private var texts: [String] = []

    func load(modelID: String) async throws {}

    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        texts.append(text)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    var isLoaded: Bool { false }
    var loadState: MLEngineLoadState { .notStarted }

    func recordedTexts() -> [String] {
        texts
    }
}

private actor FakeVLMEngine: VLMEngine {
    func load(modelID: String) async throws {}

    func describe(
        image: CGImage,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    var isLoaded: Bool { false }
    var loadState: MLEngineLoadState { .notStarted }
}
