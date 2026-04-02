import Foundation

// MARK: - Types

/// Errors from training bridge operations.
enum TrainingBridgeError: Error, LocalizedError, Sendable {
    /// The uv Python runtime is not installed or not found.
    case uvNotAvailable
    /// A required Python script was not found in the skill bundle.
    case scriptNotFound(String)
    /// Script exited with a non-zero exit code.
    case executionFailed(exitCode: Int32, stderr: String)
    /// Failed to parse JSON output from a training script.
    case parseError(String)
    /// Training did not complete within the allowed time.
    case timeout(seconds: Int)
    /// Not enough data to run training (below minimum thresholds).
    case insufficientData(sftExamples: Int, dpoPairs: Int)

    var errorDescription: String? {
        switch self {
        case .uvNotAvailable:
            return "uv Python runtime not available — install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
        case .scriptNotFound(let name):
            return "Training script not found: \(name)"
        case .executionFailed(let code, let stderr):
            return "Script failed (exit \(code)): \(stderr.prefix(500))"
        case .parseError(let detail):
            return "Failed to parse script output: \(detail)"
        case .timeout(let seconds):
            return "Training did not complete within \(seconds)s"
        case .insufficientData(let sft, let dpo):
            return "Insufficient training data: \(sft) SFT examples, \(dpo) DPO pairs"
        }
    }
}

/// Result of exporting training data from fae.db.
struct ExportResult: Sendable {
    /// Number of SFT training examples exported.
    let sftExamples: Int
    /// Number of DPO preference pairs exported.
    let dpoPairs: Int
    /// Map of output type to file path (e.g. "sft_export" → "/path/to/train.jsonl").
    let outputFiles: [String: String]
}

/// Training mode: supervised fine-tuning or direct preference optimization.
enum TrainingMode: String, Sendable {
    case sft
    case dpo
}

/// Result of launching a training run via mlx-tune.
struct TrainingLaunchResult: Sendable {
    /// PID of the detached training worker process.
    let pid: Int
    /// Directory where the adapter will be written.
    let adapterPath: String
    /// HuggingFace model ID being fine-tuned.
    let modelId: String
    /// Training mode used.
    let mode: TrainingMode
}

/// Status of a running training job.
enum TrainingStatus: Sendable {
    /// Training worker is still running.
    case running(pid: Int)
    /// Training completed; adapter is at the given path.
    case completed(adapterPath: String)
    /// Worker is not running and no adapter was found.
    case notRunning
}

/// Result of evaluating a trained adapter (loss-based proxy score from evaluate.py).
struct TrainingEvalResult: Sendable {
    /// Quality score (0.0–1.0) derived from final training loss.
    let score: Double
    /// Final training loss from the training run.
    let finalLoss: Double
    /// Recommendation: "upgrade" or "skip".
    let recommendation: String
    /// Path to the evaluated adapter directory.
    let adapterPath: String
}

/// Result of running FaeBenchmark for accuracy evaluation.
///
/// Maps to the accuracy fields in `ImprovementBaseline` and `ModelTrainingBenchmarkResult`.
struct TrainingBenchmarkResult: Sendable {
    /// Tool calling accuracy (0.0–1.0).
    let toolCallingAccuracy: Double
    /// Fae capability eval accuracy (0.0–1.0).
    let faeCapabilityAccuracy: Double
    /// Assistant fit eval accuracy (0.0–1.0).
    let assistantFitAccuracy: Double
    /// Serialization eval accuracy (0.0–1.0).
    let serializationAccuracy: Double
    /// Average throughput (tokens per second), if measured.
    let avgThroughputTPS: Double?
    /// Model ID benchmarked.
    let modelId: String
    /// Adapter path used (nil = base model).
    let adapterPath: String?

    /// Compute EvalDelta by subtracting a baseline from this result.
    ///
    /// Positive deltas mean this result is better than the baseline.
    func delta(from baseline: TrainingBenchmarkResult) -> EvalDelta {
        EvalDelta(
            toolCallingDelta: (toolCallingAccuracy - baseline.toolCallingAccuracy) * 100.0,
            faeCapabilityDelta: (faeCapabilityAccuracy - baseline.faeCapabilityAccuracy) * 100.0,
            assistantFitDelta: (assistantFitAccuracy - baseline.assistantFitAccuracy) * 100.0,
            serializationDelta: (serializationAccuracy - baseline.serializationAccuracy) * 100.0,
            throughputDelta: {
                guard let a = avgThroughputTPS, let b = baseline.avgThroughputTPS else { return nil }
                return a - b
            }()
        )
    }

    /// Convert to an ImprovementBaseline for storage.
    func toBaseline(feedbackEventCount: Int) -> ImprovementBaseline {
        ImprovementBaseline(
            id: nil,
            measuredAt: ISO8601DateFormatter().string(from: Date()),
            modelID: modelId,
            adapterPath: adapterPath,
            adapterVersion: nil,
            toolCallingAccuracy: toolCallingAccuracy,
            faeCapabilityAccuracy: faeCapabilityAccuracy,
            assistantFitAccuracy: assistantFitAccuracy,
            serializationAccuracy: serializationAccuracy,
            avgThroughputTPS: avgThroughputTPS,
            feedbackEventCount: feedbackEventCount
        )
    }
}

// MARK: - TrainingBridge

/// Bridges the ImprovementCycleCoordinator to the training-orchestrator Python scripts.
///
/// Calls training scripts via `uv run --script`, passing JSON parameters as `argv[1]`.
/// Each script is a PEP 723 inline-dependency Python file that runs in its own venv.
///
/// ## Script locations
/// - Data export: `Resources/Skills/training-data-bridge/scripts/build_dataset.py`
/// - Training: `Resources/Skills/training-orchestrator/scripts/{train,train_dpo,check_status,evaluate}.py`
actor TrainingBridge {

    // MARK: - Configuration

    /// Path to the uv binary.
    private let uvPath: String

    /// Root directory containing the training-orchestrator skill scripts.
    private let orchestratorScriptsDir: URL

    /// Root directory containing the training-data-bridge skill scripts.
    private let dataBridgeScriptsDir: URL

    /// Optional path to a pre-built FaeBenchmark binary.
    ///
    /// When set, `runBenchmark()` invokes this binary directly. When nil,
    /// benchmark evaluation is skipped and the coordinator falls back to loss-based proxy.
    /// Build with: `swift build --product FaeBenchmark` then copy `.build/debug/FaeBenchmark`.
    private var benchmarkPath: String?

    // MARK: - Init

    /// Create a bridge with explicit paths (for testing).
    ///
    /// - Parameters:
    ///   - uvPath: Absolute path to the uv binary.
    ///   - orchestratorScriptsDir: Directory containing train.py, check_status.py, evaluate.py.
    ///   - dataBridgeScriptsDir: Directory containing build_dataset.py.
    init(
        uvPath: String,
        orchestratorScriptsDir: URL,
        dataBridgeScriptsDir: URL
    ) {
        self.uvPath = uvPath
        self.orchestratorScriptsDir = orchestratorScriptsDir
        self.dataBridgeScriptsDir = dataBridgeScriptsDir
    }

    /// Create a bridge using runtime defaults (UVRuntime + app bundle).
    ///
    /// - Throws: `TrainingBridgeError.uvNotAvailable` if uv is not installed.
    ///           `TrainingBridgeError.scriptNotFound` if skill directories are missing.
    static func createDefault() async throws -> TrainingBridge {
        guard let uv = await UVRuntime.shared.path() else {
            throw TrainingBridgeError.uvNotAvailable
        }

        guard let skillsRoot = Bundle.faeResources.url(forResource: "Skills", withExtension: nil) else {
            throw TrainingBridgeError.scriptNotFound("Skills resource directory")
        }

        let orchestratorDir = skillsRoot
            .appendingPathComponent("training-orchestrator")
            .appendingPathComponent("scripts")
        let dataBridgeDir = skillsRoot
            .appendingPathComponent("training-data-bridge")
            .appendingPathComponent("scripts")

        guard FileManager.default.fileExists(atPath: orchestratorDir.path) else {
            throw TrainingBridgeError.scriptNotFound("training-orchestrator/scripts")
        }
        guard FileManager.default.fileExists(atPath: dataBridgeDir.path) else {
            throw TrainingBridgeError.scriptNotFound("training-data-bridge/scripts")
        }

        return TrainingBridge(
            uvPath: uv,
            orchestratorScriptsDir: orchestratorDir,
            dataBridgeScriptsDir: dataBridgeDir
        )
    }

    // MARK: - Script Execution

    /// Run a Python script via `uv run --script`, passing params as argv[1] JSON.
    ///
    /// - Parameters:
    ///   - scriptURL: Absolute URL to the Python script.
    ///   - params: Dictionary serialized to JSON and passed as argv[1].
    ///   - timeoutSeconds: Maximum wall-clock time before the process is killed.
    /// - Returns: Parsed JSON dictionary from stdout.
    private func runScript(
        scriptURL: URL,
        params: [String: Any] = [:],
        timeoutSeconds: Int = 300
    ) async throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw TrainingBridgeError.scriptNotFound(scriptURL.lastPathComponent)
        }

        let jsonData = try JSONSerialization.data(withJSONObject: params)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw TrainingBridgeError.parseError("Failed to serialize params to JSON")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--script", scriptURL.path, jsonString]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        // Minimal environment.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = [
            "PATH": "\(home)/.local/bin:\(home)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Timeout handling: cancel if the process exceeds the time limit.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            // Check if terminated by signal (timeout).
            if process.terminationReason == .uncaughtSignal {
                throw TrainingBridgeError.timeout(seconds: timeoutSeconds)
            }
            throw TrainingBridgeError.executionFailed(
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            let rawOutput = String(data: stdoutData, encoding: .utf8) ?? "<non-utf8>"
            throw TrainingBridgeError.parseError(
                "Expected JSON object, got: \(rawOutput.prefix(200))"
            )
        }

        // Unwrap JSON-RPC result envelope if present (build_dataset.py uses this).
        if let result = parsed["result"] as? [String: Any] {
            return result
        }
        return parsed
    }

    /// Resolve a script URL from the orchestrator scripts directory.
    private func orchestratorScript(_ name: String) -> URL {
        orchestratorScriptsDir.appendingPathComponent(name)
    }

    /// Resolve a script URL from the data bridge scripts directory.
    private func dataBridgeScript(_ name: String) -> URL {
        dataBridgeScriptsDir.appendingPathComponent(name)
    }

    // MARK: - Data Export

    /// Export SFT and DPO training data from the memory database.
    ///
    /// Calls `build_dataset.py` from the training-data-bridge skill, which reads
    /// episode and correction records from fae.db and writes JSONL files.
    ///
    /// - Parameters:
    ///   - dbPath: Path to fae.db. Defaults to the standard FaeDirectories location.
    ///   - outputDir: Directory for output JSONL files. Defaults to training/data/.
    ///   - afterTimestamp: Only export records created after this ISO-8601 timestamp.
    /// - Returns: Export statistics and output file paths.
    func exportTrainingData(
        dbPath: String? = nil,
        outputDir: String? = nil,
        afterTimestamp: String? = nil
    ) async throws -> ExportResult {
        var params: [String: Any] = [:]
        params["db_path"] = dbPath ?? FaeDirectories.database.path
        params["output_dir"] = outputDir ?? FaeDirectories.trainingDataDirectory.path
        if let ts = afterTimestamp {
            params["after_timestamp"] = ts
        }

        let result = try await runScript(
            scriptURL: dataBridgeScript("build_dataset.py"),
            params: params,
            timeoutSeconds: 120
        )

        let sft = result["sft_examples"] as? Int ?? 0
        let dpo = result["dpo_pairs"] as? Int ?? 0
        let files = result["output_files"] as? [String: String] ?? [:]

        return ExportResult(sftExamples: sft, dpoPairs: dpo, outputFiles: files)
    }

    // MARK: - Training

    /// Launch a training run as a detached process.
    ///
    /// The training worker runs independently and writes its adapter to disk. Use
    /// `checkTrainingStatus()` or `pollUntilComplete()` to monitor progress.
    ///
    /// - Parameters:
    ///   - mode: Training mode (SFT or DPO).
    ///   - targetModelPreset: Model size preset ("auto", "tiny", "small", "medium").
    ///   - trainingPreset: Training intensity ("smoke", "light", "standard", "deep").
    /// - Returns: Launch metadata including the worker PID and expected adapter path.
    func launchTraining(
        mode: TrainingMode = .sft,
        targetModelPreset: String = "auto",
        trainingPreset: String = "light"
    ) async throws -> TrainingLaunchResult {
        let scriptName: String
        switch mode {
        case .sft: scriptName = "train.py"
        case .dpo: scriptName = "train_dpo.py"
        }

        let params: [String: Any] = [
            "target_model_preset": targetModelPreset,
            "training_preset": trainingPreset,
        ]

        let result = try await runScript(
            scriptURL: orchestratorScript(scriptName),
            params: params,
            timeoutSeconds: 600
        )

        guard let pid = result["pid"] as? Int else {
            throw TrainingBridgeError.parseError("Missing 'pid' in training launch result")
        }
        guard let adapterPath = result["adapter_path"] as? String else {
            throw TrainingBridgeError.parseError("Missing 'adapter_path' in training launch result")
        }
        let modelId = result["model_id"] as? String ?? "unknown"

        return TrainingLaunchResult(
            pid: pid,
            adapterPath: adapterPath,
            modelId: modelId,
            mode: mode
        )
    }

    /// Check if a training run is still active.
    ///
    /// Reads `run.json` via `check_status.py` to determine whether the worker PID
    /// is still alive and whether an adapter has been produced.
    func checkTrainingStatus() async throws -> TrainingStatus {
        let result = try await runScript(
            scriptURL: orchestratorScript("check_status.py"),
            timeoutSeconds: 30
        )

        let running = result["running"] as? Bool ?? false
        if running {
            let pid = result["pid"] as? Int ?? 0
            return .running(pid: pid)
        }

        if let adapterPath = result["adapter_path"] as? String, !adapterPath.isEmpty {
            // Verify the adapter actually exists on disk.
            let adapterDir = URL(fileURLWithPath: adapterPath)
            let safetensors = adapterDir.appendingPathComponent("adapters.safetensors")
            if FileManager.default.fileExists(atPath: safetensors.path) {
                return .completed(adapterPath: adapterPath)
            }
        }

        return .notRunning
    }

    /// Poll `check_status.py` until training completes or times out.
    ///
    /// - Parameters:
    ///   - intervalSeconds: Seconds between status polls.
    ///   - maxWaitSeconds: Maximum total wait time before throwing `.timeout`.
    /// - Returns: Path to the completed adapter directory.
    func pollUntilComplete(
        intervalSeconds: Int = 30,
        maxWaitSeconds: Int = 7200
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSeconds))

        while Date() < deadline {
            try Task.checkCancellation()

            let status = try await checkTrainingStatus()
            switch status {
            case .completed(let path):
                return path
            case .running:
                try await Task.sleep(for: .seconds(intervalSeconds))
            case .notRunning:
                // Worker exited — check if adapter was produced anyway.
                let evalResult = try? await evaluateAdapter()
                if let path = evalResult?.adapterPath, !path.isEmpty {
                    return path
                }
                // Genuinely no adapter produced.
                throw TrainingBridgeError.executionFailed(
                    exitCode: -1,
                    stderr: "Training worker exited without producing an adapter"
                )
            }
        }

        throw TrainingBridgeError.timeout(seconds: maxWaitSeconds)
    }

    // MARK: - Evaluation

    /// Evaluate a trained adapter using the loss-based proxy score.
    ///
    /// Calls `evaluate.py`, which reads `train_metrics.json` from the adapter directory
    /// and computes a quality score from the final training loss.
    ///
    /// - Parameter adapterPath: Path to the adapter directory. If nil, reads from `run.json`.
    /// - Returns: Evaluation results including score and recommendation.
    func evaluateAdapter(adapterPath: String? = nil) async throws -> TrainingEvalResult {
        var params: [String: Any] = [:]
        if let path = adapterPath {
            params["adapter_path"] = path
        }

        let result = try await runScript(
            scriptURL: orchestratorScript("evaluate.py"),
            params: params,
            timeoutSeconds: 60
        )

        let score = result["score"] as? Double ?? 0.0
        let finalLoss = result["final_training_loss"] as? Double ?? 999.0
        let recommendation = result["recommendation"] as? String ?? "skip"
        let path = result["adapter_path"] as? String ?? adapterPath ?? ""

        return TrainingEvalResult(
            score: score,
            finalLoss: finalLoss,
            recommendation: recommendation,
            adapterPath: path
        )
    }

    // MARK: - Benchmark

    /// Set the path to a pre-built FaeBenchmark binary.
    ///
    /// Build with: `cd native/macos/Fae && swift build --product FaeBenchmark`
    /// Binary at: `.build/debug/FaeBenchmark` or `.build/release/FaeBenchmark`
    func setBenchmarkPath(_ path: String) {
        benchmarkPath = path
    }

    /// Whether benchmark evaluation is available.
    var isBenchmarkAvailable: Bool {
        guard let path = benchmarkPath else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Run FaeBenchmark to measure model accuracy with optional LoRA adapter.
    ///
    /// Invokes the pre-built FaeBenchmark binary with `--tools` (tool calling accuracy)
    /// plus intelligence/capability/serialization evals. Writes JSON to a temp file
    /// and parses the accuracy metrics.
    ///
    /// - Parameter adapterPath: Path to LoRA adapter directory. Nil = base model only.
    /// - Returns: Parsed accuracy metrics.
    /// - Throws: `TrainingBridgeError.scriptNotFound` if benchmark binary not configured.
    func runBenchmark(adapterPath: String? = nil) async throws -> TrainingBenchmarkResult {
        guard let binPath = benchmarkPath, FileManager.default.isExecutableFile(atPath: binPath) else {
            throw TrainingBridgeError.scriptNotFound("FaeBenchmark binary not configured — set via setBenchmarkPath()")
        }

        let outputFile = FaeDirectories.trainingDirectory
            .appendingPathComponent("benchmark_\(UUID().uuidString).json")

        var arguments = [
            "--model", "auto",
            "--tools",
            "--fae-capabilities",
            "--assistant-fit",
            "--serialization",
            "--output", outputFile.path,
        ]
        if let adapter = adapterPath {
            arguments.append(contentsOf: ["--adapter", adapter])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = [
            "PATH": "\(home)/.local/bin:\(home)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            "TMPDIR": NSTemporaryDirectory(),
        ]

        try process.run()

        // Benchmark can take 10-30 minutes for full eval.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(3600))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        guard process.terminationStatus == 0 else {
            throw TrainingBridgeError.executionFailed(
                exitCode: process.terminationStatus,
                stderr: "FaeBenchmark exited with code \(process.terminationStatus)"
            )
        }

        // Parse the JSON output file.
        guard let jsonData = try? Data(contentsOf: outputFile) else {
            throw TrainingBridgeError.parseError("Benchmark output file not found at \(outputFile.path)")
        }

        // Clean up temp file.
        try? FileManager.default.removeItem(at: outputFile)

        return try parseBenchmarkOutput(jsonData, adapterPath: adapterPath)
    }

    /// Parse FaeBenchmark JSON output into a TrainingBenchmarkResult.
    ///
    /// Expects the `BenchmarkOutput` schema with a `models` array.
    /// Takes the first model's accuracy metrics.
    private func parseBenchmarkOutput(_ data: Data, adapterPath: String?) throws -> TrainingBenchmarkResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrainingBridgeError.parseError("Invalid JSON in benchmark output")
        }

        guard let modelsArray = json["models"] as? [[String: Any]],
              let model = modelsArray.first else {
            throw TrainingBridgeError.parseError("No models in benchmark output")
        }

        // Compute tool calling accuracy.
        let toolCalling = model["tool_calling"] as? [[String: Any]] ?? []
        let toolCorrect = toolCalling.filter { $0["correct"] as? Bool == true }.count
        let toolTotal = max(toolCalling.count, 1)
        let toolAcc = Double(toolCorrect) / Double(toolTotal)

        // Compute intelligence eval accuracies.
        let faeCapability = model["fae_capability_eval"] as? [[String: Any]] ?? []
        let faeCorrect = faeCapability.filter { $0["correct"] as? Bool == true }.count
        let faeTotal = max(faeCapability.count, 1)
        let faeAcc = Double(faeCorrect) / Double(faeTotal)

        let assistantFit = model["assistant_fit_eval"] as? [[String: Any]] ?? []
        let assistantCorrect = assistantFit.filter { $0["correct"] as? Bool == true }.count
        let assistantTotal = max(assistantFit.count, 1)
        let assistantAcc = Double(assistantCorrect) / Double(assistantTotal)

        let serialization = model["serialization_eval"] as? [[String: Any]] ?? []
        let serCorrect = serialization.filter {
            ($0["valid"] as? Bool == true) && ($0["correct"] as? Bool == true)
        }.count
        let serTotal = max(serialization.count, 1)
        let serAcc = Double(serCorrect) / Double(serTotal)

        // Compute average throughput from no-think runs if available.
        let throughput = model["throughput_no_think"] as? [[String: Any]] ?? []
        let avgTPS: Double? = throughput.isEmpty ? nil : {
            let tpsValues = throughput.compactMap { $0["tokens_per_second"] as? Double }
            guard !tpsValues.isEmpty else { return nil as Double? }
            return tpsValues.reduce(0, +) / Double(tpsValues.count)
        }()

        let modelId = model["model_id"] as? String ?? "unknown"

        return TrainingBenchmarkResult(
            toolCallingAccuracy: toolAcc,
            faeCapabilityAccuracy: faeAcc,
            assistantFitAccuracy: assistantAcc,
            serializationAccuracy: serAcc,
            avgThroughputTPS: avgTPS,
            modelId: modelId,
            adapterPath: adapterPath
        )
    }
}
