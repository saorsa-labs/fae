import Foundation

enum CoworkExportTrustTier: String, Sendable, Equatable {
    case deviceLocal = "device_local"
    case thirdPartyCloud = "third_party_cloud"
}

enum CoworkExportMode: String, Sendable, Equatable {
    case localOnly = "local_only"
    case redactedRemote = "redacted_remote"
}

enum CoworkExportDataClass: String, Sendable, Equatable, Hashable {
    case generalPublic = "public"
    case shareableContext = "shareable_context"
    case workspaceConfidential = "workspace_confidential"
    case privateLocalOnly = "private_local_only"
}

enum CoworkExportTransform: String, Sendable, Equatable, Hashable {
    case trimmed
    case pathStripped = "path_stripped"
    case truncated
    case userSelected = "user_selected"
    case localContextExcluded = "local_context_excluded"
}

enum CoworkExportSectionKind: String, Sendable, Equatable {
    case userPrompt = "user_prompt"
    case attachmentSummary = "attachment_summary"
    case attachmentExcerpt = "attachment_excerpt"
    case focusedAttachment = "focused_attachment"
}

struct CoworkExportSection: Sendable, Equatable {
    let id: String
    let kind: CoworkExportSectionKind
    let dataClass: CoworkExportDataClass
    let transforms: [CoworkExportTransform]
    let artifactHandle: String?
    let content: String
}

struct CoworkExportPacket: Sendable, Equatable {
    let destinationTrustTier: CoworkExportTrustTier
    let mode: CoworkExportMode
    let sections: [CoworkExportSection]
    let excludedDataClasses: [CoworkExportDataClass]
    let excludedContext: [String]

    /// Renders the final prompt for external providers.
    ///
    /// **Prompt positioning optimization (Onyx research):** Context sections come first,
    /// then critical instructions at the END of the context block. LLMs follow
    /// end-positioned instructions ~90% vs ~30% for start-positioned ones.
    /// The user prompt is always the very last content.
    var renderedPrompt: String {
        let userPrompt = sections.first(where: { $0.kind == .userPrompt })?.content ?? ""
        let contextSections = sections.filter { $0.kind != .userPrompt }

        guard !contextSections.isEmpty || !excludedContext.isEmpty else {
            return userPrompt
        }

        // 1. Open context block.
        var lines: [String] = [
            "[WORK WITH FAE CONTEXT]",
        ]

        // 2. Context sections (conversation, attachments, focused items).
        for section in contextSections {
            lines.append(section.content)
        }

        // 3. Excluded context disclosure.
        if !excludedContext.isEmpty {
            lines.append("Context kept on this Mac:")
            for item in excludedContext {
                lines.append("- \(item)")
            }
        }

        // 4. Critical instructions at END (recency bias optimization).
        lines.append("Use only the explicit exported context above. Local-only memory, workspace inventory, and hidden conversation context stayed on this Mac unless included here.")

        // 5. Close context block; user prompt last.
        lines.append("[/WORK WITH FAE CONTEXT]")
        lines.append(userPrompt)
        return lines.joined(separator: "\n")
    }

    var appliedTransforms: [CoworkExportTransform] {
        var seen: Set<CoworkExportTransform> = []
        var ordered: [CoworkExportTransform] = []

        for transform in sections.flatMap(\.transforms) {
            if seen.insert(transform).inserted {
                ordered.append(transform)
            }
        }

        if !excludedContext.isEmpty, seen.insert(.localContextExcluded).inserted {
            ordered.append(.localContextExcluded)
        }

        return ordered
    }

    var containsLocalOnlyContext: Bool {
        !excludedContext.isEmpty || excludedDataClasses.contains(.workspaceConfidential) || excludedDataClasses.contains(.privateLocalOnly)
    }

    var contextScopeLabel: String {
        containsLocalOnlyContext ? "redacted_shareable" : "shareable"
    }

    var hasRedactions: Bool {
        containsLocalOnlyContext || appliedTransforms.contains(.pathStripped)
    }
}
