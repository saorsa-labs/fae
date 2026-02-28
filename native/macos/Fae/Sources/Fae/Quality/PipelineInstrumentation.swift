import Foundation

/// Lightweight instrumentation actor for recording pipeline stage timings.
///
/// Called by PipelineCoordinator at stage boundaries. Records to QualityMetricStore
/// when wired; otherwise timing calls are no-ops.
actor PipelineInstrumentation {
    private var store: QualityMetricStore?
    private var turnStartTime: Date?
    private var sttStartTime: Date?
    private var llmStartTime: Date?
    private var ttsStartTime: Date?

    func configure(store: QualityMetricStore) {
        self.store = store
    }

    // MARK: - Turn

    func markTurnStart() {
        turnStartTime = Date()
    }

    func markTurnEnd() {
        guard let start = turnStartTime else { return }
        let duration = Date().timeIntervalSince(start) * 1000
        recordMetric(.endToEndLatencyMs, value: duration)
        turnStartTime = nil
    }

    // MARK: - STT

    func markSTTStart() {
        sttStartTime = Date()
    }

    func markSTTEnd(durationMs: Double? = nil) {
        let duration: Double
        if let provided = durationMs {
            duration = provided
        } else if let start = sttStartTime {
            duration = Date().timeIntervalSince(start) * 1000
        } else {
            return
        }
        recordMetric(.sttLatencyMs, value: duration)
        sttStartTime = nil
    }

    // MARK: - LLM

    func markLLMStart() {
        llmStartTime = Date()
    }

    func markLLMFirstToken(latencyMs: Double? = nil) {
        let latency: Double
        if let provided = latencyMs {
            latency = provided
        } else if let start = llmStartTime {
            latency = Date().timeIntervalSince(start) * 1000
        } else {
            return
        }
        recordMetric(.llmFirstTokenMs, value: latency)
    }

    func markLLMEnd(durationMs: Double? = nil, tokenCount: Int? = nil) {
        let duration: Double
        if let provided = durationMs {
            duration = provided
        } else if let start = llmStartTime {
            duration = Date().timeIntervalSince(start) * 1000
        } else {
            return
        }
        recordMetric(.llmTotalMs, value: duration)

        if let tokens = tokenCount, duration > 0 {
            let tokensPerSecond = Double(tokens) / (duration / 1000)
            recordMetric(.llmTokensPerSecond, value: tokensPerSecond)
        }
        llmStartTime = nil
    }

    // MARK: - TTS

    func markTTSStart() {
        ttsStartTime = Date()
    }

    func markTTSFirstChunk(latencyMs: Double? = nil) {
        let latency: Double
        if let provided = latencyMs {
            latency = provided
        } else if let start = ttsStartTime {
            latency = Date().timeIntervalSince(start) * 1000
        } else {
            return
        }
        recordMetric(.ttsFirstChunkMs, value: latency)
    }

    func markTTSEnd(durationMs: Double? = nil) {
        let duration: Double
        if let provided = durationMs {
            duration = provided
        } else if let start = ttsStartTime {
            duration = Date().timeIntervalSince(start) * 1000
        } else {
            return
        }
        recordMetric(.ttsTotalMs, value: duration)
        ttsStartTime = nil
    }

    // MARK: - Errors

    func markError(stage: String, error: Error) {
        let metric: MetricName
        switch stage {
        case "stt": metric = .sttErrorCount
        case "llm": metric = .llmErrorCount
        case "tts": metric = .ttsErrorCount
        case "tool": metric = .toolErrorCount
        default: return
        }
        recordMetric(metric, value: 1, context: error.localizedDescription)
    }

    // MARK: - Private

    private func recordMetric(_ name: MetricName, value: Double, context: String? = nil) {
        guard let store else { return }
        let record = QualityMetricRecord(metricName: name, value: value, context: context)
        Task {
            try? await store.record(metric: record)
        }
    }
}
