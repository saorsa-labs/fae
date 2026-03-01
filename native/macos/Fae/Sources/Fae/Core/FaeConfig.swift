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
    var speaker: SpeakerConfig = SpeakerConfig()
    var voiceIdentity: VoiceIdentityConfig = VoiceIdentityConfig()
    var channels: ChannelsConfig = ChannelsConfig()
    var scheduler: SchedulerConfig = SchedulerConfig()
    var userName: String?
    var onboarded: Bool = false
    var licenseAccepted: Bool = false
    var toolMode: String = "full"

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
        /// When true, Qwen3 thinking mode is enabled (extended reasoning).
        /// When false (default), /no_think is appended to suppress thinking tokens.
        var thinkingEnabled: Bool = false
    }

    // MARK: - TTS

    struct TtsConfig: Codable {
        var voice: String = "fae"
        var modelId: String = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
        var speed: Float = 1.1
        var sampleRate: Int = 24_000
        /// Transcript of the reference audio for voice cloning.
        /// Must match the first ~3 seconds of speech in fae.wav.
        var referenceText: String? = "Hello, I'm Fae, your personal voice assistant."
        /// Path to a custom voice WAV file (overrides bundled fae.wav).
        var customVoicePath: String?
        /// Reference text for the custom voice WAV.
        var customReferenceText: String?
        /// Enable emotional prosody via instruct mode (trades voice fidelity for emotion).
        var emotionalProsody: Bool = false
        /// Voice warmth level (1-5 scale), adjusts instruct baseline.
        var warmth: Float = 3.0
    }

    // MARK: - STT

    struct SttConfig: Codable {
        var modelId: String = "mlx-community/Qwen3-ASR-1.7B-4bit"
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

    // MARK: - Speaker

    struct SpeakerConfig: Codable {
        var enabled: Bool = true
        var threshold: Float = 0.70
        var ownerThreshold: Float = 0.75
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
        var enabled: Bool = false
        /// assist|enforce
        var mode: String = "assist"
        var approvalRequiresMatch: Bool = true
    }

    // MARK: - Channels

    struct ChannelsConfig: Codable {
        var enabled: Bool = true
        var discord: DiscordConfig = DiscordConfig()
        var whatsapp: WhatsAppConfig = WhatsAppConfig()

        struct DiscordConfig: Codable {
            var botToken: String?
            var guildId: String?
            var allowedChannelIds: [String] = []
        }

        struct WhatsAppConfig: Codable {
            var accessToken: String?
            var phoneNumberId: String?
            var verifyToken: String?
            var allowedNumbers: [String] = []
        }
    }

    // MARK: - Scheduler

    struct SchedulerConfig: Codable {
        var morningBriefingHour: Int = 8
        var skillProposalsHour: Int = 11
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
        case "qwen3_5_27b":
            // NexVeridian text-only conversion (vision tower stripped).
            // mlx-community versions are VL — incompatible with mlx-lm text-only loading.
            return ("NexVeridian/Qwen3.5-27B-4bit", 65_536)
        case "qwen3_5_35b_a3b":
            // NexVeridian text-only conversion. MoE: 35B total / 3B active per token.
            // 11.7 T/s in mlx-swift-lm — sufficient for chat with thinking feedback.
            // Auto-selected on 64+ GB systems.
            return ("NexVeridian/Qwen3.5-35B-A3B-4bit", 65_536)
        case "qwen3_8b":
            return ("mlx-community/Qwen3-8B-4bit", 32_768)
        case "qwen3_4b":
            return ("mlx-community/Qwen3-4B-4bit", 16_384)
        case "qwen3_1_7b":
            return ("mlx-community/Qwen3-1.7B-4bit", 8_192)
        case "qwen3_0_6b":
            return ("mlx-community/Qwen3-0.6B-4bit", 4_096)
        default: // "auto"
            // 96+ GB: Qwen3.5-35B-A3B with full 65K context — plenty of headroom.
            // 80-95 GB: Qwen3.5-35B-A3B with 49K context — comfortable headroom.
            // 64-79 GB: Qwen3.5-35B-A3B with 32K context — MoE ~18.8 GB + 4.5 GB KV.
            // 48-63 GB: Qwen3-8B — 52.8 T/s, 100% tool calling, 4.5 GB RAM.
            // 32-47 GB: Qwen3-4B — good balance at 16K context.
            // 16-31 GB: Qwen3-1.7B — 8K context, tight but workable.
            // <16 GB: Qwen3-1.7B — 4K context, very tight with 3 models loaded.
            if totalGB >= 96 {
                return ("NexVeridian/Qwen3.5-35B-A3B-4bit", 65_536)
            } else if totalGB >= 80 {
                return ("NexVeridian/Qwen3.5-35B-A3B-4bit", 49_152)
            } else if totalGB >= 64 {
                return ("NexVeridian/Qwen3.5-35B-A3B-4bit", 32_768)
            } else if totalGB >= 48 {
                return ("mlx-community/Qwen3-8B-4bit", 32_768)
            } else if totalGB >= 32 {
                return ("mlx-community/Qwen3-4B-4bit", 16_384)
            } else if totalGB >= 16 {
                return ("mlx-community/Qwen3-1.7B-4bit", 8_192)
            } else {
                return ("mlx-community/Qwen3-1.7B-4bit", 4_096)
            }
        }
    }

    /// Compute a sensible `maxHistoryMessages` from context size and generation budget.
    ///
    /// Formula: available = contextSize - systemPromptBudget(~5000) - maxTokens.
    /// Each conversation turn ≈ 400 tokens (user ~100 + assistant ~300).
    /// Clamped to [6, 50].
    static func recommendedMaxHistory(contextSize: Int, maxTokens: Int) -> Int {
        let systemBudget = 5000
        let available = contextSize - systemBudget - maxTokens
        guard available > 0 else { return 6 }
        let computed = available / 400
        return min(max(computed, 6), 50)
    }

    // MARK: - STT Model Selection

    /// Select the appropriate STT model based on system RAM.
    static func recommendedSTTModel(
        totalMemoryBytes: UInt64? = nil
    ) -> String {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if totalGB >= 32 {
            return "mlx-community/Qwen3-ASR-1.7B-4bit"
        } else {
            return "mlx-community/Qwen3-ASR-0.6B-4bit"
        }
    }

    // MARK: - TTS Model Selection

    /// Select the appropriate TTS model based on system RAM.
    ///
    /// - >=32 GiB: 1.7B CustomVoice (voice cloning via fae.wav)
    /// - <32 GiB: 0.6B standard (no voice cloning)
    static func recommendedTTSModel(
        totalMemoryBytes: UInt64? = nil
    ) -> String {
        let totalGB = (totalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if totalGB >= 32 {
            return "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
        } else {
            return "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16"
        }
    }

    // MARK: - Persistence

    /// Config file path: ~/Library/Application Support/fae/config.toml
    static var configFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/config.toml")
    }

    /// Load config from disk. Returns default if file doesn't exist.
    static func load() -> FaeConfig { load(from: configFileURL) }

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
                return try parse(text)
            } catch {
                NSLog("FaeConfig: failed to parse %@: %@; using defaults", url.path, String(describing: error))
                return FaeConfig()
            }
        } catch {
            NSLog("FaeConfig: failed to read %@: %@; using defaults", url.path, String(describing: error))
            return FaeConfig()
        }
    }

    /// Save config to disk.
    func save() throws { try save(to: Self.configFileURL) }

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
                    guard let v = parseBool(rawValue) else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                    config.onboarded = v
                case "licenseAccepted":
                    guard let v = parseBool(rawValue) else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                    config.licenseAccepted = v
                case "toolMode":
                    guard let v = parseString(rawValue) else {
                        throw ParseError.malformedValue(key: key, value: rawValue)
                    }
                    config.toolMode = v
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
                case "enableVision":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.enableVision = v
                case "thinkingEnabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.llm.thinkingEnabled = v
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
                case "emotionalProsody":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.emotionalProsody = v
                case "warmth":
                    guard let v = parseFloat(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.tts.warmth = v
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
                case "sleepPhrases":
                    guard let v = parseStringArray(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.conversation.sleepPhrases = v
                default: break
                }
            case "bargeIn":
                switch key {
                case "enabled":
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.bargeIn.enabled = v
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
                case "allowedNumbers":
                    guard let v = parseStringArray(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.channels.whatsapp.allowedNumbers = v
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
                    guard let v = parseBool(rawValue) else { throw ParseError.malformedValue(key: key, value: rawValue) }
                    config.speaker.enabled = v
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
        lines.append("onboarded = \(onboarded ? "true" : "false")")
        lines.append("licenseAccepted = \(licenseAccepted ? "true" : "false")")
        lines.append("toolMode = \(encodeString(toolMode))")
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
        lines.append("enableVision = \(llm.enableVision ? "true" : "false")")
        lines.append("thinkingEnabled = \(llm.thinkingEnabled ? "true" : "false")")
        lines.append("")

        lines.append("[tts]")
        lines.append("voice = \(encodeString(tts.voice))")
        lines.append("modelId = \(encodeString(tts.modelId))")
        lines.append("speed = \(formatFloat(tts.speed))")
        lines.append("sampleRate = \(tts.sampleRate)")
        lines.append("referenceText = \(encodeStringOrNil(tts.referenceText))")
        lines.append("customVoicePath = \(encodeStringOrNil(tts.customVoicePath))")
        lines.append("customReferenceText = \(encodeStringOrNil(tts.customReferenceText))")
        lines.append("emotionalProsody = \(tts.emotionalProsody ? "true" : "false")")
        lines.append("warmth = \(formatFloat(tts.warmth))")
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
        lines.append("sleepPhrases = \(encodeStringArray(conversation.sleepPhrases))")
        lines.append("")

        lines.append("[bargeIn]")
        lines.append("enabled = \(bargeIn.enabled ? "true" : "false")")
        lines.append("minRms = \(formatFloat(bargeIn.minRms))")
        lines.append("confirmMs = \(bargeIn.confirmMs)")
        lines.append("assistantStartHoldoffMs = \(bargeIn.assistantStartHoldoffMs)")
        lines.append("bargeInSilenceMs = \(bargeIn.bargeInSilenceMs)")
        lines.append("")

        lines.append("[memory]")
        lines.append("enabled = \(memory.enabled ? "true" : "false")")
        lines.append("maxRecallResults = \(memory.maxRecallResults)")
        lines.append("")

        lines.append("[scheduler]")
        lines.append("morningBriefingHour = \(scheduler.morningBriefingHour)")
        lines.append("skillProposalsHour = \(scheduler.skillProposalsHour)")
        lines.append("")

        lines.append("[speaker]")
        lines.append("enabled = \(speaker.enabled ? "true" : "false")")
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
        lines.append("allowedNumbers = \(encodeStringArray(channels.whatsapp.allowedNumbers))")

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
