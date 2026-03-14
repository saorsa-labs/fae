import Foundation
import FaeInference

struct LocalModelCatalog {
    struct VoiceOption {
        let label: String
        let value: String
        let ram: String
        let description: String
    }

    struct VisionOption {
        let label: String
        let value: String
        let description: String
    }

    static let voiceOptions: [VoiceOption] = [
        .init(
            label: "Auto (Recommended)",
            value: "auto",
            ram: "8+ GB",
            description: "Picks Qwen3.5 2B, 4B, or 9B based on this Mac's RAM. Recommended for most users."
        ),
        .init(
            label: "Qwen3.5 2B",
            value: "qwen3_5_2b",
            ram: "8+ GB",
            description: "Lowest-memory fallback. Best when you need a compact local model."
        ),
        .init(
            label: "Qwen3.5 4B",
            value: "qwen3_5_4b",
            ram: "16+ GB",
            description: "Best default balance for Fae: strong tool use, good latency, and enough headroom for on-demand vision."
        ),
        .init(
            label: "Qwen3.5 9B",
            value: "qwen3_5_9b",
            ram: "24+ GB",
            description: "Best current loadable quality/runtime balance in Fae's Swift stack. Better reasoning and tool behavior than 4B, while remaining responsive enough for daily use."
        ),
        .init(
            label: "Qwen3.5 27B",
            value: "qwen3_5_27b",
            ram: "32+ GB",
            description: "Highest local quality tier currently supported by Fae's native Swift runtime. Best for larger-RAM Macs when you explicitly want higher quality over first-turn latency."
        ),
    ]

    static let visionOptions: [VisionOption] = [
        .init(
            label: "Auto",
            value: "auto",
            description: "Selects the recommended Qwen3-VL tier for your RAM: 4-bit from 16 GB, 8-bit from 32 GB."
        ),
        .init(
            label: "Qwen3-VL-4B (8-bit)",
            value: "qwen3_vl_4b_8bit",
            description: "Higher-quality on-demand vision model. Best for 32+ GB systems."
        ),
        .init(
            label: "Qwen3-VL-4B (4-bit)",
            value: "qwen3_vl_4b_4bit",
            description: "Lower-memory on-demand vision model. Best for 16-31 GB systems or tighter RAM."
        ),
    ]

    static func voiceCacheStatus(for preset: String) -> (text: String, cached: Bool)? {
        let modelID = FaeConfig.recommendedModel(preset: preset).modelId
        return cacheStatus(for: modelID)
    }

    static func visionCacheStatus(for preset: String) -> (text: String, cached: Bool)? {
        guard let modelID = FaeConfig.recommendedVLMModel(preset: preset)?.modelId else {
            return nil
        }
        return cacheStatus(for: modelID)
    }

    private static func cacheStatus(for modelID: String) -> (text: String, cached: Bool) {
        let cached = isModelCached(modelID: modelID)
        if cached {
            return ("Cached locally: \(modelID)", true)
        }
        return ("Not cached locally. Fae will download \(modelID) when you switch.", false)
    }

    static func isModelCached(modelID: String) -> Bool {
        localModelDirectoryURL(from: modelID) != nil
    }
}
