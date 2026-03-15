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
            description: "Picks the best model for your Mac's RAM: 35B-A3B MoE on 32+ GB, 4B on 16+ GB, saorsa-1.1-tiny below."
        ),
        .init(
            label: "saorsa-1.1-tiny (2B)",
            value: "saorsa_1_1_tiny",
            ram: "8+ GB",
            description: "Our fine-tuned Qwen3.5-2B. Compact, fast inference, strong tool use. Best for Macs with limited RAM."
        ),
        .init(
            label: "Qwen3.5 4B",
            value: "qwen3_5_4b",
            ram: "16+ GB",
            description: "Best balance for Fae: strong tool use, good latency, and enough headroom for on-demand vision."
        ),
        .init(
            label: "Qwen3.5 35B-A3B (MoE)",
            value: "qwen3_5_35b_a3b",
            ram: "32+ GB",
            description: "Flagship model. 35B total with only 3B active per token — frontier intelligence at fast speed. Natively multimodal (text + vision). Recommended for 32+ GB Macs."
        ),
    ]

    static let visionOptions: [VisionOption] = [
        .init(
            label: "Auto",
            value: "auto",
            description: "Best vision for your RAM: 35B-A3B (shared with text LLM) on 32+ GB, Qwen3-VL-4B on 16+ GB."
        ),
        .init(
            label: "Qwen3.5 35B-A3B (shared)",
            value: "qwen3_5_35b_a3b_vlm",
            description: "Frontier multimodal vision using the same 35B-A3B text model — zero additional RAM. Requires 32+ GB."
        ),
        .init(
            label: "Qwen3-VL-4B (4-bit)",
            value: "qwen3_vl_4b_4bit",
            description: "Lightweight on-demand vision model. Best for 16-31 GB systems alongside the 4B text model."
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
