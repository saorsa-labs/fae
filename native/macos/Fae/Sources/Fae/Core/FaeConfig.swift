import Foundation

/// Application configuration, loaded from `config.toml`.
///
/// Replaces: `src/config.rs`
struct FaeConfig: Codable {

    var audio: AudioConfig = AudioConfig()
    var vad: VadConfig = VadConfig()
    var llm: LlmConfig = LlmConfig()
    var tts: TtsConfig = TtsConfig()
    var stt: SttConfig = SttConfig()
    var conversation: ConversationConfig = ConversationConfig()
    var bargeIn: BargeInConfig = BargeInConfig()
    var memory: MemoryConfig = MemoryConfig()
    var userName: String?
    var onboarded: Bool = false

    // MARK: - Audio

    struct AudioConfig: Codable {
        var inputSampleRate: Int = 16_000
        var outputSampleRate: Int = 24_000
        var inputChannels: Int = 1
        var bufferSize: Int = 512
    }

    // MARK: - VAD

    struct VadConfig: Codable {
        var threshold: Float = 0.008
        var hysteresisRatio: Float = 0.6
        var minSilenceDurationMs: Int = 1000
        var speechPadMs: Int = 30
        var minSpeechDurationMs: Int = 250
        var maxSpeechDurationMs: Int = 15_000
    }

    // MARK: - LLM

    struct LlmConfig: Codable {
        var maxTokens: Int = 512
        var contextSizeTokens: Int = 16_384
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var topK: Int = 40
        var repeatPenalty: Float = 1.1
        var maxHistoryMessages: Int = 10
        var voiceModelPreset: String = "auto"
        var enableVision: Bool = false
    }

    // MARK: - TTS

    struct TtsConfig: Codable {
        var voice: String = "fae"
        var speed: Float = 1.1
        var sampleRate: Int = 24_000
    }

    // MARK: - STT

    struct SttConfig: Codable {
        var modelId: String = "mlx-community/Qwen3-ASR-0.6B-4bit"
    }

    // MARK: - Conversation

    struct ConversationConfig: Codable {
        var wakeWord: String = "hi fae"
        var enabled: Bool = true
        var idleTimeoutS: Int = 0
        var requireDirectAddress: Bool = false
        var directAddressFollowupS: Int = 20
        var sleepPhrases: [String] = [
            "shut up", "stop fae", "go to sleep",
            "that will do fae", "that'll do fae",
            "quiet fae", "sleep fae", "goodbye fae", "bye fae",
        ]
    }

    // MARK: - Barge-In

    struct BargeInConfig: Codable {
        var enabled: Bool = true
        var minRms: Float = 0.05
        var confirmMs: Int = 150
        var assistantStartHoldoffMs: Int = 500
        var bargeInSilenceMs: Int = 600
    }

    // MARK: - Memory

    struct MemoryConfig: Codable {
        var enabled: Bool = true
        var maxRecallResults: Int = 5
    }

    // MARK: - Model Selection

    /// Select the appropriate LLM model based on system RAM and preset.
    ///
    /// Returns `(modelId, contextSize)` for MLX loading.
    static func recommendedModel(
        totalMemoryBytes: UInt64? = nil,
        preset: String = "auto"
    ) -> (modelId: String, contextSize: Int) {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

        switch preset.lowercased() {
        case "qwen3_5_35b_a3b":
            return ("mlx-community/Qwen3.5-35B-A3B-4bit", 65_536)
        case "qwen3_8b":
            return ("mlx-community/Qwen3-8B-4bit", 32_768)
        case "qwen3_4b":
            return ("mlx-community/Qwen3-4B-4bit", 16_384)
        case "qwen3_1_7b":
            return ("mlx-community/Qwen3-1.7B-4bit", 8_192)
        case "qwen3_0_6b":
            return ("mlx-community/Qwen3-0.6B-4bit", 4_096)
        default: // "auto"
            if totalGB >= 64 {
                return ("mlx-community/Qwen3.5-35B-A3B-4bit", 65_536)
            } else if totalGB >= 48 {
                return ("mlx-community/Qwen3-8B-4bit", 32_768)
            } else if totalGB >= 32 {
                return ("mlx-community/Qwen3-4B-4bit", 16_384)
            } else {
                return ("mlx-community/Qwen3-1.7B-4bit", 8_192)
            }
        }
    }

    // MARK: - Persistence

    /// Config file path: ~/Library/Application Support/fae/config.toml
    static var configFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("fae/config.toml")
    }

    /// Load config from disk. Returns default if file doesn't exist.
    static func load() -> FaeConfig {
        // TODO: Phase 1+ — parse config.toml with TOMLKit
        return FaeConfig()
    }

    /// Save config to disk.
    func save() throws {
        // TODO: Phase 1+ — serialize to TOML with TOMLKit
        let dir = Self.configFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSLog("FaeConfig: save() — stub")
    }
}
