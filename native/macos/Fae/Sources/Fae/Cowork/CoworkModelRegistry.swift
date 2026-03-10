import Foundation

// MARK: - Capability flags

enum CoworkModelCapability: String, CaseIterable, Hashable, Sendable {
    case vision    // Can process image inputs
    case toolUse   // Supports function / tool calling
    case reasoning // Extended thinking / chain-of-thought reasoning
}

// MARK: - Per-model metadata

struct CoworkModelMetadata: Sendable {
    let id: String
    let vendorLabel: String
    let displayName: String
    let contextWindowK: Int?            // context window in thousands of tokens (nil = unknown)
    let capabilities: Set<CoworkModelCapability>
    let isDeprecated: Bool

    init(
        id: String,
        vendorLabel: String,
        displayName: String,
        contextWindowK: Int? = nil,
        capabilities: Set<CoworkModelCapability> = [],
        isDeprecated: Bool = false
    ) {
        self.id = id
        self.vendorLabel = vendorLabel
        self.displayName = displayName
        self.contextWindowK = contextWindowK
        self.capabilities = capabilities
        self.isDeprecated = isDeprecated
    }

    var contextWindowLabel: String? {
        guard let k = contextWindowK else { return nil }
        if k >= 1000 { return "\(k / 1000)M" }
        return "\(k)K"
    }
}

// MARK: - Static catalog

enum CoworkKnownModelRegistry {

    private static let catalog: [String: CoworkModelMetadata] = buildCatalog()

    static func metadata(for modelID: String) -> CoworkModelMetadata? {
        let t = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog[t] ?? catalog[t.lowercased()]
    }

    private static func buildCatalog() -> [String: CoworkModelMetadata] {
        var c: [String: CoworkModelMetadata] = [:]

        func register(_ m: CoworkModelMetadata, aliases: [String] = []) {
            c[m.id] = m
            c[m.id.lowercased()] = m
            for a in aliases {
                c[a] = m
                c[a.lowercased()] = m
            }
        }

        // ── Anthropic (direct hyphens + OpenRouter variants) ──────────────────
        let anthropicModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("claude-opus-4-6",            "Claude Opus 4.6",   200, [.vision, .toolUse, .reasoning]),
            ("claude-sonnet-4-6",          "Claude Sonnet 4.6", 200, [.vision, .toolUse, .reasoning]),
            ("claude-haiku-4-5-20251001",  "Claude Haiku 4.5",  200, [.vision, .toolUse]),
            ("claude-opus-4-5",            "Claude Opus 4.5",   200, [.vision, .toolUse, .reasoning]),
            ("claude-sonnet-4-5",          "Claude Sonnet 4.5", 200, [.vision, .toolUse]),
            ("claude-3-7-sonnet-20250219", "Claude 3.7 Sonnet", 200, [.vision, .toolUse, .reasoning]),
            ("claude-3-5-sonnet-20241022", "Claude 3.5 Sonnet", 200, [.vision, .toolUse]),
            ("claude-3-5-haiku-20241022",  "Claude 3.5 Haiku",  200, [.vision, .toolUse]),
        ]
        for (id, name, ctx, caps) in anthropicModels {
            let m = CoworkModelMetadata(id: id, vendorLabel: "Anthropic", displayName: name, contextWindowK: ctx, capabilities: caps)
            // Direct Anthropic uses hyphens; OpenRouter may use dots (e.g. claude-opus-4.6)
            let dotVariant = id.replacingOccurrences(of: "-4-", with: "-4.").replacingOccurrences(of: "-4-5", with: "-4.5")
            register(m, aliases: ["anthropic/\(id)", "anthropic/\(dotVariant)"])
        }

        // ── OpenAI (direct + OpenRouter-prefixed) ─────────────────────────────
        let openAIModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("gpt-4.1",      "GPT-4.1",      1047, [.vision, .toolUse]),
            ("gpt-4.1-mini", "GPT-4.1 Mini", 1047, [.vision, .toolUse]),
            ("gpt-4.1-nano", "GPT-4.1 Nano", 1047, [.vision, .toolUse]),
            ("gpt-4o",       "GPT-4o",        128, [.vision, .toolUse]),
            ("gpt-4o-mini",  "GPT-4o Mini",   128, [.vision, .toolUse]),
            ("o3",           "o3",            200, [.toolUse, .reasoning]),
            ("o3-mini",      "o3 mini",       200, [.toolUse, .reasoning]),
            ("o4-mini",      "o4-mini",       200, [.vision, .toolUse, .reasoning]),
        ]
        for (id, name, ctx, caps) in openAIModels {
            let m = CoworkModelMetadata(id: id, vendorLabel: "OpenAI", displayName: name, contextWindowK: ctx, capabilities: caps)
            register(m, aliases: ["openai/\(id)"])
        }

        // ── Google (primarily OpenRouter-prefixed) ────────────────────────────
        let googleModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("google/gemini-2.5-pro",              "Gemini 2.5 Pro",           1000, [.vision, .toolUse, .reasoning]),
            ("google/gemini-2.5-flash",             "Gemini 2.5 Flash",         1000, [.vision, .toolUse]),
            ("google/gemini-2.5-flash:thinking",    "Gemini 2.5 Flash (Think)", 1000, [.vision, .toolUse, .reasoning]),
            ("google/gemini-2.0-flash-001",         "Gemini 2.0 Flash",         1000, [.vision, .toolUse]),
            ("google/gemini-1.5-pro",               "Gemini 1.5 Pro",           2000, [.vision, .toolUse]),
        ]
        for (id, name, ctx, caps) in googleModels {
            register(CoworkModelMetadata(id: id, vendorLabel: "Google", displayName: name, contextWindowK: ctx, capabilities: caps))
        }

        // ── Meta (primarily OpenRouter-prefixed) ──────────────────────────────
        let metaModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("meta-llama/llama-4-scout",           "Llama 4 Scout",   512, [.vision, .toolUse]),
            ("meta-llama/llama-4-maverick",        "Llama 4 Maverick", 512, [.vision, .toolUse]),
            ("meta-llama/llama-3.3-70b-instruct",  "Llama 3.3 70B",   128, [.toolUse]),
            ("meta-llama/llama-3.1-405b-instruct", "Llama 3.1 405B",  128, [.toolUse]),
        ]
        for (id, name, ctx, caps) in metaModels {
            register(CoworkModelMetadata(id: id, vendorLabel: "Meta", displayName: name, contextWindowK: ctx, capabilities: caps))
        }

        // ── Mistral ───────────────────────────────────────────────────────────
        let mistralModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("mistralai/mistral-large-latest",  "Mistral Large",  128, [.toolUse]),
            ("mistralai/mistral-medium-latest", "Mistral Medium", 128, [.toolUse]),
            ("mistralai/pixtral-large-latest",  "Pixtral Large",  128, [.vision, .toolUse]),
            ("mistral/mistral-large-latest",    "Mistral Large",  128, [.toolUse]),
        ]
        for (id, name, ctx, caps) in mistralModels {
            register(CoworkModelMetadata(id: id, vendorLabel: "Mistral", displayName: name, contextWindowK: ctx, capabilities: caps))
        }

        // ── xAI ───────────────────────────────────────────────────────────────
        let xaiModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("x-ai/grok-3",           "Grok 3",      131, [.toolUse]),
            ("x-ai/grok-3-mini",      "Grok 3 Mini", 131, [.toolUse, .reasoning]),
            ("x-ai/grok-vision-beta", "Grok Vision",   8, [.vision]),
        ]
        for (id, name, ctx, caps) in xaiModels {
            register(CoworkModelMetadata(id: id, vendorLabel: "xAI", displayName: name, contextWindowK: ctx, capabilities: caps))
        }

        // ── DeepSeek ──────────────────────────────────────────────────────────
        let deepseekModels: [(String, String, Int, Set<CoworkModelCapability>)] = [
            ("deepseek/deepseek-r1",        "DeepSeek R1",       128, [.toolUse, .reasoning]),
            ("deepseek/deepseek-r1-0528",   "DeepSeek R1 0528",  128, [.toolUse, .reasoning]),
            ("deepseek/deepseek-chat-v3-5", "DeepSeek Chat V3",   64, [.toolUse]),
        ]
        for (id, name, ctx, caps) in deepseekModels {
            register(CoworkModelMetadata(id: id, vendorLabel: "DeepSeek", displayName: name, contextWindowK: ctx, capabilities: caps))
        }

        // ── Cohere ────────────────────────────────────────────────────────────
        register(CoworkModelMetadata(id: "cohere/command-r-plus-08-2024", vendorLabel: "Cohere",
                                      displayName: "Command R+", contextWindowK: 128, capabilities: [.toolUse]))
        register(CoworkModelMetadata(id: "cohere/command-r-08-2024", vendorLabel: "Cohere",
                                      displayName: "Command R", contextWindowK: 128, capabilities: [.toolUse]))

        return c
    }
}
