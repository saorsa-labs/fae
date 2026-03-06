import AppKit
import Foundation
import UniformTypeIdentifiers

struct WorkWithFaeFileEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let absolutePath: String
    let kind: String
    let sizeBytes: Int64
    let modifiedAt: Date?

    init(id: String, relativePath: String, absolutePath: String, kind: String, sizeBytes: Int64, modifiedAt: Date?) {
        self.id = id
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    init(url: URL, relativeTo root: URL) {
        let standardized = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let path = standardized.path
        let relative: String
        if path.hasPrefix(rootPath) {
            let trimmed = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            relative = trimmed.isEmpty ? standardized.lastPathComponent : trimmed
        } else {
            relative = standardized.lastPathComponent
        }

        let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        self.id = path
        self.relativePath = relative
        self.absolutePath = path
        self.kind = Self.kindForFile(url: standardized, isDirectory: values?.isDirectory == true)
        self.sizeBytes = Int64(values?.fileSize ?? 0)
        self.modifiedAt = values?.contentModificationDate
    }

    private static func kindForFile(url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        let ext = url.pathExtension.lowercased()
        if ["swift", "rs", "py", "js", "ts", "tsx", "jsx", "json", "toml", "yaml", "yml", "md", "txt", "html", "css", "c", "h", "cpp", "hpp", "go", "java", "kt"].contains(ext) {
            return "text"
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
            return "image"
        }
        if ["pdf", "doc", "docx", "rtf"].contains(ext) {
            return "document"
        }
        return ext.isEmpty ? "file" : ext
    }
}

struct WorkWithFaeAttachment: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case image
        case text
    }

    let id: UUID
    let kind: Kind
    let displayName: String
    let path: String?
    let inlineText: String?
    let createdAt: Date

    init(kind: Kind, displayName: String, path: String? = nil, inlineText: String? = nil, createdAt: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.inlineText = inlineText
        self.createdAt = createdAt
    }
}

struct WorkWithFaeWorkspaceState: Codable, Sendable {
    var selectedDirectoryPath: String?
    var indexedFiles: [WorkWithFaeFileEntry]
    var attachments: [WorkWithFaeAttachment]

    static let empty = WorkWithFaeWorkspaceState(selectedDirectoryPath: nil, indexedFiles: [], attachments: [])
}

struct WorkWithFaePreview: Sendable, Equatable {
    enum Source: String, Sendable {
        case workspaceFile
        case attachment
    }

    let source: Source
    let title: String
    let subtitle: String?
    let kind: String
    let path: String?
    let textPreview: String?
}

enum WorkWithFaeProviderTrust: Sendable {
    case faeLocalhost
    case externalOpenAICompatible
}

struct WorkWithFaePreparedPrompt: Sendable, Equatable {
    let userVisiblePrompt: String
    let faeLocalPrompt: String
    let shareablePrompt: String
    let containsLocalOnlyContext: Bool
}

enum WorkWithFaeWorkspaceStore {
    private static let maxIndexedFiles = 800
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", "build", "dist", "node_modules", ".next", ".idea", ".swiftpm", "DerivedData"
    ]

    static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/work_with_fae_workspace.json")
    }

    static var attachmentsDirectory: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("workspace-attachments", isDirectory: true)
    }

    static func load() -> WorkWithFaeWorkspaceState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? decoder.decode(WorkWithFaeWorkspaceState.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    static func save(_ state: WorkWithFaeWorkspaceState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    static func scanDirectory(_ root: URL) -> [WorkWithFaeFileEntry] {
        let fm = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .nameKey]
        guard let enumerator = fm.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [WorkWithFaeFileEntry] = []
        results.reserveCapacity(256)

        for case let fileURL as URL in enumerator {
            if results.count >= maxIndexedFiles { break }
            let values = try? fileURL.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if let name = values?.name, ignoredDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            results.append(WorkWithFaeFileEntry(url: fileURL, relativeTo: standardizedRoot))
        }

        return results.sorted { lhs, rhs in
            lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    static func attachments(from urls: [URL]) -> [WorkWithFaeAttachment] {
        urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let kind: WorkWithFaeAttachment.Kind = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) ? .image : .file
            return WorkWithFaeAttachment(kind: kind, displayName: url.lastPathComponent, path: url.standardizedFileURL.path)
        }
    }

    static func filteredFiles(_ files: [WorkWithFaeFileEntry], query: String) -> [WorkWithFaeFileEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        let lowered = trimmed.lowercased()
        return files.filter {
            $0.relativePath.lowercased().contains(lowered)
                || $0.kind.lowercased().contains(lowered)
        }
    }

    static func preview(for file: WorkWithFaeFileEntry) -> WorkWithFaePreview {
        let path = file.absolutePath
        let url = URL(fileURLWithPath: path)
        if file.kind == "image" {
            return WorkWithFaePreview(
                source: .workspaceFile,
                title: file.relativePath,
                subtitle: "Image file",
                kind: file.kind,
                path: path,
                textPreview: nil
            )
        }

        let previewText = loadTextPreview(from: url)
        return WorkWithFaePreview(
            source: .workspaceFile,
            title: file.relativePath,
            subtitle: file.kind.capitalized,
            kind: file.kind,
            path: path,
            textPreview: previewText
        )
    }

    static func preview(for attachment: WorkWithFaeAttachment) -> WorkWithFaePreview {
        switch attachment.kind {
        case .text:
            return WorkWithFaePreview(
                source: .attachment,
                title: attachment.displayName,
                subtitle: "Pasted text",
                kind: "text",
                path: nil,
                textPreview: attachment.inlineText
            )
        case .image:
            return WorkWithFaePreview(
                source: .attachment,
                title: attachment.displayName,
                subtitle: "Image attachment",
                kind: "image",
                path: attachment.path,
                textPreview: nil
            )
        case .file:
            let previewText = attachment.path.map { loadTextPreview(from: URL(fileURLWithPath: $0)) }
            let ext = attachment.path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "file"
            return WorkWithFaePreview(
                source: .attachment,
                title: attachment.displayName,
                subtitle: "File attachment",
                kind: ext.isEmpty ? "file" : ext,
                path: attachment.path,
                textPreview: previewText ?? nil
            )
        }
    }

    static func attachmentFromPasteboardImage(_ image: NSImage) -> WorkWithFaeAttachment? {
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let fileURL = attachmentsDirectory.appendingPathComponent("pasted-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return WorkWithFaeAttachment(kind: .image, displayName: fileURL.lastPathComponent, path: fileURL.path)
        } catch {
            return nil
        }
    }

    static func textAttachment(_ text: String) -> WorkWithFaeAttachment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preview = String(trimmed.prefix(40))
        return WorkWithFaeAttachment(kind: .text, displayName: preview + (trimmed.count > 40 ? "…" : ""), inlineText: trimmed)
    }

    static func dropURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }

    static func preparePrompt(
        userPrompt: String,
        state: WorkWithFaeWorkspaceState,
        focusedPreview: WorkWithFaePreview? = nil
    ) -> WorkWithFaePreparedPrompt {
        let trimmedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.selectedDirectoryPath != nil || !state.attachments.isEmpty || focusedPreview != nil else {
            return WorkWithFaePreparedPrompt(
                userVisiblePrompt: trimmedPrompt,
                faeLocalPrompt: trimmedPrompt,
                shareablePrompt: trimmedPrompt,
                containsLocalOnlyContext: false
            )
        }

        var localLines: [String] = [
            "[WORK WITH FAE CONTEXT]",
            "Use this workspace context to ground your answer. Prefer the selected workspace and attached files before asking the user to re-explain.",
        ]
        var shareableLines: [String] = [
            "[WORK WITH FAE CONTEXT]",
            "Use explicitly attached items as grounding. Do not assume access to the full local workspace unless the user pasted or attached it here.",
        ]
        var containsLocalOnlyContext = false

        if let selectedDirectoryPath = state.selectedDirectoryPath {
            containsLocalOnlyContext = true
            localLines.append("Workspace root: \(selectedDirectoryPath)")
            localLines.append("Indexed files: \(state.indexedFiles.count)")
            if !state.indexedFiles.isEmpty {
                localLines.append("Workspace file inventory sample:")
                for entry in state.indexedFiles.prefix(40) {
                    localLines.append("- \(entry.relativePath) [\(entry.kind)]")
                }
                localLines.append("If you need more detail from these files, inspect the relevant paths directly.")
            }
        }

        if !state.attachments.isEmpty {
            localLines.append("Attached items:")
            shareableLines.append("Attached items:")
            for attachment in state.attachments.prefix(12) {
                switch attachment.kind {
                case .text:
                    localLines.append("- text: \(attachment.displayName)")
                    shareableLines.append("- text: \(attachment.displayName)")
                    if let inlineText = attachment.inlineText {
                        let snippet = String(inlineText.prefix(1200))
                        localLines.append("  snippet: \(snippet)")
                        shareableLines.append("  snippet: \(snippet)")
                    }
                case .image:
                    let line = "- image: \(attachment.displayName) @ \(attachment.path ?? "unknown")"
                    localLines.append(line)
                    shareableLines.append(line)
                case .file:
                    let line = "- file: \(attachment.displayName) @ \(attachment.path ?? "unknown")"
                    localLines.append(line)
                    shareableLines.append(line)
                }
            }
        }

        if let focusedPreview {
            localLines.append("Focused item:")
            localLines.append("- title: \(focusedPreview.title)")
            if let subtitle = focusedPreview.subtitle {
                localLines.append("- type: \(subtitle)")
            }
            if let path = focusedPreview.path {
                localLines.append("- path: \(path)")
            }
            if let textPreview = focusedPreview.textPreview, !textPreview.isEmpty {
                localLines.append("- preview:\n\(String(textPreview.prefix(2400)))")
            }
            localLines.append("Prioritize this focused item when answering if it appears relevant.")

            if focusedPreview.source == .attachment {
                shareableLines.append("Focused item:")
                shareableLines.append("- title: \(focusedPreview.title)")
                if let subtitle = focusedPreview.subtitle {
                    shareableLines.append("- type: \(subtitle)")
                }
                if let path = focusedPreview.path {
                    shareableLines.append("- path: \(path)")
                }
                if let textPreview = focusedPreview.textPreview, !textPreview.isEmpty {
                    shareableLines.append("- preview:\n\(String(textPreview.prefix(2400)))")
                }
                shareableLines.append("Prioritize this focused item when answering if it appears relevant.")
            } else {
                containsLocalOnlyContext = true
            }
        }

        localLines.append("[/WORK WITH FAE CONTEXT]")
        localLines.append(trimmedPrompt)
        shareableLines.append("[/WORK WITH FAE CONTEXT]")
        shareableLines.append(trimmedPrompt)

        return WorkWithFaePreparedPrompt(
            userVisiblePrompt: trimmedPrompt,
            faeLocalPrompt: localLines.joined(separator: "\n"),
            shareablePrompt: shareableLines.joined(separator: "\n"),
            containsLocalOnlyContext: containsLocalOnlyContext
        )
    }

    static func contextualPrompt(
        userPrompt: String,
        state: WorkWithFaeWorkspaceState,
        focusedPreview: WorkWithFaePreview? = nil
    ) -> String {
        preparePrompt(userPrompt: userPrompt, state: state, focusedPreview: focusedPreview).faeLocalPrompt
    }

    private static func loadTextPreview(from url: URL, maxCharacters: Int = 8_000) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(maxCharacters))
        }
        return nil
    }
}
