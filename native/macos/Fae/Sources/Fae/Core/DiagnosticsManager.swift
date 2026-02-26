import Foundation

/// Runtime diagnostics and health monitoring.
///
/// Replaces: `src/diagnostics/` (2,000 lines)
@MainActor
final class DiagnosticsManager: ObservableObject {
    @Published var healthStatus: HealthStatus = HealthStatus()

    struct HealthStatus: Sendable {
        var sttLoaded: Bool = false
        var llmLoaded: Bool = false
        var ttsLoaded: Bool = false
        var pipelineRunning: Bool = false
        var memoryRecordCount: Int = 0
        var uptimeSeconds: TimeInterval = 0
    }

    private var startTime = Date()

    func update(
        sttLoaded: Bool,
        llmLoaded: Bool,
        ttsLoaded: Bool,
        pipelineRunning: Bool,
        memoryRecordCount: Int
    ) {
        healthStatus = HealthStatus(
            sttLoaded: sttLoaded,
            llmLoaded: llmLoaded,
            ttsLoaded: ttsLoaded,
            pipelineRunning: pipelineRunning,
            memoryRecordCount: memoryRecordCount,
            uptimeSeconds: Date().timeIntervalSince(startTime)
        )
    }

    var summary: String {
        let h = healthStatus
        return """
            STT: \(h.sttLoaded ? "loaded" : "not loaded")
            LLM: \(h.llmLoaded ? "loaded" : "not loaded")
            TTS: \(h.ttsLoaded ? "loaded" : "not loaded")
            Pipeline: \(h.pipelineRunning ? "running" : "stopped")
            Memory: \(h.memoryRecordCount) records
            Uptime: \(Int(h.uptimeSeconds))s
            """
    }
}
