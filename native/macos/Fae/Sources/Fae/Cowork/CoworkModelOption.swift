import Foundation

struct CoworkModelOption: Identifiable, Hashable, Sendable {
    let providerKind: CoworkLLMProviderKind
    let providerPresetID: String
    let providerDisplayName: String
    let baseURL: String
    let modelIdentifier: String
    let vendorLabel: String
    let compactLabel: String
    let displayTitle: String
    let displaySubtitle: String
    let searchText: String
    let requiresCredential: Bool
    let isConfigured: Bool

    var id: String { "\(providerPresetID)::\(baseURL.lowercased())::\(modelIdentifier.lowercased())" }

    var accessibilityLabel: String {
        if displaySubtitle == providerDisplayName {
            return "\(displayTitle), \(providerDisplayName)"
        }
        return "\(displayTitle), \(displaySubtitle)"
    }

    var providerSortRank: Int {
        switch providerKind {
        case .faeLocalhost: return 0
        case .anthropic: return 1
        case .openAICompatibleExternal: return providerPresetID == "openrouter" ? 3 : 2
        }
    }
}

func modelOptions(
    from models: [String],
    for preset: CoworkBackendPreset,
    baseURL: String? = nil,
    isConfigured: Bool = true
) -> [CoworkModelOption] {
    var seen = Set<String>()
    return models.compactMap { model in
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: preset.defaultBaseURL)
        let cacheKey = "\(preset.id.lowercased())::\(normalizedBaseURL.lowercased())::\(trimmed.lowercased())"
        guard !trimmed.isEmpty, seen.insert(cacheKey).inserted else { return nil }
        return modelOption(for: trimmed, preset: preset, baseURL: normalizedBaseURL, isConfigured: isConfigured)
    }
}

func modelOption(
    for model: String,
    preset: CoworkBackendPreset,
    baseURL: String? = nil,
    isConfigured: Bool = true
) -> CoworkModelOption? {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalizedBaseURL = CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: preset.defaultBaseURL)
    let vendor = vendorLabel(for: trimmed, preset: preset)
    let compact = compactModelLabel(for: trimmed, preset: preset)
    let subtitle: String
    if vendor == preset.displayName || compact == preset.displayName {
        subtitle = preset.displayName
    } else {
        subtitle = "\(vendor) via \(preset.displayName)"
    }

    return CoworkModelOption(
        providerKind: preset.providerKind,
        providerPresetID: preset.id,
        providerDisplayName: preset.displayName,
        baseURL: normalizedBaseURL,
        modelIdentifier: trimmed,
        vendorLabel: vendor,
        compactLabel: compact,
        displayTitle: compact,
        displaySubtitle: subtitle,
        searchText: [trimmed, compact, vendor, preset.displayName, subtitle].joined(separator: " "),
        requiresCredential: preset.requiresAPIKey,
        isConfigured: isConfigured
    )
}

func modelOptionID(for model: String, preset: CoworkBackendPreset, baseURL: String? = nil) -> String? {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalizedBaseURL = CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: preset.defaultBaseURL)
    return "\(preset.id)::\(normalizedBaseURL.lowercased())::\(trimmed.lowercased())"
}

func compactModelLabel(for model: String, preset: CoworkBackendPreset? = nil) -> String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "fae-agent-local" || preset?.providerKind == .faeLocalhost {
        return "Fae Local"
    }
    guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
    return String(trimmed[trimmed.index(after: slash)...])
}

func vendorLabel(for model: String, preset: CoworkBackendPreset) -> String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init)?.lowercased()
    switch prefix {
    case "openai": return "OpenAI"
    case "anthropic": return "Anthropic"
    case "google": return "Google"
    case "minimax": return "MiniMax"
    case "meta": return "Meta"
    case "mistralai": return "Mistral"
    case "mistral": return "Mistral"
    case "x-ai": return "xAI"
    case "xai": return "xAI"
    case "deepseek": return "DeepSeek"
    case "qwen": return "Qwen"
    case "liquid": return "Liquid"
    case "cohere": return "Cohere"
    case "perplexity": return "Perplexity"
    case "moonshotai": return "Moonshot AI"
    case "microsoft": return "Microsoft"
    case "amazon": return "Amazon"
    case .none:
        break
    case .some(let value):
        return value.split(separator: "-").map { $0.capitalized }.joined(separator: "-")
    }

    if preset.id == "anthropic" {
        return "Anthropic"
    }
    if preset.id == "openai" {
        return "OpenAI"
    }
    return preset.displayName
}
