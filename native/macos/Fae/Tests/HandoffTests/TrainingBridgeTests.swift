import XCTest
@testable import Fae

final class TrainingBridgeTests: XCTestCase {

    // MARK: - ExportResult Parsing

    func testExportResultFromJSONRPCEnvelope() throws {
        let json: [String: Any] = [
            "result": [
                "status": "ok",
                "sft_examples": 42,
                "dpo_pairs": 7,
                "average_interest_weight": 1.15,
                "output_files": [
                    "sft_export": "/tmp/training/data/sft_export.jsonl",
                    "dpo_pairs": "/tmp/training/data/dpo_pairs.jsonl",
                    "meta": "/tmp/training/data/export_meta.json",
                ],
            ] as [String: Any],
        ]
        let result = json["result"] as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["sft_examples"] as? Int, 42)
        XCTAssertEqual(result?["dpo_pairs"] as? Int, 7)
        let files = result?["output_files"] as? [String: String]
        XCTAssertNotNil(files)
        XCTAssertEqual(files?["sft_export"], "/tmp/training/data/sft_export.jsonl")
    }

    // MARK: - TrainingLaunchResult Parsing

    func testTrainingLaunchResultFromJSON() throws {
        let json: [String: Any] = [
            "status": "started",
            "pid": 12345,
            "adapter_path": "/Users/test/Library/Application Support/fae/models/personal/20260331-030000",
            "model_id": "mlx-community/Qwen3.5-4B-4bit",
            "mode": "sft",
            "engine": "mlx-tune",
            "log_path": "/tmp/training/train.log",
        ]
        XCTAssertEqual(json["pid"] as? Int, 12345)
        XCTAssertEqual(json["adapter_path"] as? String,
                       "/Users/test/Library/Application Support/fae/models/personal/20260331-030000")
        XCTAssertEqual(json["mode"] as? String, "sft")
        XCTAssertEqual(json["model_id"] as? String, "mlx-community/Qwen3.5-4B-4bit")
    }

    // MARK: - TrainingStatus Parsing

    func testTrainingStatusRunning() throws {
        let json: [String: Any] = [
            "status": "running",
            "running": true,
            "pid": 99,
            "adapter_path": "/tmp/adapters/20260331",
        ]
        let running = json["running"] as? Bool ?? false
        XCTAssertTrue(running)
        XCTAssertEqual(json["pid"] as? Int, 99)
    }

    func testTrainingStatusCompleted() throws {
        let json: [String: Any] = [
            "status": "not_running",
            "running": false,
            "adapter_path": "/tmp/adapters/20260331",
        ]
        let running = json["running"] as? Bool ?? false
        XCTAssertFalse(running)
        XCTAssertNotNil(json["adapter_path"] as? String)
    }

    func testTrainingStatusNotRunningNoAdapter() throws {
        let json: [String: Any] = [
            "status": "not_running",
            "running": false,
        ]
        let running = json["running"] as? Bool ?? false
        XCTAssertFalse(running)
        XCTAssertNil(json["adapter_path"] as? String)
    }

    // MARK: - TrainingEvalResult Parsing

    func testTrainingEvalResultFromJSON() throws {
        let json: [String: Any] = [
            "status": "evaluated",
            "score": 0.85,
            "final_training_loss": 0.75,
            "recommendation": "upgrade",
            "adapter_path": "/tmp/adapters/20260331",
            "engine": "mlx-tune",
        ]
        XCTAssertEqual(json["score"] as? Double, 0.85)
        XCTAssertEqual(json["final_training_loss"] as? Double, 0.75)
        XCTAssertEqual(json["recommendation"] as? String, "upgrade")
        XCTAssertEqual(json["adapter_path"] as? String, "/tmp/adapters/20260331")
    }

    func testTrainingEvalResultSkipRecommendation() throws {
        let json: [String: Any] = [
            "status": "evaluated",
            "score": 0.15,
            "final_training_loss": 4.25,
            "recommendation": "skip",
            "adapter_path": "/tmp/adapters/bad-run",
        ]
        XCTAssertEqual(json["recommendation"] as? String, "skip")
        let score = json["score"] as? Double ?? 0.0
        XCTAssertLessThan(score, 0.5)
    }

    // MARK: - FaeDirectories Training Paths

    func testTrainingDirectoriesExist() {
        let trainingDir = FaeDirectories.trainingDataDirectory
        XCTAssertTrue(trainingDir.path.contains("training/data"),
                       "trainingDataDirectory should contain 'training/data' in path")

        let personalDir = FaeDirectories.personalModelsDirectory
        XCTAssertTrue(personalDir.path.contains("models/personal"),
                       "personalModelsDirectory should contain 'models/personal' in path")

        let runFile = FaeDirectories.trainingRunFile
        XCTAssertTrue(runFile.path.contains("training/run.json"),
                       "trainingRunFile should contain 'training/run.json' in path")
    }

    func testTrainingDirectoriesAutoCreate() {
        // Access should auto-create the directories.
        let trainingDir = FaeDirectories.trainingDataDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: trainingDir.path),
                       "trainingDataDirectory should be created on access")

        let personalDir = FaeDirectories.personalModelsDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalDir.path),
                       "personalModelsDirectory should be created on access")
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        let err1 = TrainingBridgeError.scriptNotFound("train.py")
        XCTAssertTrue(err1.localizedDescription.contains("train.py"))

        let err2 = TrainingBridgeError.timeout(seconds: 7200)
        XCTAssertTrue(err2.localizedDescription.contains("7200"))

        let err3 = TrainingBridgeError.executionFailed(exitCode: 1, stderr: "some error message")
        XCTAssertTrue(err3.localizedDescription.contains("some error message"))

        let err4 = TrainingBridgeError.uvNotAvailable
        XCTAssertFalse(err4.localizedDescription.isEmpty)

        let err5 = TrainingBridgeError.parseError("bad json")
        XCTAssertTrue(err5.localizedDescription.contains("bad json"))

        let err6 = TrainingBridgeError.insufficientData(sftExamples: 3, dpoPairs: 1)
        XCTAssertTrue(err6.localizedDescription.contains("3"))
    }

    // MARK: - TrainingMode

    func testTrainingModeRawValues() {
        XCTAssertEqual(TrainingMode.sft.rawValue, "sft")
        XCTAssertEqual(TrainingMode.dpo.rawValue, "dpo")
    }

    func testTrainingModeFromRawValue() {
        XCTAssertEqual(TrainingMode(rawValue: "sft"), .sft)
        XCTAssertEqual(TrainingMode(rawValue: "dpo"), .dpo)
        XCTAssertNil(TrainingMode(rawValue: "grpo"))
    }

    // MARK: - Struct Construction

    func testExportResultInit() {
        let result = ExportResult(
            sftExamples: 100,
            dpoPairs: 15,
            outputFiles: ["sft_export": "/tmp/train.jsonl"]
        )
        XCTAssertEqual(result.sftExamples, 100)
        XCTAssertEqual(result.dpoPairs, 15)
        XCTAssertEqual(result.outputFiles["sft_export"], "/tmp/train.jsonl")
    }

    func testTrainingLaunchResultInit() {
        let result = TrainingLaunchResult(
            pid: 42,
            adapterPath: "/tmp/adapter",
            modelId: "mlx-community/Qwen3.5-4B-4bit",
            mode: .sft
        )
        XCTAssertEqual(result.pid, 42)
        XCTAssertEqual(result.adapterPath, "/tmp/adapter")
        XCTAssertEqual(result.mode, .sft)
    }

    func testTrainingEvalResultInit() {
        let result = TrainingEvalResult(
            score: 0.92,
            finalLoss: 0.4,
            recommendation: "upgrade",
            adapterPath: "/tmp/adapter"
        )
        XCTAssertEqual(result.score, 0.92)
        XCTAssertEqual(result.recommendation, "upgrade")
    }

    // MARK: - TrainingBenchmarkResult

    func testTrainingBenchmarkResultInit() {
        let result = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.9,
            faeCapabilityAccuracy: 0.85,
            assistantFitAccuracy: 0.8,
            serializationAccuracy: 0.95,
            avgThroughputTPS: 45.0,
            modelId: "mlx-community/Qwen3.5-4B-4bit",
            adapterPath: nil
        )
        XCTAssertEqual(result.toolCallingAccuracy, 0.9)
        XCTAssertEqual(result.faeCapabilityAccuracy, 0.85)
        XCTAssertNil(result.adapterPath)
    }

    func testTrainingBenchmarkResultDelta() {
        let baseline = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.80,
            faeCapabilityAccuracy: 0.70,
            assistantFitAccuracy: 0.60,
            serializationAccuracy: 0.50,
            avgThroughputTPS: 40.0,
            modelId: "test-model",
            adapterPath: nil
        )
        let adapter = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.90,
            faeCapabilityAccuracy: 0.75,
            assistantFitAccuracy: 0.65,
            serializationAccuracy: 0.55,
            avgThroughputTPS: 38.0,
            modelId: "test-model",
            adapterPath: "/tmp/adapter"
        )

        let delta = adapter.delta(from: baseline)
        // 0.90 - 0.80 = 0.10 → 10.0 percentage points
        XCTAssertEqual(delta.toolCallingDelta ?? 0, 10.0, accuracy: 0.01)
        // 0.75 - 0.70 = 0.05 → 5.0
        XCTAssertEqual(delta.faeCapabilityDelta ?? 0, 5.0, accuracy: 0.01)
        // 0.65 - 0.60 = 0.05 → 5.0
        XCTAssertEqual(delta.assistantFitDelta ?? 0, 5.0, accuracy: 0.01)
        // 0.55 - 0.50 = 0.05 → 5.0
        XCTAssertEqual(delta.serializationDelta ?? 0, 5.0, accuracy: 0.01)
        // 38.0 - 40.0 = -2.0 (adapter is slower)
        XCTAssertEqual(delta.throughputDelta ?? 0, -2.0, accuracy: 0.01)
    }

    func testTrainingBenchmarkResultDeltaWithNilThroughput() {
        let baseline = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.80,
            faeCapabilityAccuracy: 0.70,
            assistantFitAccuracy: 0.60,
            serializationAccuracy: 0.50,
            avgThroughputTPS: nil,
            modelId: "test-model",
            adapterPath: nil
        )
        let adapter = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.85,
            faeCapabilityAccuracy: 0.75,
            assistantFitAccuracy: 0.65,
            serializationAccuracy: 0.55,
            avgThroughputTPS: nil,
            modelId: "test-model",
            adapterPath: "/tmp/adapter"
        )
        let delta = adapter.delta(from: baseline)
        XCTAssertNil(delta.throughputDelta)
    }

    func testTrainingBenchmarkResultNegativeDelta() {
        let baseline = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.90,
            faeCapabilityAccuracy: 0.85,
            assistantFitAccuracy: 0.80,
            serializationAccuracy: 0.95,
            avgThroughputTPS: nil,
            modelId: "test-model",
            adapterPath: nil
        )
        let adapter = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.70,
            faeCapabilityAccuracy: 0.60,
            assistantFitAccuracy: 0.50,
            serializationAccuracy: 0.40,
            avgThroughputTPS: nil,
            modelId: "test-model",
            adapterPath: "/tmp/bad-adapter"
        )
        let delta = adapter.delta(from: baseline)
        // All negative — adapter is worse.
        XCTAssertLessThan(delta.toolCallingDelta ?? 0, 0)
        XCTAssertLessThan(delta.faeCapabilityDelta ?? 0, 0)
        XCTAssertLessThan(delta.assistantFitDelta ?? 0, 0)
        XCTAssertLessThan(delta.serializationDelta ?? 0, 0)
    }

    func testTrainingBenchmarkResultToBaseline() {
        let result = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.90,
            faeCapabilityAccuracy: 0.85,
            assistantFitAccuracy: 0.80,
            serializationAccuracy: 0.95,
            avgThroughputTPS: 45.0,
            modelId: "mlx-community/Qwen3.5-4B-4bit",
            adapterPath: nil
        )
        let baseline = result.toBaseline(feedbackEventCount: 25)
        XCTAssertEqual(baseline.toolCallingAccuracy, 0.90)
        XCTAssertEqual(baseline.faeCapabilityAccuracy, 0.85)
        XCTAssertEqual(baseline.modelID, "mlx-community/Qwen3.5-4B-4bit")
        XCTAssertEqual(baseline.feedbackEventCount, 25)
        XCTAssertNil(baseline.adapterPath)
        XCTAssertFalse(baseline.measuredAt.isEmpty)
    }

    func testBenchmarkNotAvailableByDefault() async {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-bridge-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let bridge = TrainingBridge(
            uvPath: "/usr/bin/false",
            orchestratorScriptsDir: tmpDir,
            dataBridgeScriptsDir: tmpDir
        )
        let available = await bridge.isBenchmarkAvailable
        XCTAssertFalse(available, "Benchmark should not be available without setBenchmarkPath()")
    }
}
