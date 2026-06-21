import Foundation

/// The on-disk form of a trained adapter — determines which evaluator (P9/C4)
/// and which deploy path can consume it.
enum AdapterKind: String, Sendable, Codable {
    /// A GGUF the llama.cpp daemon loads via `engine.reload` (PEFT/daemon lane).
    case gguf
    /// An MLX adapter directory loaded by the in-process MLX engine (mlx-tune lane).
    case mlxDir
}

/// A freshly trained adapter awaiting evaluation. Carries the artifact `kind` so
/// the eval gate and deploy path (P9/C4) pick lane-appropriate handling.
struct AdapterCandidate: Sendable {
    let path: String
    let kind: AdapterKind
    /// Final training loss when the backend reports it (PEFT lane); nil for the
    /// detached mlx-tune lane, which doesn't surface a loss synchronously.
    let finalLoss: Double?
}

/// Errors surfaced by a training backend.
enum TrainingBackendError: Error, LocalizedError, CustomStringConvertible {
    /// A required exported dataset artifact (e.g. `sft_export`) was absent.
    case missingDataset(String)

    var description: String {
        switch self {
        case .missingDataset(let key): return "missing dataset artifact: \(key)"
        }
    }

    /// Mirror `description` so `localizedDescription` is meaningful when this
    /// error reaches a generic `catch` (not an opaque NSError string).
    var errorDescription: String? { description }
}

/// P9/C1 — the seam over the concrete training lanes.
///
/// `ImprovementCycleCoordinator` selects a backend and calls `trainAdapter`; the
/// lane mechanics stay in `TrainingBridge`. This makes the lane swap explicit and
/// unit-testable, and the returned `AdapterCandidate.kind` drives the C4 evaluator
/// + deploy gate. Conformers today: `MlxTuneBackend` (Apple MLX dir) and
/// `PeftDaemonBackend` (portable PEFT → GGUF for the llama.cpp daemon). A
/// CUDA-only `UnslothBackend` is a planned future conformer — not implemented.
protocol TrainingBackend: Sendable {
    /// Stable identifier for logs/receipts (e.g. "mlx", "peft").
    var id: String { get }
    /// Train and produce a deployable adapter candidate from an exported dataset.
    func trainAdapter(export: ExportResult) async throws -> AdapterCandidate
}

/// mlx-tune lane: detached SFT/DPO training producing an MLX adapter directory.
struct MlxTuneBackend: TrainingBackend {
    let bridge: TrainingBridge
    var id: String { "mlx" }

    func trainAdapter(export: ExportResult) async throws -> AdapterCandidate {
        let mode: TrainingMode = export.dpoPairs >= 5 ? .dpo : .sft
        let launch = try await bridge.launchTraining(mode: mode)
        NSLog(
            "MlxTuneBackend: training started (pid=%d, model=%@, mode=%@)",
            launch.pid, launch.modelId, mode.rawValue
        )
        let path = try await bridge.pollUntilComplete()
        return AdapterCandidate(path: path, kind: .mlxDir, finalLoss: nil)
    }
}

/// PEFT/daemon lane: train a portable PEFT adapter and convert it to a GGUF the
/// llama.cpp daemon loads via `engine.reload` (P3/C3).
struct PeftDaemonBackend: TrainingBackend {
    let bridge: TrainingBridge
    let baseModel: String
    var id: String { "peft" }

    func trainAdapter(export: ExportResult) async throws -> AdapterCandidate {
        guard let sftPath = export.outputFiles["sft_export"] else {
            throw TrainingBackendError.missingDataset("sft_export")
        }
        let peft = try await bridge.trainPeftAndConvert(sftPath: sftPath, baseModel: baseModel)
        NSLog(
            "PeftDaemonBackend: training complete — gguf=%@ loss=%.4g",
            peft.ggufPath, peft.finalLoss
        )
        return AdapterCandidate(path: peft.ggufPath, kind: .gguf, finalLoss: peft.finalLoss)
    }
}
