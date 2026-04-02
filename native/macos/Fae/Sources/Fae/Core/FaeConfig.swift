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
    var streamingASR: StreamingASRConfig = StreamingASRConfig()
    var conversation: ConversationConfig = ConversationConfig()
    var bargeIn: BargeInConfig = BargeInConfig()
    var memory: MemoryConfig = MemoryConfig()
    var speaker: SpeakerConfig = SpeakerConfig()
    var voiceIdentity: VoiceIdentityConfig = VoiceIdentityConfig()
    var channels: ChannelsConfig = ChannelsConfig()
    var scheduler: SchedulerConfig = SchedulerConfig()
    var skills: SkillsConfig = SkillsConfig()
    var vision: VisionConfig = VisionConfig()
    var awareness: AwarenessConfig = AwarenessConfig()
    var training = TrainingConfig()
    var agents = AgentConfig()
    var privacy: PrivacyConfig = PrivacyConfig()
    var userName: String?
    var licenseAccepted: Bool = false
    var startupIntroSeen: Bool = false
    var startupIntroSeenConfigured: Bool = false
    var toolMode: String = "full" {
        didSet {
            // Silently migrate legacy tool mode values.
            let migrated = Self.migrateToolMode(toolMode)
            if migrated != toolMode {
                toolMode = migrated
            }
        }
    }

    /// Migrate legacy tool mode strings to the simplified two-mode system.
    static func migrateToolMode(_ mode: String) -> String {
        switch mode {
        case "off", "read_only":
            return "assistant"
        case "read_write", "full_no_approval":
            return "full"
        case "assistant", "full":
            return mode
        default:
            return "full"
        }
    }

    // MARK: - Audio

    struct AudioConfig: Codable {
        var inputSampleRate: Int = 16_000
        var outputSampleRate: Int = 24_000
        var inputChannels: Int = 1
        /// Capture buffer size at the pipeline sample rate.
        /// 576 matches Silero VAD's native 36 ms frame size.
        var bufferSize: Int = 576
    }

    // MARK: - VAD

    struct VadConfig: Codable {
        /// Speech probability threshold for Silero VAD.
        /// Legacy RMS configs used very small values like 0.008; those are migrated
        /// at runtime to the Silero defaults for backward compatibility.
        var threshold: Float = 0.30
        /// Sustain ratio applied while already in speech.
        /// 0.8333 ~= 0.25 / 0.30, a common Silero start/stop pairing.
        var hysteresisRatio: Float = 0.8333333
        var minSilenceDurationMs: Int = 800
        var speechPadMs: Int = 30
        var minSpeechDurationMs: Int = 250
        var maxSpeechDurationMs: Int = 15_000
    }

    // MARK: - LLM

    struct LlmConfig: Codable {
        var maxTokens: Int = 4096
        /// Context size in tokens. 0 = auto (use model-recommended size based on RAM tier).
        var contextSizeTokens: Int = 0
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var topK: Int = 40
        /// Repetition penalty. 0.0 = disabled (no TokenRing overhead).
        /// Previously 1.1, but TokenRing processor adds per-token overhead
        /// (array indexing + MLX.where + multiply/divide per token) that
        /// costs 10-20% TPS on MoE models. Qwen3.5 handles repetition
        /// well without explicit penalty.
        var repeatPenalty: Float = 0.0
        var maxHistoryMessages: Int = 10
        /// Operator / control model preset for the main local pipeline.
        var voiceModelPreset: String = "auto"
        /// Preferred remote provider preset for user-managed external sessions.
        var remoteProviderPreset: String = "openrouter"
        /// Preferred remote base URL for user-managed external sessions.
        var remoteBaseURL: String = "https://openrouter.ai/api"
        /// Preferred remote model for user-managed external sessions.
        var remoteModel: String = "openai/gpt-4.1-mini"
        var enableVision: Bool = false
        /// Legacy compatibility flag for whether deliberate reasoning is enabled.
        /// Kept in sync with `thinkingLevel` when reading and writing config.
        var thinkingEnabled: Bool = false
        /// Conversation reasoning depth.
        /// - fast: minimize explicit reasoning for lower latency.
        /// - balanced: normal reasoning for most work.
        /// - deep: more deliberate reasoning with a larger local response budget.
        var thinkingLevel: String = FaeThinkingLevel.fast.rawValue

        // MARK: KV Cache Optimization (Phase 1)

        /// KV cache quantization bits. 4 = 4x memory savings with encode/decode
        /// overhead. nil = full precision (f16), faster but uses more memory.
        /// Auto-disabled on 64GB+ systems where memory is plentiful.
        var kvQuantBits: Int? = {
            let totalGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
            return totalGB >= 64 ? nil : 4
        }()

        /// Maximum KV cache size in tokens. When set, uses sliding window
        /// (RotatingKVCache) for bounded memory. nil = unlimited.
        var maxKVCacheSize: Int? = nil

        /// Token count after which to begin quantizing KV cache.
        /// Keeps initial context at full precision. Default: 512.
        var kvQuantStartTokens: Int = 512

        /// Quantization group size. Default 64 matches Ollama/mistral.rs.
        var kvGroupSize: Int = 64

        /// Number of tokens for repetition penalty window.
        /// Larger catches more patterns. Default: 64 (up from 20).
        var repetitionContextSize: Int = 64

        /// Prefill chunk size. nil = auto-tune based on model size.
        var prefillStepSize: Int? = nil
    }

    /// True when the effective LLM context window is at or below 16K tokens.
    ///
    /// In lightweight mode the system prompt strips sections the small models cannot
    /// reliably act on (Python scripting, detailed self-modification menu, roleplay,
    /// proactive behaviour), and replaces them with compact, direct tool examples.
    /// This reclaims ~1,100 tokens and gives the model more headroom for generation
    /// and conversation history without changing tool availability.
    ///
    /// Applies to Qwen3.5-2B (and legacy saorsa-1.1-tiny). 4B and larger receive the full prompt.
    var isLightweightContext: Bool {
        let preset = FaeConfig.canonicalVoiceModelPreset(llm.voiceModelPreset)
        switch preset {
        case "qwen3_5_2b":
            return true
        case "auto":
            let totalGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
            return totalGB < 16  // Auto selects Qwen3.5-2B below 16 GB
        default:
            // Also honour manually configured very small contexts (e.g. developer overrides).
            return llm.contextSizeTokens > 0 && llm.contextSizeTokens <= 16_384
        }
    }

    func applyingTestServerMemoryProfile() -> FaeConfig {
        var copy = self
        copy.llm.voiceModelPreset = "qwen3_5_2b"
        copy.llm.contextSizeTokens = min(copy.llm.contextSizeTokens > 0 ? copy.llm.contextSizeTokens : 8_192, 8_192)
        copy.llm.maxKVCacheSize = min(copy.llm.maxKVCacheSize ?? 8_192, 8_192)
        copy.llm.kvQuantBits = copy.llm.kvQuantBits ?? 4
        copy.vision.enabled = false
        copy.vision.modelPreset = "qwen3_vl_4b_4bit"
        return copy
    }

    // MARK: - TTS

    struct TtsConfig: Codable {
        static let bundledFaeReferenceText =
            "Hi David, it's Lauren, also known as Faye apparently. So, things in the garden and what's been happening, I've just fed all the wee birdies. We picked up some GDP primulas on the way down this morning and we went past Dobby's. So, I'm just going to plant them in the planters at the front."

        var voice: String = "fae"
        var modelId: String = "kokoro:fae"
        var speed: Float = 1.1
        var sampleRate: Int = 24_000
        /// Reference audio transcript (legacy, used by Qwen3-TTS ICL voice cloning).
        /// Not used by FaeTTSAdapter / KokoroSwift, which uses pre-computed .bin embeddings.
        var referenceText: String? = TtsConfig.bundledFaeReferenceText
        /// Path to a custom voice WAV file (overrides bundled fae.wav when voiceIdentityLock=false).
        var customVoicePath: String?
        /// Reference text for the custom voice WAV.
        var customReferenceText: String?
        /// When true, force canonical bundled fae.wav at runtime.
        var voiceIdentityLock: Bool = true
        /// When set, use instruct mode instead of voice cloning.
        /// Pass a text description like "A warm, calm female voice" and the TTS
        /// model will generate speech matching that description (no reference audio needed).
        /// Set to nil to revert to voice cloning from fae.wav.
        var defaultVoiceInstruct: String? = "A softly spoken young Scottish woman with a warm, gently cheeky tone. She sounds friendly, playful, and grounded, with a clear Scottish accent and a touch of dry humour."
        /// When `true`, defer all TTS until the LLM turn completes (batched mode).
        /// When `false` (default), synthesise sentence-by-sentence as the LLM streams,
        /// giving lower time-to-first-audio. Kokoro is stateless per call so per-sentence
        /// synthesis does not degrade prosody.
        var preferFinalOnly: Bool = false
    }

    // MARK: - STT

    struct SttConfig: Codable {
        var modelId: String = "mlx-community/Qwen3-ASR-1.7B-4bit"
    }

    /// Configuration for the dual-path streaming ASR fast-path.
    ///
    /// When enabled, Parakeet TDT runs alongside Qwen3-ASR as a lightweight
    /// CTC-based streaming recognizer. Parakeet provides low-latency partial
    /// transcripts during speech, while Qwen3-ASR handles final high-accuracy
    /// transcription after speech ends.
    struct StreamingASRConfig: Codable {
        /// Whether the streaming ASR fast-path is enabled.
        /// Default: false — Qwen3-ASR growing-buffer (1.6% WER) is the primary path.
        /// External engines (Parakeet, Moonshine) were evaluated but accuracy/complexity
        /// tradeoff doesn't justify dual-path.  Set to true when a <2% WER streaming
        /// engine becomes available.
        var enabled: Bool = false

        /// HuggingFace model repository for the streaming ASR model.
        var modelId: String = "UsefulSensors/moonshine-streaming-tiny"

        /// Audio samples to accumulate before each decode pass (16kHz mono).
        /// Default 8000 = 500ms. Lower values reduce latency but increase GPU load.
        var chunkSamples: Int = 8_000

        /// Minimum audio samples before the very first decode pass.
        /// Default 4000 = 250ms. Ensures enough context for meaningful output.
        var minChunkSamples: Int = 4_000
    }

    // MARK: - Conversation

    struct ConversationConfig: Codable {
        var wakeWord: String = "hi fae"
        var enabled: Bool = true
        var idleTimeoutS: Int = 45
        var requireDirectAddress: Bool = true
        var directAddressFollowupS: Int = 30
        var acousticWakeEnabled: Bool = true
        var acousticWakeThreshold: Float = 0.70
        var sleepPhrases: [String] = [
            "shut up", "stop fae", "go to sleep",
            "that will do fae", "that'll do fae",
            "quiet fae", "sleep fae", "goodbye fae", "bye fae",
        ]
    }

    // MARK: - Barge-In

    struct BargeInConfig: Codable {
        /// Minimum RMS energy for barge-in candidate.
        var minRms: Float = 0.08
        /// Continuous speech duration (ms) before barge-in fires (legacy decider).
        /// Reduced from 350→200 for more responsive interruption.
        var confirmMs: Int = 200
        /// Holdoff after playback starts before allowing interruption (ms).
        /// Reduced from 500→200 — keywords bypass this entirely.
        var assistantStartHoldoffMs: Int = 200
        var bargeInSilenceMs: Int = 600
        /// Adaptive interruption configuration (Phase 2a).
        var adaptive: AdaptiveInterruptionConfig = AdaptiveInterruptionConfig()
    }

    // MARK: - Memory

    struct MemoryConfig: Codable {
        var enabled: Bool = true
        var maxRecallResults: Int = 5
        var autoIngestInbox: Bool = true
        var generateDigests: Bool = true
    }

    // MARK: - Speaker

    struct SpeakerConfig: Codable {
        var threshold: Float = 0.45
        var ownerThreshold: Float = 0.50
        /// Voice identity gates tool access. Always true in proactive-by-default mode —
        /// only the primary user (owner) or explicitly granted guests get tool access.
        var requireOwnerForTools: Bool = true
        var progressiveEnrollment: Bool = true
        var maxEnrollments: Int = 50
        /// Minimum liveness score (0 = disabled, 1 = maximum strictness).
        var livenessThreshold: Float = 0.5
        /// Re-verify speaker identity every N utterances when not owner.
        var reVerifyEveryN: Int = 5
    }

    // MARK: - Voice Identity

    struct VoiceIdentityConfig: Codable {
        /// Always enabled — voice identity is the primary security model.
        var enabled: Bool = true
        /// enforce: only recognized voices get tool access. assist: informational only.
        var mode: String = "enforce"
        /// Require voice match for tool approval.
        var approvalRequiresMatch: Bool = true
    }

    // MARK: - Channels

    struct ChannelsConfig: Codable {
        var enabled: Bool = true
        var discord: DiscordConfig = DiscordConfig()
        var whatsapp: WhatsAppConfig = WhatsAppConfig()
        var imessage: IMessageConfig = IMessageConfig()

        struct DiscordConfig: Codable {
            var botToken: String?
            var guildId: String?
            var allowedChannelIds: [String] = []
        }

        struct WhatsAppConfig: Codable {
            var accessToken: String?
            var phoneNumberId: String?
            var verifyToken: String?
            var appSecret: String?
            var allowedNumbers: [String] = []
            var webhookPort: UInt16 = 8443
        }

        struct IMessageConfig: Codable {
            var enabled: Bool = false
            var allowedSenders: [String] = []
        }
    }

    // MARK: - Scheduler

    struct SchedulerConfig: Codable {
        var morningBriefingHour: Int = 8
        var skillProposalsHour: Int = 11
    }

    // MARK: - Skills

    struct SkillsConfig: Codable {
        /// Maximum tokens budgeted for skill descriptions in system prompt.
        var promptBudgetTokens: Int = 2000
        /// Built-in skill names that should not be shown or activated.
        var disabledBuiltins: [String] = []
    }

    // MARK: - Vision

    struct VisionConfig: Codable {
        /// Master toggle for vision capabilities (screenshot, camera, read_screen).
        var enabled: Bool = true
        /// Deep VLM model preset: "auto" (SmolVLM2-500M), "smolvlm_500m", "smolvlm_2_2b",
        /// "qwen3_vl_4b_4bit", "qwen3_vl_4b_8bit". Fast VLM (256M) is always SmolVLM2-256M.
        var modelPreset: String = "auto"
    }

    // MARK: - Awareness

    struct AwarenessConfig: Codable {
        /// Master orchestration toggle. Always on — proactive-by-default.
        var enabled: Bool = true
        /// Camera presence checks (greetings, mood, presence detection).
        /// Always on after primary user enrollment — core to Fae's proactive nature.
        var cameraEnabled: Bool = true
        /// Screen activity monitoring (passive context-building).
        /// Always on after primary user enrollment — Fae builds silent context.
        var screenEnabled: Bool = true
        /// Camera check interval in seconds (adjustable intensity).
        var cameraIntervalSeconds: Int = 60
        /// Screen check interval in seconds (adjustable intensity).
        var screenIntervalSeconds: Int = 30
        /// Research during quiet hours (22:00-06:00). Always on.
        var overnightWorkEnabled: Bool = true
        /// Enhanced morning briefing with calendar, mail, research. Always on.
        var enhancedBriefingEnabled: Bool = true
        /// Tier 1 proactive features run without camera/screen consent. Always true.
        var proactiveLiteEnabled: Bool = true
        /// Pause observations when on battery power (power management, adjustable).
        var pauseOnBattery: Bool = true
        /// Pause observations under thermal pressure (thermal management, adjustable).
        var pauseOnThermalPressure: Bool = true
        /// ISO8601 timestamp when awareness was activated. Auto-set on primary
        /// user enrollment — no separate consent flow required.
        var consentGrantedAt: String? = nil
    }

    // MARK: - Training

    struct TrainingConfig: Codable {
        var enabled: Bool = true
        var consentGrantedAt: String? = nil
        var autoTrainEnabled: Bool = true
        var targetModelPreset: String = "auto"
        var trainingPreset: String = "light"
        var maxIterationsPerRun: Int = 50
        var lastDataExportAt: String? = nil
        var lastTrainingRunAt: String? = nil
        var lastBenchmarkScore: Float? = nil
        var minEpisodesSinceLastExport: Int = 100
        var personalAdapterPath: String? = nil
        var previousAdapterPath: String? = nil
        var adapterAutoLoadEnabled: Bool = false
        var approvedAdapterCycles: Int = 0
    }

    // MARK: - Agents

    struct AgentConfig: Codable {
        /// Custom agent registry: name -> command mapping.
        /// Example: ["my-agent": "./bin/my-acp-server"]
        var customAgents: [String: String] = [:]
        /// Default approval policy for agent sessions.
        var defaultApprovalPolicy: String = "approve_reads"
        /// Maximum concurrent ACP sessions.
        var maxConcurrentSessions: Int = 5
        /// Session idle timeout in seconds (default 30 minutes).
        var sessionIdleTimeoutSeconds: Int = 1800
    }

    // MARK: - Privacy

    struct PrivacyConfig: Codable {
        /// strict_local: no network, no delegation, no remote services.
        /// local_preferred: local-first with optional connected features.
        /// connected: enable connected features when allowed by tool mode.
        var mode: String = "local_preferred"
    }

    static func recommendedTrainingTarget() -> String {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let ramGB = totalRAM / (1024 * 1024 * 1024)
        if ramGB >= 48 { return "medium" }
        if ramGB >= 24 { return "small" }
        return "tiny"
    }

    /// Training preset parameters for mlx-tune SFTTrainer.
    ///
    /// Keys match train.py PRESET_MAP: max_steps, batch_size,
    /// gradient_accumulation_steps, lr, max_seq_length, lora_r, warmup_steps.
    static func trainingPresetParameters(_ preset: String) -> [String: Any] {
        switch preset.lowercased() {
        case "smoke":
            return [
                "max_steps": 10, "batch_size": 1, "gradient_accumulation_steps": 1,
                "lr": 1e-4, "max_seq_length": 512, "lora_r": 8, "warmup_steps": 0,
            ]
        case "light":
            return [
                "max_steps": 50, "batch_size": 2, "gradient_accumulation_steps": 2,
                "lr": 5e-5, "max_seq_length": 1024, "lora_r": 16, "warmup_steps": 5,
            ]
        case "standard":
            return [
                "max_steps": 200, "batch_size": 4, "gradient_accumulation_steps": 4,
                "lr": 2e-5, "max_seq_length": 2048, "lora_r": 16, "warmup_steps": 10,
            ]
        case "deep":
            return [
                "max_steps": 500, "batch_size": 4, "gradient_accumulation_steps": 4,
                "lr": 1e-5, "max_seq_length": 2048, "lora_r": 32, "warmup_steps": 20,
            ]
        default:
            return trainingPresetParameters("light")
        }
    }

    // MARK: - Model Selection

    static func canonicalVoiceModelPreset(_ preset: String) -> String {
        switch preset.lowercased() {
        case "qwen3_5_35b_a3b":
            return "qwen3_5_35b_a3b"
        case "qwen3_5_9b":
            return "qwen3_5_9b"
        case "qwen3_5_4b":
            return "qwen3_5_4b"
        case "qwen3_5_2b":
            return "qwen3_5_2b"
        case "saorsa-1.1-tiny", "saorsa_1_1_tiny":
            return "qwen3_5_2b"  // legacy alias → Qwen3.5-2B-OptiQ
        case "auto":
            return "auto"
        default:
            NSLog("FaeConfig: unknown model preset '%@' — falling back to auto", preset)
            return "auto"
        }
    }

    /// Select the appropriate LLM model based on system RAM and preset.
    ///
    /// Returns `(modelId, contextSize)` for MLX loading.
    static func recommendedModel(
        totalMemoryBytes: UInt64? = nil,
        preset: String = "auto"
    ) -> (modelId: String, contextSize: Int) {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

        // Allow env var override for testing (e.g. FAE_VOICE_MODEL_PRESET=qwen3_5_4b).
        let effectivePreset: String
        if let envPreset = ProcessInfo.processInfo.environment["FAE_VOICE_MODEL_PRESET"],
           !envPreset.isEmpty
        {
            effectivePreset = envPreset
            NSLog("FaeConfig: model preset overridden by FAE_VOICE_MODEL_PRESET=%@", envPreset)
        } else {
            effectivePreset = preset
        }

        switch canonicalVoiceModelPreset(effectivePreset) {
        case "qwen3_5_35b_a3b":
            // MoE: 35B total, 3B active per token. ~18 GB 4-bit. Natively multimodal.
            return ("mlx-community/Qwen3.5-35B-A3B-4bit", 131_072)
        case "qwen3_5_9b":
            // 9B Unsloth: per-tensor mixed-bit (imatrix-calibrated). ~6 GB.
            // 100% tool calling, 100% assistant fit, 100% serialization.
            return ("Brooooooklyn/Qwen3.5-9B-unsloth-mlx", 32_768)
        case "qwen3_5_4b":
            // Uniform 4-bit. OptiQ variant was catastrophically broken (0% tool calling).
            return ("mlx-community/Qwen3.5-4B-4bit", 32_768)
        case "qwen3_5_2b":
            // Qwen3.5-2B with OptiQ mixed-precision. Compact, fast.
            return ("mlx-community/Qwen3.5-2B-OptiQ-4bit", 32_768)
        default: // "auto"
            if totalGB >= 16 {
                // 9B Unsloth: per-tensor mixed-bit quantization (imatrix-calibrated).
                // Benchmarked 2026-03-28: 100% tool calling, 100% assistant fit,
                // 100% Fae capability, 100% serialization. Best quality at any size.
                // ~6 GB VRAM + ~3GB for STT/TTS/speaker = ~9GB total pipeline.
                return ("Brooooooklyn/Qwen3.5-9B-unsloth-mlx", 32_768)
            } else if totalGB >= 8 {
                // 4B uniform: reliable tool calling (100%), 95% assistant fit.
                // ~2.3 GB VRAM. OptiQ variant was broken — use plain uniform.
                return ("mlx-community/Qwen3.5-4B-4bit", 32_768)
            } else {
                // Qwen3.5-2B with OptiQ mixed-precision for low-RAM Macs.
                return ("mlx-community/Qwen3.5-2B-OptiQ-4bit", 32_768)
            }
        }
    }

    /// Compute a sensible `maxHistoryMessages` from context size and generation budget.
    ///
    /// Formula: available = contextSize - systemPromptBudget - maxTokens.
    /// System prompt budget: ~12K base + tool schemas (~5K) + potential skill injection (~5K) = ~18K.
    /// Each conversation turn ≈ 400 tokens (user ~100 + assistant ~300).
    /// Clamped to [6, 100].
    static func recommendedMaxHistory(contextSize: Int, maxTokens: Int) -> Int {
        // Conservative estimate: base system prompt (~12K) + tool schemas (~5K)
        // + headroom for skill injection. PipelineCoordinator dynamically adjusts
        // reserved tokens per turn, but this sets the max message count ceiling.
        let systemBudget = 18_000
        let available = contextSize - systemBudget - maxTokens
        guard available > 0 else { return 6 }
        let computed = available / 400
        return min(max(computed, 6), 100)
    }

    /// Auto-tune prefill step size based on model size.
    ///
    /// Larger models benefit from smaller prefill chunks to reduce memory spikes.
    /// Smaller models can handle larger chunks for faster prefill.
    ///
    /// Based on research into Ollama, mistral.rs, and LM Studio optimizations.
    static func recommendedPrefillStepSize(modelId: String) -> Int {
        let totalGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let modelLower = modelId.lowercased()
        if modelLower.contains("35b") {
            // MoE 35B: scale with available RAM. 256 was too conservative —
            // community reports show 512-1024 works well on 64GB+ systems.
            return totalGB >= 64 ? 1024 : (totalGB >= 32 ? 512 : 256)
        } else if modelLower.contains("4b") || modelLower.contains("3b") {
            return 768  // 4B: larger chunks
        } else {
            return 1024 // 2B and smaller: maximize chunk size
        }
    }

    // MARK: - STT Model Selection

    /// Select the appropriate STT model based on system RAM.
    ///
    /// - >=16 GiB: 1.7B (full quality — smaller LLMs free up RAM for STT)
    /// - <16 GiB: 0.6B (compact)
    static func recommendedSTTModel(
        totalMemoryBytes: UInt64? = nil
    ) -> String {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if totalGB >= 16 {
            return "mlx-community/Qwen3-ASR-1.7B-4bit"
        } else {
            return "mlx-community/Qwen3-ASR-0.6B-4bit"
        }
    }

    // MARK: - TTS Model Selection

    /// Return the active TTS model identifier (used for display in About / Settings).
    ///
    /// Active engine: FaeTTSAdapter (Kokoro-82M via KokoroSwift / MLX).
    static func recommendedTTSModel(
        totalMemoryBytes: UInt64? = nil
    ) -> String {
        return "hexgrad/Kokoro-82M"
    }

    /// Whether the given LLM model ID is natively multimodal (handles text + vision).
    ///
    /// When true, the model can be loaded via VLMModelFactory and shared between
    /// the text LLM pipeline and vision pipeline, avoiding a duplicate load.
    static func isMultimodalLLM(modelId: String) -> Bool {
        // Qwen3.5 MoE models (35B-A3B, 122B-A10B, 397B-A17B) are natively multimodal.
        modelId.contains("Qwen3.5") && modelId.contains("A3B") ||
        modelId.contains("Qwen3.5") && modelId.contains("A10B") ||
        modelId.contains("Qwen3.5") && modelId.contains("A17B")
    }

    // MARK: - VLM Model Selection

    /// Select the deep VLM model for detailed screenshot/camera analysis.
    ///
    /// Returns `nil` when insufficient RAM for vision alongside the text LLM + STT + TTS stack.
    /// Deep VLM loads on-demand (not at startup) — only uses RAM when vision tools fire.
    ///
    /// Eval results (2026-03-26, FaeEvalServer, 15 vision scenarios):
    ///   SmolVLM2-500M: 73% accuracy, 1.8GB, avg 11.4s — best accuracy
    ///   SmolVLM2-2.2B: 67% accuracy, 5.2GB, avg 3.5s — fastest
    ///   SmolVLM2-256M: 53% accuracy, <1GB, avg 7.1s — used for fast path
    ///   Qwen3-VL-4B:   ~2.5GB, slower, legacy
    static func recommendedVLMModel(
        totalMemoryBytes: UInt64? = nil,
        preset: String = "auto"
    ) -> (modelId: String, contextSize: Int)? {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

        switch preset.lowercased() {
        case "qwen3_5_35b_a3b_vlm":
            return ("mlx-community/Qwen3.5-35B-A3B-4bit", 16_384)
        case "qwen3_vl_4b_8bit", "qwen3_vl_8b":
            return ("mlx-community/Qwen3-VL-4B-Instruct-8bit", 16_384)
        case "qwen3_vl_4b_4bit", "qwen3_vl_4b":
            return ("lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit", 16_384)
        case "smolvlm_2_2b":
            return ("mlx-community/SmolVLM2-2.2B-Instruct-mlx", 4_096)
        case "smolvlm_500m":
            return ("mlx-community/SmolVLM2-500M-Video-Instruct-mlx", 4_096)
        case "smolvlm_256m":
            return ("mlx-community/SmolVLM2-256M-Video-Instruct-mlx", 4_096)
        default: // "auto"
            // SmolVLM2-500M scored 73% on Fae vision eval (15 scenarios) — best accuracy
            // among sub-2GB VLMs. Uses 1.8GB vs Qwen3-VL-4B's 2.5GB.
            // 16+ GB: SmolVLM2-500M (1.8 GB) — highest accuracy, on-demand deep path.
            // <16 GB: Not enough headroom for a separate VLM.
            if totalGB >= 16 {
                return ("mlx-community/SmolVLM2-500M-Video-Instruct-mlx", 4_096)
            } else {
                return nil
            }
        }
    }

    /// Select the fast VLM model for always-on proactive awareness.
    ///
    /// Loaded at startup alongside STT/LLM/TTS. Used for camera presence detection
    /// and quick screen triage. Must be <1GB to avoid impacting the main pipeline.
    ///
    /// Returns `nil` when insufficient RAM (fast VLM needs ~700MB headroom).
    static func recommendedFastVLMModel(
        totalMemoryBytes: UInt64? = nil
    ) -> (modelId: String, contextSize: Int)? {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        // SmolVLM2-256M: 53% accuracy, <1GB, fast (0.5-2s on passes).
        // Good enough for: "is someone at the desk?", "is this a terminal or browser?", app identification.
        // 16+ GB: always load fast VLM for proactive awareness.
        // <16 GB: skip (not enough headroom).
        if totalGB >= 16 {
            return ("mlx-community/SmolVLM2-256M-Video-Instruct-mlx", 4_096)
        } else {
            return nil
        }
    }

    // MARK: - Persistence

    /// Config file path — uses FaeDirectories for dev-mode isolation.
    static var configFileURL: URL { FaeDirectories.configFile }

    /// Load config for the current environment.
    ///
    /// - **Normal mode**: Returns code defaults. config.toml is NOT read.
    ///   User preferences come from UserDefaults (Settings UI / voice commands).
    /// - **Dev mode**: Reads config.toml from the dev data directory.
    ///   This allows developers to override any setting via the toml file.
    static func load() -> FaeConfig {
        if FaeEnvironment.isDev || FaeEnvironment.isTesting {
            return load(from: configFileURL)
        }
        // Normal mode: pure code defaults. UserDefaults overlay applied by FaeCore.
        return FaeConfig()
    }

    /// Load config from a specific URL. Returns default for missing/invalid files.
    static func load(from url: URL) -> FaeConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FaeConfig()
        }

        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                NSLog("FaeConfig: failed to decode UTF-8 at %@; using defaults", url.path)
                return FaeConfig()
            }
            do {
                var parsed = try parse(text)
                let hasExplicitThinkingLevel = text.contains("thinkingLevel") || text.contains("thinking_level")
                parsed.llm.normalizeThinkingConfiguration(hasExplicitLevel: hasExplicitThinkingLevel)
                return parsed
            } catch {
                NSLog("FaeConfig: failed to parse %@: %@; using defaults", url.path, String(describing: error))
                return FaeConfig()
            }
        } catch {
            NSLog("FaeConfig: failed to read %@: %@; using defaults", url.path, String(describing: error))
            return FaeConfig()
        }
    }

    /// Save config to disk. Only writes in dev mode or tests — normal mode uses UserDefaults.
    func save() throws {
        guard FaeEnvironment.isDev || FaeEnvironment.isTesting else { return }
        try save(to: Self.configFileURL)
    }

    /// Save config to a specific URL atomically, creating parent directories as needed.
    func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = serialize()
        guard let data = output.data(using: .utf8) else {
            throw NSError(
                domain: "FaeConfig",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode config as UTF-8"]
            )
        }
        try data.write(to: url, options: .atomic)
    }

    private static func parse(_ input: String) throws -> FaeConfig {
        enum ParseError: Error {
            case invalidSectionHeader(String)
            case malformedAssignment(String)
            case malformedValue(key: String, value: String)
        }

        var config = FaeConfig()
        var section = ""

        for rawLine in input.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty {
                    continue
                }
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError.invalidSectionHeader(line)
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                // Skip lines without '=' — may be continuation of a multi-line
                // array from an older config format, or trailing commas.
                NSLog("FaeConfig: skipping line without '=': %@", line)
                continue
            }

            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            switch section {
            case "":
                switch key {
                case "userName":
                    if rawValue == "nil" {
                        config.userName = nil
                    } else if let v = parseString(rawValue) {
                        config.userName = v
                    } else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                case "onboarded":
                    break  // Legacy field — ignored gracefully
                case "licenseAccepted":
                    guard let v = parseBool(rawValue) else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                    config.licenseAccepted = v
                case "startupIntroSeen":
                    guard let v = parseBool(rawValue) else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                    config.startupIntroSeen = v
                    config.startupIntroSeenConfigured = true
                case "toolMode":
                    guard let v = parseString(rawValue) else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                    config.toolMode = v
                default: break
                }
            case "privacy":
                switch key {
                case "mode":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.privacy.mode = v
                default: break
                }
            case "audio":
                switch key {
                case "inputSampleRate":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.audio.inputSampleRate = v
                case "outputSampleRate":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.audio.outputSampleRate = v
                case "inputChannels":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.audio.inputChannels = v
                case "bufferSize":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.audio.bufferSize = v
                default: break
                }
            case "vad":
                switch key {
                case "threshold":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vad.threshold = v
                case "hysteresisRatio":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vad.hysteresisRatio = v
                case "minSilenceDurationMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vad.minSilenceDurationMs = v
                case "speechPadMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vad.speechPadMs = v
                case "minSpeechDurationMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vad.minSpeechDurationMs = v
                case "maxSpeechDurationMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vad.maxSpeechDurationMs = v
                default: break
                }
            case "llm":
                switch key {
                case "maxTokens":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.maxTokens = v
                case "contextSizeTokens":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.contextSizeTokens = v
                case "temperature":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.temperature = v
                case "topP":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.topP = v
                case "topK":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.topK = v
                case "repeatPenalty":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.repeatPenalty = v
                case "maxHistoryMessages":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.maxHistoryMessages = v
                case "voiceModelPreset":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.voiceModelPreset = v
                case "remoteProviderPreset":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.remoteProviderPreset = v
                case "remoteBaseURL":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.remoteBaseURL = v
                case "remoteModel":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.remoteModel = v
                case "enableVision":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.enableVision = v
                case "thinkingEnabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.thinkingEnabled = v
                case "thinkingLevel", "thinking_level":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.thinkingLevel = v
                default: break
                }
            case "tts":
                switch key {
                case "voice":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.voice = v
                case "modelId":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.modelId = v
                case "speed":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.speed = v
                case "sampleRate":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.sampleRate = v
                case "referenceText":
                    if rawValue == "nil" {
                        config.tts.referenceText = nil
                    } else if let v = parseString(rawValue) {
                        config.tts.referenceText = v
                    } else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                case "customVoicePath":
                    config.tts.customVoicePath = rawValue == "nil" ? nil : parseString(rawValue)
                case "customReferenceText":
                    config.tts.customReferenceText = rawValue == "nil" ? nil : parseString(rawValue)
                case "voiceIdentityLock", "voice_identity_lock":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.voiceIdentityLock = v
                case "preferFinalOnly", "prefer_final_only":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.preferFinalOnly = v
                case "emotionalProsody", "warmth":
                    break // Legacy keys — silently ignored (emotional prosody removed in v2.0).
                default: break
                }
            case "stt":
                if key == "modelId" {
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.stt.modelId = v
                }
            case "conversation":
                switch key {
                case "wakeWord":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.wakeWord = v
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.enabled = v
                case "idleTimeoutS":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.idleTimeoutS = v
                case "requireDirectAddress":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.requireDirectAddress = v
                case "directAddressFollowupS":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.directAddressFollowupS = v
                case "acousticWakeEnabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.acousticWakeEnabled = v
                case "acousticWakeThreshold":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.acousticWakeThreshold = v
                case "sleepPhrases":
                    guard let v = parseStringArray(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.sleepPhrases = v
                default: break
                }
            case "bargeIn":
                switch key {
                case "enabled":
                    // Legacy field — barge-in is always on. Silently ignore.
                    break
                case "minRms":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.bargeIn.minRms = v
                case "confirmMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.bargeIn.confirmMs = v
                case "assistantStartHoldoffMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.bargeIn.assistantStartHoldoffMs = v
                case "bargeInSilenceMs":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.bargeIn.bargeInSilenceMs = v
                default: break
                }
            case "memory":
                switch key {
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.memory.enabled = v
                case "maxRecallResults":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.memory.maxRecallResults = v
                case "autoIngestInbox":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.memory.autoIngestInbox = v
                case "generateDigests":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.memory.generateDigests = v
                default: break
                }
            case "voiceIdentity":
                switch key {
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.voiceIdentity.enabled = v
                case "mode":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.voiceIdentity.mode = v
                case "approvalRequiresMatch":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.voiceIdentity.approvalRequiresMatch = v
                default: break
                }
            case "channels":
                if key == "enabled" {
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.enabled = v
                }
            case "channels.discord":
                switch key {
                case "botToken":
                    config.channels.discord.botToken = rawValue == "nil" ? nil : parseString(rawValue)
                case "guildId":
                    config.channels.discord.guildId = rawValue == "nil" ? nil : parseString(rawValue)
                case "allowedChannelIds":
                    guard let v = parseStringArray(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.discord.allowedChannelIds = v
                default: break
                }
            case "channels.whatsapp":
                switch key {
                case "accessToken":
                    config.channels.whatsapp.accessToken = rawValue == "nil" ? nil : parseString(rawValue)
                case "phoneNumberId":
                    config.channels.whatsapp.phoneNumberId = rawValue == "nil" ? nil : parseString(rawValue)
                case "verifyToken":
                    config.channels.whatsapp.verifyToken = rawValue == "nil" ? nil : parseString(rawValue)
                case "appSecret":
                    config.channels.whatsapp.appSecret = rawValue == "nil" ? nil : parseString(rawValue)
                case "allowedNumbers":
                    guard let v = parseStringArray(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.whatsapp.allowedNumbers = v
                case "webhookPort":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.whatsapp.webhookPort = UInt16(clamping: v)
                default: break
                }
            case "channels.imessage":
                switch key {
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.imessage.enabled = v
                case "allowedSenders":
                    guard let v = parseStringArray(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.imessage.allowedSenders = v
                default: break
                }
            case "vision":
                switch key {
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vision.enabled = v
                case "modelPreset", "model_preset":
                    guard let v = parseString(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.vision.modelPreset = v
                default: break
                }
            case "awareness":
                switch key {
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.enabled = v
                case "cameraEnabled", "camera_enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.cameraEnabled = v
                case "screenEnabled", "screen_enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.screenEnabled = v
                case "cameraIntervalSeconds", "camera_interval_seconds":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.cameraIntervalSeconds = v
                case "screenIntervalSeconds", "screen_interval_seconds":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.screenIntervalSeconds = v
                case "overnightWorkEnabled", "overnight_work":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.overnightWorkEnabled = v
                case "enhancedBriefingEnabled", "enhanced_briefing":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.enhancedBriefingEnabled = v
                case "proactiveLiteEnabled", "proactive_lite":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.proactiveLiteEnabled = v
                case "pauseOnBattery", "pause_on_battery":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.pauseOnBattery = v
                case "pauseOnThermalPressure", "pause_on_thermal_pressure":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.awareness.pauseOnThermalPressure = v
                case "consentGrantedAt", "consent_granted_at":
                    config.awareness.consentGrantedAt = rawValue == "nil" ? nil : parseString(rawValue)
                default: break
                }
            case "scheduler":
                switch key {
                case "morningBriefingHour":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.scheduler.morningBriefingHour = v
                case "skillProposalsHour":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.scheduler.skillProposalsHour = v
                default: break
                }
            case "speaker":
                switch key {
                case "enabled":
                    break // Legacy key — speaker recognition is always on (v2.0).
                case "threshold":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.threshold = v
                case "ownerThreshold":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.ownerThreshold = v
                case "requireOwnerForTools":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.requireOwnerForTools = v
                case "progressiveEnrollment":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.progressiveEnrollment = v
                case "maxEnrollments":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.maxEnrollments = v
                case "livenessThreshold":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.livenessThreshold = v
                case "reVerifyEveryN":
                    guard let v = parseInt(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.reVerifyEveryN = v
                default: break
                }
            default:
                break
            }
        }

        return config
    }

    private func serialize() -> String {
        var lines: [String] = []

        lines.append("userName = \(encodeStringOrNil(userName))")
        lines.append("licenseAccepted = \(licenseAccepted ? "true" : "false")")
        lines.append("startupIntroSeen = \(startupIntroSeen ? "true" : "false")")
        lines.append("toolMode = \(encodeString(toolMode))")
        lines.append("")

        lines.append("[privacy]")
        lines.append("mode = \(encodeString(privacy.mode))")
        lines.append("")

        lines.append("[audio]")
        lines.append("inputSampleRate = \(audio.inputSampleRate)")
        lines.append("outputSampleRate = \(audio.outputSampleRate)")
        lines.append("inputChannels = \(audio.inputChannels)")
        lines.append("bufferSize = \(audio.bufferSize)")
        lines.append("")

        lines.append("[vad]")
        lines.append("threshold = \(formatFloat(vad.threshold))")
        lines.append("hysteresisRatio = \(formatFloat(vad.hysteresisRatio))")
        lines.append("minSilenceDurationMs = \(vad.minSilenceDurationMs)")
        lines.append("speechPadMs = \(vad.speechPadMs)")
        lines.append("minSpeechDurationMs = \(vad.minSpeechDurationMs)")
        lines.append("maxSpeechDurationMs = \(vad.maxSpeechDurationMs)")
        lines.append("")

        lines.append("[llm]")
        lines.append("maxTokens = \(llm.maxTokens)")
        lines.append("contextSizeTokens = \(llm.contextSizeTokens)")
        lines.append("temperature = \(formatFloat(llm.temperature))")
        lines.append("topP = \(formatFloat(llm.topP))")
        lines.append("topK = \(llm.topK)")
        lines.append("repeatPenalty = \(formatFloat(llm.repeatPenalty))")
        lines.append("maxHistoryMessages = \(llm.maxHistoryMessages)")
        lines.append("voiceModelPreset = \(encodeString(llm.voiceModelPreset))")
        lines.append("remoteProviderPreset = \(encodeString(llm.remoteProviderPreset))")
        lines.append("remoteBaseURL = \(encodeString(llm.remoteBaseURL))")
        lines.append("remoteModel = \(encodeString(llm.remoteModel))")
        let normalizedThinkingLevel = llm.resolvedThinkingLevel
        lines.append("enableVision = \(llm.enableVision ? "true" : "false")")
        lines.append("thinkingEnabled = \(normalizedThinkingLevel.enablesThinking ? "true" : "false")")
        lines.append("thinkingLevel = \(encodeString(normalizedThinkingLevel.rawValue))")
        lines.append("")

        lines.append("[tts]")
        lines.append("voice = \(encodeString(tts.voice))")
        lines.append("modelId = \(encodeString(tts.modelId))")
        lines.append("speed = \(formatFloat(tts.speed))")
        lines.append("sampleRate = \(tts.sampleRate)")
        lines.append("referenceText = \(encodeStringOrNil(tts.referenceText))")
        lines.append("customVoicePath = \(encodeStringOrNil(tts.customVoicePath))")
        lines.append("customReferenceText = \(encodeStringOrNil(tts.customReferenceText))")
        lines.append("voiceIdentityLock = \(tts.voiceIdentityLock ? "true" : "false")")
        lines.append("preferFinalOnly = \(tts.preferFinalOnly ? "true" : "false")")
        lines.append("")

        lines.append("[stt]")
        lines.append("modelId = \(encodeString(stt.modelId))")
        lines.append("")

        lines.append("[conversation]")
        lines.append("wakeWord = \(encodeString(conversation.wakeWord))")
        lines.append("enabled = \(conversation.enabled ? "true" : "false")")
        lines.append("idleTimeoutS = \(conversation.idleTimeoutS)")
        lines.append("requireDirectAddress = \(conversation.requireDirectAddress ? "true" : "false")")
        lines.append("directAddressFollowupS = \(conversation.directAddressFollowupS)")
        lines.append("acousticWakeEnabled = \(conversation.acousticWakeEnabled ? "true" : "false")")
        lines.append("acousticWakeThreshold = \(formatFloat(conversation.acousticWakeThreshold))")
        lines.append("sleepPhrases = \(encodeStringArray(conversation.sleepPhrases))")
        lines.append("")

        lines.append("[bargeIn]")
        lines.append("minRms = \(formatFloat(bargeIn.minRms))")
        lines.append("confirmMs = \(bargeIn.confirmMs)")
        lines.append("assistantStartHoldoffMs = \(bargeIn.assistantStartHoldoffMs)")
        lines.append("bargeInSilenceMs = \(bargeIn.bargeInSilenceMs)")
        lines.append("")

        lines.append("[memory]")
        lines.append("enabled = \(memory.enabled ? "true" : "false")")
        lines.append("maxRecallResults = \(memory.maxRecallResults)")
        lines.append("autoIngestInbox = \(memory.autoIngestInbox ? "true" : "false")")
        lines.append("generateDigests = \(memory.generateDigests ? "true" : "false")")
        lines.append("")

        lines.append("[scheduler]")
        lines.append("morningBriefingHour = \(scheduler.morningBriefingHour)")
        lines.append("skillProposalsHour = \(scheduler.skillProposalsHour)")
        lines.append("")

        lines.append("[vision]")
        lines.append("enabled = \(vision.enabled ? "true" : "false")")
        lines.append("modelPreset = \(encodeString(vision.modelPreset))")
        lines.append("")

        lines.append("[awareness]")
        lines.append("enabled = \(awareness.enabled ? "true" : "false")")
        lines.append("cameraEnabled = \(awareness.cameraEnabled ? "true" : "false")")
        lines.append("screenEnabled = \(awareness.screenEnabled ? "true" : "false")")
        lines.append("cameraIntervalSeconds = \(awareness.cameraIntervalSeconds)")
        lines.append("screenIntervalSeconds = \(awareness.screenIntervalSeconds)")
        lines.append("overnightWorkEnabled = \(awareness.overnightWorkEnabled ? "true" : "false")")
        lines.append("enhancedBriefingEnabled = \(awareness.enhancedBriefingEnabled ? "true" : "false")")
        lines.append("proactiveLiteEnabled = \(awareness.proactiveLiteEnabled ? "true" : "false")")
        lines.append("pauseOnBattery = \(awareness.pauseOnBattery ? "true" : "false")")
        lines.append("pauseOnThermalPressure = \(awareness.pauseOnThermalPressure ? "true" : "false")")
        lines.append("consentGrantedAt = \(encodeStringOrNil(awareness.consentGrantedAt))")
        lines.append("")

        lines.append("[speaker]")
        lines.append("threshold = \(formatFloat(speaker.threshold))")
        lines.append("ownerThreshold = \(formatFloat(speaker.ownerThreshold))")
        lines.append("requireOwnerForTools = \(speaker.requireOwnerForTools ? "true" : "false")")
        lines.append("progressiveEnrollment = \(speaker.progressiveEnrollment ? "true" : "false")")
        lines.append("maxEnrollments = \(speaker.maxEnrollments)")
        lines.append("livenessThreshold = \(formatFloat(speaker.livenessThreshold))")
        lines.append("reVerifyEveryN = \(speaker.reVerifyEveryN)")
        lines.append("")

        lines.append("[voiceIdentity]")
        lines.append("enabled = \(voiceIdentity.enabled ? "true" : "false")")
        lines.append("mode = \(encodeString(voiceIdentity.mode))")
        lines.append("approvalRequiresMatch = \(voiceIdentity.approvalRequiresMatch ? "true" : "false")")
        lines.append("")

        lines.append("[channels]")
        lines.append("enabled = \(channels.enabled ? "true" : "false")")
        lines.append("")

        lines.append("[channels.discord]")
        lines.append("botToken = \(encodeStringOrNil(channels.discord.botToken))")
        lines.append("guildId = \(encodeStringOrNil(channels.discord.guildId))")
        lines.append("allowedChannelIds = \(encodeStringArray(channels.discord.allowedChannelIds))")
        lines.append("")

        lines.append("[channels.whatsapp]")
        lines.append("accessToken = \(encodeStringOrNil(channels.whatsapp.accessToken))")
        lines.append("phoneNumberId = \(encodeStringOrNil(channels.whatsapp.phoneNumberId))")
        lines.append("verifyToken = \(encodeStringOrNil(channels.whatsapp.verifyToken))")
        lines.append("appSecret = \(encodeStringOrNil(channels.whatsapp.appSecret))")
        lines.append("allowedNumbers = \(encodeStringArray(channels.whatsapp.allowedNumbers))")
        lines.append("webhookPort = \(channels.whatsapp.webhookPort)")
        lines.append("")

        lines.append("[channels.imessage]")
        lines.append("enabled = \(channels.imessage.enabled ? "true" : "false")")
        lines.append("allowedSenders = \(encodeStringArray(channels.imessage.allowedSenders))")

        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseString(_ raw: String) -> String? {
        if raw == "nil" {
            return nil
        }
        guard raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 else {
            return nil
        }
        let inner = String(raw.dropFirst().dropLast())
        return unescapeString(inner)
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func parseInt(_ raw: String) -> Int? { Int(raw) }

    private static func parseFloat(_ raw: String) -> Float? { Float(raw) }

    private static func parseStringArray(_ raw: String) -> [String]? {
        guard raw.hasPrefix("[") && raw.hasSuffix("]") else {
            return nil
        }
        let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty {
            return []
        }

        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false

        for ch in inner {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if ch == "\\" && inQuotes {
                current.append(ch)
                escaping = true
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if ch == "," && !inQuotes {
                let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = parseString(part) else { return nil }
                result.append(value)
                current = ""
                continue
            }
            current.append(ch)
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            guard let value = parseString(tail) else { return nil }
            result.append(value)
        }
        return result
    }

    private func encodeString(_ value: String) -> String {
        "\"\(Self.escapeString(value))\""
    }

    private func encodeStringOrNil(_ value: String?) -> String {
        guard let value else { return "nil" }
        return encodeString(value)
    }

    private func encodeStringArray(_ values: [String]) -> String {
        let encoded = values.map { encodeString($0) }
        return "[\(encoded.joined(separator: ", "))]"
    }

    private static func escapeString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func unescapeString(_ value: String) -> String {
        var output = ""
        var escaping = false
        for ch in value {
            if escaping {
                switch ch {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "\\": output.append("\\")
                case "\"": output.append("\"")
                default:
                    output.append("\\")
                    output.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                output.append(ch)
            }
        }
        if escaping { output.append("\\") }
        return output
    }

    private func formatFloat(_ value: Float) -> String {
        let number = NSNumber(value: value)
        return number.description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}

extension FaeConfig.LlmConfig {
    var resolvedThinkingLevel: FaeThinkingLevel {
        FaeThinkingLevel(rawValue: thinkingLevel) ?? (thinkingEnabled ? .balanced : .fast)
    }

    mutating func normalizeThinkingConfiguration(hasExplicitLevel: Bool = true) {
        let resolvedLevel: FaeThinkingLevel
        if hasExplicitLevel {
            resolvedLevel = FaeThinkingLevel(rawValue: thinkingLevel) ?? (thinkingEnabled ? .balanced : .fast)
        } else {
            resolvedLevel = thinkingEnabled ? .balanced : .fast
        }
        thinkingLevel = resolvedLevel.rawValue
        thinkingEnabled = resolvedLevel.enablesThinking
    }
}
