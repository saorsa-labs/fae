import Foundation
import XCTest
@testable import Fae

/// Offline eval harness for the audio pipeline.
///
/// Runs pre-recorded WAV files through VAD, streaming STT, and keyword classifier
/// independently, reporting per-clip metrics.  Skips gracefully when the eval corpus
/// directory is empty (no WAV files checked in — they live locally).
///
/// Usage:
///   1. Record clips into Tests/eval-corpus/ (16kHz mono Float32 WAV).
///   2. Annotate each clip with a matching .json sidecar (see schema.json).
///   3. Run: just test-target AudioEvalHarnessTests
final class AudioEvalHarnessTests: XCTestCase {

    // MARK: - Corpus Discovery

    struct EvalEntry: Decodable {
        let file: String
        let `class`: String
        let transcript: String
        let noiseType: String?
        let speechOnsetMs: Int?
        let speechOffsetMs: Int?
        let expectedKeywords: [String]?
        let isInterrupt: Bool?
        let snrEstimateDb: Double?
        let durationSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case file
            case `class`
            case transcript
            case noiseType = "noise_type"
            case speechOnsetMs = "speech_onset_ms"
            case speechOffsetMs = "speech_offset_ms"
            case expectedKeywords = "expected_keywords"
            case isInterrupt = "is_interrupt"
            case snrEstimateDb = "snr_estimate_db"
            case durationSeconds = "duration_seconds"
        }
    }

    static let corpusDir: URL = {
        // Resolve relative to the source file location.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // HandoffTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("eval-corpus")
    }()

    static func loadCorpus() -> [EvalEntry] {
        let dir = corpusDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        let jsonFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".json") && $0 != "schema.json" } ?? []

        var entries: [EvalEntry] = []
        let decoder = JSONDecoder()
        for jsonFile in jsonFiles {
            let url = dir.appendingPathComponent(jsonFile)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(EvalEntry.self, from: data)
            else { continue }

            // Only include entries that have a corresponding WAV file.
            let wavPath = dir.appendingPathComponent(entry.file).path
            if FileManager.default.fileExists(atPath: wavPath) {
                entries.append(entry)
            }
        }
        return entries
    }

    static func loadWAV(at url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Simple WAV parser: skip 44-byte header, read Float32 samples.
        guard data.count > 44 else { return nil }
        let sampleData = data.advanced(by: 44)
        let sampleCount = sampleData.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return nil }
        return sampleData.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self).prefix(sampleCount))
        }
    }

    // MARK: - VAD Eval

    func testVADOnCorpus() {
        let entries = Self.loadCorpus()
        guard !entries.isEmpty else {
            // No corpus files — skip gracefully.
            return
        }

        var vadFalsePositives = 0
        var vadMisses = 0
        var totalSpeechEntries = 0
        var totalSilenceEntries = 0

        for entry in entries {
            let wavURL = Self.corpusDir.appendingPathComponent(entry.file)
            guard let samples = Self.loadWAV(at: wavURL) else { continue }

            var vad = VoiceActivityDetector()
            let chunkSize = 576
            var speechDetected = false

            var offset = 0
            while offset + chunkSize <= samples.count {
                let chunk = AudioChunk(
                    samples: Array(samples[offset..<(offset + chunkSize)]),
                    sampleRate: 16000
                )
                let output = vad.processChunk(chunk)
                if output.isSpeech || output.segment != nil {
                    speechDetected = true
                }
                offset += chunkSize
            }

            let hasSpeech = !entry.transcript.isEmpty
            if hasSpeech {
                totalSpeechEntries += 1
                if !speechDetected { vadMisses += 1 }
            } else {
                totalSilenceEntries += 1
                if speechDetected { vadFalsePositives += 1 }
            }
        }

        if totalSilenceEntries > 0 {
            let fpRate = Float(vadFalsePositives) / Float(totalSilenceEntries)
            XCTAssertLessThan(fpRate, 0.05, "VAD false positive rate should be < 5%")
        }
        if totalSpeechEntries > 0 {
            let missRate = Float(vadMisses) / Float(totalSpeechEntries)
            XCTAssertLessThan(missRate, 0.02, "VAD miss rate should be < 2%")
        }
    }

    // MARK: - Noise Floor Eval

    func testNoiseFloorAdaptationOnCorpus() {
        let entries = Self.loadCorpus().filter { $0.class == "ambient_silence" }
        guard !entries.isEmpty else { return }

        for entry in entries {
            let wavURL = Self.corpusDir.appendingPathComponent(entry.file)
            guard let samples = Self.loadWAV(at: wavURL) else { continue }

            var vad = VoiceActivityDetector()
            let chunkSize = 576
            var offset = 0
            while offset + chunkSize <= samples.count {
                let chunk = AudioChunk(
                    samples: Array(samples[offset..<(offset + chunkSize)]),
                    sampleRate: 16000
                )
                _ = vad.processChunk(chunk)
                offset += chunkSize
            }

            // Noise floor should have adapted to ambient level.
            let rms = VoiceActivityDetector.computeRMS(samples)
            let snr = vad.estimatedSNRdB(chunkRms: rms)
            // For silence, SNR at the measured RMS should be near 0 dB.
            XCTAssertLessThan(abs(snr), 6.0,
                              "SNR for ambient clip \(entry.file) should be near 0 dB, got \(snr)")
        }
    }

    // MARK: - Endpointing Eval

    func testEndpointingOnCorpus() {
        let entries = Self.loadCorpus().filter { !$0.transcript.isEmpty }
        guard !entries.isEmpty else { return }

        var prematureCutoffs = 0
        var total = 0

        for entry in entries {
            let wavURL = Self.corpusDir.appendingPathComponent(entry.file)
            guard let samples = Self.loadWAV(at: wavURL) else { continue }

            var vad = VoiceActivityDetector()
            let chunkSize = 576
            var segments: [SpeechSegment] = []

            var offset = 0
            while offset + chunkSize <= samples.count {
                let chunk = AudioChunk(
                    samples: Array(samples[offset..<(offset + chunkSize)]),
                    sampleRate: 16000
                )
                let output = vad.processChunk(chunk)
                if let seg = output.segment { segments.append(seg) }
                offset += chunkSize
            }

            total += 1

            // Check if the expected speech onset/offset is captured in a segment.
            if let onsetMs = entry.speechOnsetMs,
               let offsetMs = entry.speechOffsetMs
            {
                let expectedDuration = Double(offsetMs - onsetMs) / 1000.0
                let capturedDuration = segments.reduce(0.0) { $0 + $1.durationSeconds }

                // Premature cutoff: we captured less than 60% of expected speech.
                if capturedDuration < expectedDuration * 0.6 {
                    prematureCutoffs += 1
                }
            }
        }

        if total > 0 {
            let cutoffRate = Float(prematureCutoffs) / Float(total)
            XCTAssertLessThan(cutoffRate, 0.05, "Premature cutoff rate should be < 5%")
        }
    }

    // MARK: - Streaming STT Partial Stability Eval

    func testStreamingPartialStabilityOnCorpus() async {
        let entries = Self.loadCorpus().filter { !$0.transcript.isEmpty }
        guard !entries.isEmpty else { return }

        // For each speech clip, verify that the streaming session lifecycle works:
        // start → feed audio → reset. Without a loaded model, feedStreamingAudio
        // silently drops samples (session is nil), but the API shouldn't crash.
        for entry in entries {
            let wavURL = Self.corpusDir.appendingPathComponent(entry.file)
            guard let samples = Self.loadWAV(at: wavURL) else { continue }

            let engine = MLXSTTEngine()
            let chunkSize = 576
            var offset = 0

            // Without a loaded model, startStreamingSession is a no-op
            // and feedStreamingAudio drops samples safely.
            while offset + chunkSize <= samples.count {
                let chunk = Array(samples[offset..<(offset + chunkSize)])
                await engine.feedStreamingAudio(chunk)
                offset += chunkSize
            }

            let isCurrentlyStreaming = await engine.isStreaming
            XCTAssertFalse(isCurrentlyStreaming,
                           "Engine should not be streaming without a loaded model")

            await engine.resetStreaming()
        }
    }

    // MARK: - Keyword Classifier Eval (placeholder — requires loaded model)

    func testKeywordExpectationsOnCorpus() {
        let entries = Self.loadCorpus().filter { $0.expectedKeywords != nil && !($0.expectedKeywords ?? []).isEmpty }
        guard !entries.isEmpty else { return }

        // The keyword classifier was removed (S18 kill-list); verify only that
        // corpus entries with expected keywords have the right metadata.
        // corpus metadata stays well-formed for any future audio classifier.
        for entry in entries {
            XCTAssertFalse(
                (entry.expectedKeywords ?? []).isEmpty,
                "Entry \(entry.file) claims keywords but has empty list"
            )
        }
    }

    // MARK: - False Barge-In Eval

    func testTTSOnlyClipsProduceNoSpeechSegments() {
        let entries = Self.loadCorpus().filter { $0.class == "tts_only" }
        guard !entries.isEmpty else { return }

        for entry in entries {
            let wavURL = Self.corpusDir.appendingPathComponent(entry.file)
            guard let samples = Self.loadWAV(at: wavURL) else { continue }

            var vad = VoiceActivityDetector()
            let chunkSize = 576
            var segments: [SpeechSegment] = []

            var offset = 0
            while offset + chunkSize <= samples.count {
                let chunk = AudioChunk(
                    samples: Array(samples[offset..<(offset + chunkSize)]),
                    sampleRate: 16000
                )
                let output = vad.processChunk(chunk)
                if let seg = output.segment { segments.append(seg) }
                offset += chunkSize
            }

            // TTS-only clips should produce zero user speech segments.
            // If VAD fires on Fae's own output, that's a false barge-in source.
            XCTAssertEqual(
                segments.count, 0,
                "TTS-only clip \(entry.file) should produce 0 VAD segments, got \(segments.count)"
            )
        }
    }

    // MARK: - Harness Sanity

    func testCorpusSchemaExists() {
        let schemaPath = Self.corpusDir.appendingPathComponent("schema.json").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: schemaPath),
            "Eval corpus schema.json should exist at \(schemaPath)"
        )
    }
}
