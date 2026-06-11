import XCTest
@testable import Fae

final class TrainingBridgeTypesTests: XCTestCase {

    // MARK: - TrainingBridgeError

    func testTrainingBridgeErrorUVNotAvailable() {
        let error: Error = TrainingBridgeError.uvNotAvailable
        XCTAssertTrue((error as? TrainingBridgeError)?.errorDescription?.contains("uv") == true)
    }

    func testTrainingBridgeErrorScriptNotFound() {
        let error: Error = TrainingBridgeError.scriptNotFound("train.py")
        let desc = (error as? TrainingBridgeError)?.errorDescription ?? ""
        XCTAssertTrue(desc.contains("train.py"))
    }

    func testTrainingBridgeErrorExecutionFailed() {
        let error: Error = TrainingBridgeError.executionFailed(exitCode: 1, stderr: "segfault")
        let desc = (error as? TrainingBridgeError)?.errorDescription ?? ""
        XCTAssertTrue(desc.contains("1"))
        XCTAssertTrue(desc.contains("segfault"))
    }

    func testTrainingBridgeErrorParseError() {
        let error: Error = TrainingBridgeError.parseError("invalid json")
        let desc = (error as? TrainingBridgeError)?.errorDescription ?? ""
        XCTAssertTrue(desc.contains("parse"))
    }

    func testTrainingBridgeErrorTimeout() {
        let error: Error = TrainingBridgeError.timeout(seconds: 300)
        let desc = (error as? TrainingBridgeError)?.errorDescription ?? ""
        XCTAssertTrue(desc.contains("300"))
    }

    func testTrainingBridgeErrorInsufficientData() {
        let error: Error = TrainingBridgeError.insufficientData(sftExamples: 5, dpoPairs: 0)
        let desc = (error as? TrainingBridgeError)?.errorDescription ?? ""
        XCTAssertTrue(desc.contains("5"))
    }

    // MARK: - ExportResult

    func testExportResultInit() {
        let result = ExportResult(
            sftExamples: 100,
            dpoPairs: 50,
            outputFiles: ["sft_export": "/tmp/train.jsonl", "dpo_export": "/tmp/dpo.jsonl"]
        )
        XCTAssertEqual(result.sftExamples, 100)
        XCTAssertEqual(result.dpoPairs, 50)
        XCTAssertEqual(result.outputFiles.count, 2)
    }

    // MARK: - TrainingMode

    func testTrainingModeRawValues() {
        XCTAssertEqual(TrainingMode.sft.rawValue, "sft")
        XCTAssertEqual(TrainingMode.dpo.rawValue, "dpo")
    }

    // MARK: - TrainingLaunchResult

    func testTrainingLaunchResultInit() {
        let result = TrainingLaunchResult(
            pid: 12345,
            adapterPath: "/tmp/adapter",
            modelId: "Qwen/Qwen3-4B",
            mode: .sft
        )
        XCTAssertEqual(result.pid, 12345)
        XCTAssertEqual(result.mode, .sft)
    }

    // MARK: - TrainingStatus

    func testTrainingStatusRunning() {
        let status: TrainingStatus = .running(pid: 12345)
        switch status {
        case .running(let pid):
            XCTAssertEqual(pid, 12345)
        default:
            XCTFail("Expected running")
        }
    }

    func testTrainingStatusCompleted() {
        let status: TrainingStatus = .completed(adapterPath: "/tmp/adapter-v1")
        switch status {
        case .completed(let path):
            XCTAssertEqual(path, "/tmp/adapter-v1")
        default:
            XCTFail("Expected completed")
        }
    }

    func testTrainingStatusNotRunning() {
        let status: TrainingStatus = .notRunning
        switch status {
        case .notRunning:
            break // OK
        default:
            XCTFail("Expected notRunning")
        }
    }

    // MARK: - TrainingEvalResult

    func testTrainingEvalResultInit() {
        let result = TrainingEvalResult(
            score: 0.85,
            finalLoss: 0.42,
            recommendation: "upgrade",
            adapterPath: "/tmp/adapter"
        )
        XCTAssertEqual(result.score, 0.85)
        XCTAssertEqual(result.recommendation, "upgrade")
    }

    // MARK: - TrainingBenchmarkResult

    func testTrainingBenchmarkResultInit() {
        let result = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.85,
            faeCapabilityAccuracy: 0.92,
            assistantFitAccuracy: 0.78,
            serializationAccuracy: 0.95,
            avgThroughputTPS: 45.5,
            modelId: "Qwen/Qwen3-4B",
            adapterPath: nil
        )
        XCTAssertEqual(result.toolCallingAccuracy, 0.85)
        XCTAssertNil(result.adapterPath)
    }

    func testTrainingBenchmarkResultDelta() {
        let baseline = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.70,
            faeCapabilityAccuracy: 0.80,
            assistantFitAccuracy: 0.60,
            serializationAccuracy: 0.85,
            avgThroughputTPS: 40.0,
            modelId: "base",
            adapterPath: nil
        )
        let after = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.85,
            faeCapabilityAccuracy: 0.90,
            assistantFitAccuracy: 0.75,
            serializationAccuracy: 0.80,
            avgThroughputTPS: 50.0,
            modelId: "adapter",
            adapterPath: "/tmp/adapter"
        )

        let delta = after.delta(from: baseline)
        // Double arithmetic carries rounding error — compare with accuracy.
        XCTAssertEqual(delta.toolCallingDelta ?? .nan, 15.0, accuracy: 1e-9) // (0.85-0.70)*100
        XCTAssertEqual(delta.faeCapabilityDelta ?? .nan, 10.0, accuracy: 1e-9)
        XCTAssertEqual(delta.assistantFitDelta ?? .nan, 15.0, accuracy: 1e-9)
        XCTAssertEqual(delta.serializationDelta ?? .nan, -5.0, accuracy: 1e-9) // regression
        XCTAssertEqual(delta.throughputDelta ?? .nan, 10.0, accuracy: 1e-9)
    }

    func testTrainingBenchmarkResultDeltaNilThroughput() {
        let baseline = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.70, faeCapabilityAccuracy: 0.80,
            assistantFitAccuracy: 0.60, serializationAccuracy: 0.85,
            avgThroughputTPS: nil, modelId: "base", adapterPath: nil
        )
        let after = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.80, faeCapabilityAccuracy: 0.85,
            assistantFitAccuracy: 0.70, serializationAccuracy: 0.90,
            avgThroughputTPS: nil, modelId: "adapter", adapterPath: "/tmp/a"
        )

        let delta = after.delta(from: baseline)
        XCTAssertNil(delta.throughputDelta) // both nil → nil
    }

    func testTrainingBenchmarkResultToBaseline() {
        let result = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.85,
            faeCapabilityAccuracy: 0.92,
            assistantFitAccuracy: 0.78,
            serializationAccuracy: 0.95,
            avgThroughputTPS: 45.5,
            modelId: "Qwen/Qwen3-4B",
            adapterPath: "/tmp/adapter"
        )

        let baseline = result.toBaseline(feedbackEventCount: 10)
        XCTAssertEqual(baseline.modelID, "Qwen/Qwen3-4B")
        XCTAssertEqual(baseline.toolCallingAccuracy, 0.85)
        XCTAssertEqual(baseline.feedbackEventCount, 10)
        XCTAssertNotNil(baseline.measuredAt)
    }

    // MARK: - EvalDelta

    func testEvalDeltaInit() {
        let delta = EvalDelta(
            toolCallingDelta: 5.0,
            faeCapabilityDelta: 3.0,
            assistantFitDelta: -2.0,
            serializationDelta: 1.0,
            throughputDelta: 10.0
        )
        XCTAssertEqual(delta.toolCallingDelta, 5.0)
        XCTAssertEqual(delta.assistantFitDelta, -2.0)
    }

    func testEvalDeltaAllNil() {
        let delta = EvalDelta(
            toolCallingDelta: nil,
            faeCapabilityDelta: nil,
            assistantFitDelta: nil,
            serializationDelta: nil,
            throughputDelta: nil
        )
        XCTAssertNil(delta.toolCallingDelta)
    }
}
