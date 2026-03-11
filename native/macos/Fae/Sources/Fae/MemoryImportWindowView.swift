import AppKit
import SwiftUI

struct MemoryImportWindowView: View {
    let memoryInboxServiceProvider: () -> MemoryInboxService?
    let focusMainWindow: () -> Void
    let dismissAction: () -> Void

    @State private var pastedTitle: String = ""
    @State private var pastedText: String = ""
    @State private var urlText: String = ""
    @State private var promptCopied: Bool = false
    @State private var statusMessage: String = "Import text, files, or URLs directly into Fae's memory inbox."
    @State private var statusColor: Color = .secondary
    @State private var isWorking: Bool = false

    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    private static let exportPrompt = """
        I'm moving to another service and need to export my data. List every memory you \
        have stored about me, as well as any context you've learned about me from past \
        conversations. Output everything in a single code block so I can easily copy it.

        Format each entry as: [date saved, if available] - memory content.

        Make sure to cover all of the following - preserve my words verbatim where possible:
        - Instructions I've given you about how to respond (tone, format, style, \
        'always do X', 'never do Y').
        - Personal details: name, location, job, family, interests.
        - Projects, goals, and recurring topics.
        - Tools, languages, and frameworks I use.
        - Preferences and corrections I've made to your behavior.
        - Any other stored context not covered above. Do not summarize, group, or omit \
        any entries.

        After the code block, confirm whether that is the complete set or if any remain.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    migrationSection
                    Divider()
                    pasteSection
                    Divider()
                    urlSection
                    Divider()
                    fileSection
                    Divider()
                    dropFolderSection
                }
                .padding(24)
            }

            Divider()
            actionBar
        }
        .frame(minWidth: 520, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var migrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Migrate from Another Assistant", systemImage: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))

            Text("Use this prompt when you want ChatGPT, Gemini, or another assistant to dump everything it remembers before you paste it here.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text(Self.exportPrompt)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            Button(action: copyPrompt) {
                HStack(spacing: 5) {
                    Image(systemName: promptCopied ? "checkmark" : "doc.on.doc")
                    Text(promptCopied ? "Copied" : "Copy Migration Prompt")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(promptCopied ? .green : Self.heather)
            .disabled(isWorking)
        }
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Paste Text", systemImage: "doc.text.fill")
                .font(.system(size: 14, weight: .semibold))

            TextField("Optional title", text: $pastedTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $pastedText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
                Button("Paste from Clipboard") {
                    pasteFromClipboard()
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)

                Spacer()

                Text("\(pastedText.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Button("Import Pasted Text") {
                importPastedText()
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.heather)
            .disabled(isWorking || pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Import URL", systemImage: "link")
                .font(.system(size: 14, weight: .semibold))

            Text("Fetch a page, extract readable text, and store it as a first-class memory artifact.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("https://example.com/article", text: $urlText)
                    .textFieldStyle(.roundedBorder)

                Button("Import URL") {
                    importURL()
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.heather)
                .disabled(isWorking || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Import Files", systemImage: "paperclip")
                .font(.system(size: 14, weight: .semibold))

            Text("Supports plain text, code, markdown, HTML, RTF, JSON, YAML, and PDF files.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("Choose Files...") {
                    chooseFiles()
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.heather)
                .disabled(isWorking)

                Button("Close") {
                    dismissAction()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var dropFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Drop Folder", systemImage: "folder.fill.badge.plus")
                .font(.system(size: 14, weight: .semibold))

            Text("Testers can also drop files into the pending inbox folder and let the background ingest task sweep them up every five minutes.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("Open Pending Folder") {
                    openPendingFolder()
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)

                Button("Ingest Pending Now") {
                    ingestPendingFiles()
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.heather)
                .disabled(isWorking)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text(statusMessage)
                .font(.system(size: 12))
                .foregroundColor(statusColor)

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.exportPrompt, forType: .string)
        promptCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            promptCopied = false
        }
    }

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            pastedText = string
        }
    }

    private func importPastedText() {
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        runImportTask {
            let service = try requireService()
            let result = try await service.importText(
                title: emptyToNil(pastedTitle),
                text: trimmed
            )
            pastedText = ""
            pastedTitle = ""
            focusMainWindow()
            setStatus(
                result.wasDuplicate
                    ? "That text was already in the memory inbox."
                    : "Imported pasted text into Fae's memory inbox.",
                color: result.wasDuplicate ? .secondary : .green
            )
        }
    }

    private func importURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        runImportTask {
            let service = try requireService()
            let result = try await service.importURL(trimmed)
            urlText = ""
            focusMainWindow()
            setStatus(
                result.wasDuplicate
                    ? "That URL was already imported."
                    : "Imported URL content into Fae's memory inbox.",
                color: result.wasDuplicate ? .secondary : .green
            )
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.title = "Import files into Fae memory"
        if panel.runModal() == .OK {
            let urls = panel.urls
            runImportTask {
                let service = try requireService()
                let results = try await service.importFiles(at: urls)
                focusMainWindow()
                let duplicates = results.filter(\.wasDuplicate).count
                let imported = results.count - duplicates
                if imported > 0 {
                    setStatus(
                        "Imported \(imported) file(s) into Fae's memory inbox." + (duplicates > 0 ? " Skipped \(duplicates) duplicate(s)." : ""),
                        color: .green
                    )
                } else {
                    setStatus("All selected files were already imported.", color: .secondary)
                }
            }
        }
    }

    private func openPendingFolder() {
        runImportTask(showProgress: false) {
            let service = try requireService()
            let pendingURL = try await service.pendingDirectory()
            NSWorkspace.shared.open(pendingURL)
            setStatus("Opened the pending inbox folder.", color: .secondary)
        }
    }

    private func ingestPendingFiles() {
        runImportTask {
            let service = try requireService()
            let results = try await service.ingestPendingFiles()
            focusMainWindow()
            if results.isEmpty {
                setStatus("No new files were waiting in the pending inbox folder.", color: .secondary)
            } else {
                let duplicates = results.filter(\.wasDuplicate).count
                let imported = results.count - duplicates
                setStatus(
                    "Processed \(results.count) pending file(s)." + (imported > 0 ? " Imported \(imported)." : "") + (duplicates > 0 ? " Skipped \(duplicates) duplicate(s)." : ""),
                    color: .green
                )
            }
        }
    }

    private func requireService() throws -> MemoryInboxService {
        if let service = memoryInboxServiceProvider() {
            return service
        }
        throw NSError(
            domain: "MemoryImportWindowView",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Memory inbox is not available until the runtime finishes starting."]
        )
    }

    private func runImportTask(
        showProgress: Bool = true,
        operation: @escaping () async throws -> Void
    ) {
        if showProgress {
            isWorking = true
        }
        Task { @MainActor in
            defer {
                if showProgress {
                    isWorking = false
                }
            }
            do {
                try await operation()
            } catch {
                setStatus(error.localizedDescription, color: .red)
            }
        }
    }

    private func setStatus(_ message: String, color: Color) {
        statusMessage = message
        statusColor = color
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
