import XCTest
@testable import Fae

final class KeywordClassifierTests: XCTestCase {

    // MARK: - KeywordLabel Tests

    func testKeywordLabelRawValues() {
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.interrupt.rawValue, 0)
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.wake.rawValue, 1)
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.speech.rawValue, 2)
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.silence.rawValue, 3)
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.noise.rawValue, 4)
    }

    func testKeywordLabelNames() {
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.interrupt.name, "interrupt")
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.wake.name, "wake")
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.speech.name, "speech")
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.silence.name, "silence")
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.noise.name, "noise")
    }

    func testKeywordLabelCaseIterable() {
        XCTAssertEqual(MLXKeywordClassifier.KeywordLabel.allCases.count, 5)
    }

    // MARK: - Classifier Config

    func testClassifierConfigDecoding() throws {
        let json = """
        {
            "num_classes": 5,
            "input_features": 128,
            "target_frames": 48,
            "sample_rate": 24000,
            "n_mels": 128,
            "label_names": ["interrupt", "wake", "speech", "silence", "noise"]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(
            MLXKeywordClassifier.ClassifierConfig.self, from: data
        )
        XCTAssertEqual(config.numClasses, 5)
        XCTAssertEqual(config.inputFeatures, 128)
        XCTAssertEqual(config.targetFrames, 48)
        XCTAssertEqual(config.sampleRate, 24_000)
        XCTAssertEqual(config.nMels, 128)
        XCTAssertEqual(config.labelNames.count, 5)
    }

    // MARK: - Model Discovery

    func testDefaultModelPathIsInAppSupport() {
        let path = MLXKeywordClassifier.defaultModelPath.path
        XCTAssertTrue(
            path.contains("Application Support/fae/models/keyword-classifier"),
            "Default model path should be in fae app support: \(path)"
        )
    }

    // MARK: - Classifier Not Loaded

    func testClassifyThrowsWhenNotLoaded() async {
        let classifier = MLXKeywordClassifier()
        let loaded = await classifier.isLoaded
        XCTAssertFalse(loaded)

        do {
            _ = try await classifier.classify(
                audio: [Float](repeating: 0.1, count: 8_000),
                sampleRate: 16_000
            )
            XCTFail("Should throw when not loaded")
        } catch {
            // Expected — model not loaded.
        }
    }

    func testClassifyThrowsOnEmptyAudio() async {
        let classifier = MLXKeywordClassifier()
        // Even if loaded, empty audio should fail.
        do {
            _ = try await classifier.classify(audio: [], sampleRate: 16_000)
            XCTFail("Should throw on empty audio")
        } catch {
            // Expected.
        }
    }

    // MARK: - Load Missing Model

    func testLoadFailsWithMissingModel() async {
        let classifier = MLXKeywordClassifier()
        let bogusPath = URL(fileURLWithPath: "/tmp/nonexistent-keyword-model")

        do {
            try await classifier.load(modelPath: bogusPath)
            XCTFail("Should throw for missing model files")
        } catch {
            // Expected — model files don't exist.
        }

        let loaded = await classifier.isLoaded
        XCTAssertFalse(loaded)
    }

    // MARK: - Mel Spectrogram Shape

    func testSharedMelSpectrogramProducesCorrectShape() {
        // Generate 1 second of 16kHz audio (will be resampled to 24kHz internally).
        let sampleRate = 16_000
        let duration = 1.0
        let sampleCount = Int(Double(sampleRate) * duration)
        var audio = [Float](repeating: 0, count: sampleCount)

        // Simple sine wave at 440Hz.
        for i in 0..<sampleCount {
            audio[i] = sin(Float(i) * 2.0 * .pi * 440.0 / Float(sampleRate)) * 0.5
        }

        let (mel, numFrames) = CoreMLSpeakerEncoder.sharedLogMelSpectrogram(
            audio: audio,
            sampleRate: sampleRate
        )

        // Should produce 128 mel bands × some number of frames.
        XCTAssertGreaterThan(numFrames, 0, "Should have at least one frame")
        XCTAssertEqual(mel.count, 128 * numFrames, "Mel should be numMels × numFrames")
    }

    // MARK: - Classification Result Types

    func testKeywordClassificationInit() {
        let result = MLXKeywordClassifier.KeywordClassification(
            label: .interrupt,
            confidence: 0.95,
            keyword: "stop"
        )
        XCTAssertEqual(result.label, .interrupt)
        XCTAssertEqual(result.confidence, 0.95, accuracy: 0.001)
        XCTAssertEqual(result.keyword, "stop")
    }

    func testKeywordClassificationNoKeyword() {
        let result = MLXKeywordClassifier.KeywordClassification(
            label: .noise,
            confidence: 0.8,
            keyword: nil
        )
        XCTAssertEqual(result.label, .noise)
        XCTAssertNil(result.keyword)
    }

    // MARK: - PendingBargeIn Keyword Fields

    func testPendingBargeInKeywordFieldsDefaultToNil() {
        let barge = PendingBargeIn(
            capturedAt: Date(),
            lastRms: 0.1,
            peakRms: 0.1
        )
        XCTAssertNil(barge.partialTranscript, "Default partialTranscript should be nil")
        XCTAssertFalse(barge.hasInterruptKeyword, "Default hasInterruptKeyword should be false")
    }

    func testPendingBargeInKeywordFieldsMutable() {
        var barge = PendingBargeIn(
            capturedAt: Date(),
            lastRms: 0.1,
            peakRms: 0.1
        )
        barge.hasInterruptKeyword = true
        barge.partialTranscript = "stop"

        XCTAssertTrue(barge.hasInterruptKeyword)
        XCTAssertEqual(barge.partialTranscript, "stop")
    }
}
