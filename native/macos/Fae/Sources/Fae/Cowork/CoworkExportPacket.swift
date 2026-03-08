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

    var renderedPrompt: String {
        let userPrompt = sections.first(where: { $0.kind == .userPrompt })?.content ?? ""
        let contextSections = sections.filter { $0.kind != .userPrompt }

        guard !contextSections.isEmpty || !excludedContext.isEmpty else {
            return userPrompt
        }

        var lines: [String] = [
            "[WORK WITH FAE CONTEXT]",
            "Use only the explicit exported context below. Local-only memory, workspace inventory, and hidden conversation context stayed on this Mac unless included here.",
        ]

        for section in contextSections {
            lines.append(section.content)
        }

        if !excludedContext.isEmpty {
            lines.append("Context kept on this Mac:")
            for item in excludedContext {
                lines.append("- \(item)")
            }
        }

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
