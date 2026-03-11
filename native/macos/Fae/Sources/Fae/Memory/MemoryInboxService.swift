import CryptoKit
import Foundation
import PDFKit

struct MemoryImportResult: Sendable {
    var artifact: MemoryArtifact
    var record: MemoryRecord
    var wasDuplicate: Bool
}

actor MemoryInboxService {
    enum ImportError: LocalizedError {
        case invalidURL
        case unsupportedFileType(String)
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The URL is invalid."
            case .unsupportedFileType(let name):
                return "Unsupported file type: \(name)"
            case .emptyContent:
                return "No readable text was found to import."
            }
        }
    }

    private static let searchOrchestrator = SearchOrchestrator()
    private static let supportedTextExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "log", "xml", "yaml", "yml",
        "html", "htm", "rtf", "toml", "swift", "rs", "py", "js", "ts", "tsx",
        "jsx", "css", "c", "h", "cpp", "hpp", "go", "java", "kt",
    ]

    private let store: SQLiteMemoryStore

    init(store: SQLiteMemoryStore) {
        self.store = store
    }

    func importText(
        title: String? = nil,
        text: String,
        origin: String? = nil,
        sourceType: MemoryArtifactSourceType = .pastedText
    ) async throws -> MemoryImportResult {
        try await storeImportedArtifact(
            sourceType: sourceType,
            title: title,
            origin: origin,
            mimeType: "text/plain",
            rawText: text,
            metadata: artifactMetadataJSON(
                title: title,
                origin: origin,
                mimeType: "text/plain",
                extra: [:]
            )
        )
    }

    func importURL(_ urlString: String) async throws -> MemoryImportResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw ImportError.invalidURL
        }
        if let blockedReason = FetchURLTool.blockedReason(for: trimmed) {
            throw NSError(
                domain: "MemoryInboxService",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: blockedReason]
            )
        }

        let page = try await Self.searchOrchestrator.fetchPageContent(urlString: trimmed)
        return try await storeImportedArtifact(
            sourceType: .url,
            title: page.title.isEmpty ? url.host : page.title,
            origin: page.url,
            mimeType: "text/html",
            rawText: page.text,
            metadata: artifactMetadataJSON(
                title: page.title,
                origin: page.url,
                mimeType: "text/html",
                extra: ["word_count": "\(page.wordCount)"]
            )
        )
    }

    func importFiles(
        at urls: [URL],
        sourceType: MemoryArtifactSourceType = .file
    ) async throws -> [MemoryImportResult] {
        var results: [MemoryImportResult] = []
        results.reserveCapacity(urls.count)
        for url in urls {
            results.append(try await importFile(at: url, sourceType: sourceType))
        }
        return results
    }

    func importFile(
        at fileURL: URL,
        sourceType: MemoryArtifactSourceType = .file
    ) async throws -> MemoryImportResult {
        let fileInfo = try Self.extractFileText(from: fileURL, preferredSourceType: sourceType)
        return try await storeImportedArtifact(
            sourceType: fileInfo.sourceType,
            title: fileURL.lastPathComponent,
            origin: fileURL.path,
            mimeType: fileInfo.mimeType,
            rawText: fileInfo.text,
            metadata: artifactMetadataJSON(
                title: fileURL.lastPathComponent,
                origin: fileURL.path,
                mimeType: fileInfo.mimeType,
                extra: [
                    "filename": fileURL.lastPathComponent,
                    "extension": fileURL.pathExtension.lowercased(),
                ]
            )
        )
    }

    func ingestPendingFiles(limit: Int = 16) async throws -> [MemoryImportResult] {
        try prepareInboxDirectories()
        let pendingURL = try Self.pendingInboxURL()
        let processedURL = try Self.processedInboxURL()
        let rejectedURL = try Self.rejectedInboxURL()

        let contents = try FileManager.default.contentsOfDirectory(
            at: pendingURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        let files = try contents
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .sorted {
                let lhs = try $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                let rhs = try $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                return lhs < rhs
            }

        var results: [MemoryImportResult] = []
        for fileURL in files.prefix(max(1, limit)) {
            do {
                let result = try await importFile(at: fileURL)
                try Self.moveFile(fileURL, toDirectory: processedURL)
                results.append(result)
            } catch {
                try? Self.moveFile(fileURL, toDirectory: rejectedURL)
                NSLog("MemoryInboxService: failed to import %@: %@", fileURL.path, error.localizedDescription)
            }
        }
        return results
    }

    func inboxDirectory() throws -> URL {
        try Self.inboxRootURL()
    }

    func pendingDirectory() throws -> URL {
        try Self.pendingInboxURL()
    }

    func prepareInboxDirectories() throws {
        for url in [try Self.inboxRootURL(), try Self.pendingInboxURL(), try Self.processedInboxURL(), try Self.rejectedInboxURL()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func storeImportedArtifact(
        sourceType: MemoryArtifactSourceType,
        title: String?,
        origin: String?,
        mimeType: String?,
        rawText: String,
        metadata: String?
    ) async throws -> MemoryImportResult {
        let normalizedText = Self.normalizeImportedText(rawText)
        guard !normalizedText.isEmpty else {
            throw ImportError.emptyContent
        }

        let contentHash = Self.sha256Hex(normalizedText)
        let artifactUpsert = try await store.upsertArtifact(
            sourceType: sourceType,
            title: title,
            origin: origin,
            mimeType: mimeType,
            rawText: normalizedText,
            contentHash: contentHash,
            metadata: metadata
        )
        let artifact = artifactUpsert.artifact

        if let existingRecord = try await store.linkedRecordForArtifact(id: artifact.id) {
            return MemoryImportResult(artifact: artifact, record: existingRecord, wasDuplicate: true)
        }

        if let existingRecord = try await store.linkedRecordForContentHash(contentHash) {
            try await store.linkRecordSource(
                recordId: existingRecord.id,
                artifactId: artifact.id,
                role: .artifact
            )
            return MemoryImportResult(
                artifact: artifact,
                record: existingRecord,
                wasDuplicate: !artifactUpsert.inserted
            )
        }

        let record = try await store.insertRecord(
            kind: .fact,
            text: Self.importedRecordText(
                sourceType: sourceType,
                title: title,
                origin: origin,
                rawText: normalizedText
            ),
            confidence: 0.74,
            sourceTurnId: "artifact:\(artifact.id)",
            tags: ["imported", "artifact", sourceType.rawValue],
            importanceScore: 0.70,
            metadata: recordMetadataJSON(
                artifactId: artifact.id,
                title: title,
                origin: origin,
                sourceType: sourceType,
                mimeType: mimeType
            )
        )
        try await store.linkRecordSource(
            recordId: record.id,
            artifactId: artifact.id,
            role: .artifact
        )
        return MemoryImportResult(artifact: artifact, record: record, wasDuplicate: false)
    }

    private func artifactMetadataJSON(
        title: String?,
        origin: String?,
        mimeType: String?,
        extra: [String: String]
    ) -> String? {
        var payload: [String: String] = [
            "imported_at": Self.isoFormatter.string(from: Date()),
        ]
        if let title, !title.isEmpty {
            payload["title"] = title
        }
        if let origin, !origin.isEmpty {
            payload["origin"] = origin
        }
        if let mimeType, !mimeType.isEmpty {
            payload["mime_type"] = mimeType
        }
        for (key, value) in extra where !value.isEmpty {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func recordMetadataJSON(
        artifactId: String,
        title: String?,
        origin: String?,
        sourceType: MemoryArtifactSourceType,
        mimeType: String?
    ) -> String? {
        var payload: [String: String] = [
            "artifact_id": artifactId,
            "source_type": sourceType.rawValue,
            "imported_at": Self.isoFormatter.string(from: Date()),
        ]
        if let title, !title.isEmpty {
            payload["title"] = title
        }
        if let origin, !origin.isEmpty {
            payload["origin"] = origin
        }
        if let mimeType, !mimeType.isEmpty {
            payload["mime_type"] = mimeType
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func importedRecordText(
        sourceType: MemoryArtifactSourceType,
        title: String?,
        origin: String?,
        rawText: String
    ) -> String {
        var lines = ["Imported memory from \(sourceLabel(for: sourceType))."]
        if let title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let origin, !origin.isEmpty {
            lines.append("Origin: \(origin)")
        }
        lines.append("")
        lines.append(rawText)
        return lines.joined(separator: "\n")
    }

    private struct ImportedFile {
        let sourceType: MemoryArtifactSourceType
        let mimeType: String
        let text: String
    }

    private static func extractFileText(
        from url: URL,
        preferredSourceType: MemoryArtifactSourceType
    ) throws -> ImportedFile {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw ImportError.unsupportedFileType(url.lastPathComponent)
            }
            let text = document.string ?? ""
            return ImportedFile(sourceType: .pdf, mimeType: "application/pdf", text: text)
        }

        if ext == "rtf" {
            let data = try Data(contentsOf: url)
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return ImportedFile(sourceType: preferredSourceType, mimeType: "text/rtf", text: attributed.string)
        }

        if supportedTextExtensions.contains(ext) || ext.isEmpty {
            let text = try readPlainText(url: url)
            let mimeType = ext == "html" || ext == "htm" ? "text/html" : "text/plain"
            let normalized = (ext == "html" || ext == "htm")
                ? ContentExtractor.stripAllHTMLTags(text)
                : text
            return ImportedFile(sourceType: preferredSourceType, mimeType: mimeType, text: normalized)
        }

        throw ImportError.unsupportedFileType(url.lastPathComponent)
    }

    private static func readPlainText(url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .utf16) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
            return text
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw ImportError.unsupportedFileType(url.lastPathComponent)
        }
        return text
    }

    private static func normalizeImportedText(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(MemoryConstants.maxArtifactTextLen))
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceLabel(for sourceType: MemoryArtifactSourceType) -> String {
        sourceType.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private static func moveFile(_ url: URL, toDirectory directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private static func appSupportDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "MemoryInboxService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve Application Support directory."]
            )
        }
        return base.appendingPathComponent("fae", isDirectory: true)
    }

    static func inboxRootURL() throws -> URL {
        try appSupportDirectory().appendingPathComponent("memory-inbox", isDirectory: true)
    }

    static func pendingInboxURL() throws -> URL {
        try inboxRootURL().appendingPathComponent("pending", isDirectory: true)
    }

    static func processedInboxURL() throws -> URL {
        try inboxRootURL().appendingPathComponent("processed", isDirectory: true)
    }

    static func rejectedInboxURL() throws -> URL {
        try inboxRootURL().appendingPathComponent("rejected", isDirectory: true)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
