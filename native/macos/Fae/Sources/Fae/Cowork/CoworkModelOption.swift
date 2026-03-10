import Foundation

struct CoworkModelOption: Identifiable, Hashable, Sendable {
    let providerKind: CoworkLLMProviderKind
    let providerPresetID: String
    let providerDisplayName: String
    let baseURL: String
    let modelIdentifier: String
    let vendorLabel: String
    let vendorGroup: String             // vendor for section grouping (e.g. "Anthropic", "OpenAI")
    let compactLabel: String
    let displayTitle: String
    let displaySubtitle: String
    let searchText: String
    let requiresCredential: Bool
    let isConfigured: Bool
    let contextWindowK: Int?            // context window in K tokens (nil = unknown)
    let capabilities: Set<CoworkModelCapability>

    var id: String { "\(providerPresetID)::\(baseURL.lowercased())::\(modelIdentifier.lowercased())" }

    var contextWindowLabel: String? {
        guard let k = contextWindowK else { return nil }
        if k >= 1000 { return "\(k / 1000)M" }
        return "\(k)K"
    }

    // Used by filteredModelOptionSections to group OpenRouter models by vendor
    var sectionGroupKey: String {
        if providerPresetID == "openrouter", !vendorGroup.isEmpty, vendorGroup != providerDisplayName {
            return "openrouter::\(vendorGroup.lowercased())"
        }
        return providerPresetID
    }

    var sectionTitle: String {
        if providerPresetID == "openrouter", !vendorGroup.isEmpty, vendorGroup != providerDisplayName {
            return vendorGroup
        }
        return providerDisplayName
    }

    var sectionSubtitleExtra: String {
        if providerPresetID == "openrouter", !vendorGroup.isEmpty, vendorGroup != providerDisplayName {
            return "via OpenRouter"
        }
        return ""
    }

    // Sort rank within the model picker — lower = first
    var sectionSortRank: Int {
        switch providerPresetID {
        case "fae-local":  return 0
        case "anthropic":  return 1
        case "openai":     return 2
        case "openrouter":
            switch vendorGroup.lowercased() {
            case "anthropic": return 10
            case "openai":    return 11
            case "google":    return 12
            case "meta":      return 13
            case "mistral":   return 14
            case "xai":       return 15
            case "deepseek":  return 16
            case "cohere":    return 17
            default:          return 20
            }
        default: return 5
        }
    }

    // Keep for backward compatibility with existing call sites
    var providerSortRank: Int { sectionSortRank }

    var accessibilityLabel: String {
        if displaySubtitle == providerDisplayName {
            return "\(displayTitle), \(providerDisplayName)"
        }
        return "\(displayTitle), \(displaySubtitle)"
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
    let knownMeta = CoworkKnownModelRegistry.metadata(for: trimmed)
    let vendor = knownMeta?.vendorLabel ?? vendorLabel(for: trimmed, preset: preset)
    let compact = compactModelLabel(for: trimmed, preset: preset)

    let subtitle: String
    if vendor == preset.displayName || compact == preset.displayName {
        subtitle = preset.displayName
    } else {
        subtitle = "\(vendor) via \(preset.displayName)"
    }

    let caps = knownMeta?.capabilities ?? []
    let capText = caps.map(\.rawValue).sorted().joined(separator: " ")
    let ctxText = knownMeta?.contextWindowLabel ?? ""

    return CoworkModelOption(
        providerKind: preset.providerKind,
        providerPresetID: preset.id,
        providerDisplayName: preset.displayName,
        baseURL: normalizedBaseURL,
        modelIdentifier: trimmed,
        vendorLabel: vendor,
        vendorGroup: vendor,
        compactLabel: compact,
        displayTitle: knownMeta?.displayName ?? compact,
        displaySubtitle: subtitle,
        searchText: [trimmed, compact, vendor, preset.displayName, subtitle, capText, ctxText].joined(separator: " "),
        requiresCredential: preset.requiresAPIKey,
        isConfigured: isConfigured,
        contextWindowK: knownMeta?.contextWindowK,
        capabilities: caps
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
    case "openai":      return "OpenAI"
    case "anthropic":   return "Anthropic"
    case "google":      return "Google"
    case "minimax":     return "MiniMax"
    case "meta", "meta-llama": return "Meta"
    case "mistralai", "mistral": return "Mistral"
    case "x-ai", "xai": return "xAI"
    case "deepseek":    return "DeepSeek"
    case "qwen":        return "Qwen"
    case "liquid":      return "Liquid"
    case "cohere":      return "Cohere"
    case "perplexity":  return "Perplexity"
    case "moonshotai":  return "Moonshot AI"
    case "microsoft":   return "Microsoft"
    case "amazon":      return "Amazon"
    case .none:
        break
    case .some(let value):
        return value.split(separator: "-").map { $0.capitalized }.joined(separator: "-")
    }
    if preset.id == "anthropic" { return "Anthropic" }
    if preset.id == "openai" { return "OpenAI" }
    return preset.displayName
}
