import SwiftUI

struct EditableSkillDraft: Identifiable, Equatable {
    enum Mode: Equatable {
        case create
        case edit(existingName: String)
    }

    let id = UUID()
    let mode: Mode
    var name: String
    var description: String
    var body: String
    var sourceURLString: String

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var title: String {
        isEditing ? "Edit Skill" : "Create Skill"
    }

    var actionTitle: String {
        isEditing ? "Save Changes" : "Create Skill"
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func new() -> EditableSkillDraft {
        EditableSkillDraft(mode: .create, name: "", description: "", body: "", sourceURLString: "")
    }

    static func loadPersonalSkill(named name: String) -> EditableSkillDraft? {
        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(name)
        let skillURL = skillDir.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillURL, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return EditableSkillDraft(mode: .edit(existingName: name), name: name, description: "", body: text, sourceURLString: "")
        }

        var closingIndex: Int?
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            closingIndex = index
            break
        }
        guard let closingIndex else {
            return EditableSkillDraft(mode: .edit(existingName: name), name: name, description: "", body: text, sourceURLString: "")
        }

        let frontmatter = Array(lines[1..<closingIndex])
        let description = frontmatter.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("description:") })?
            .split(separator: ":", maxSplits: 1)
            .dropFirst()
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        let body = Array(lines[(closingIndex + 1)...]).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return EditableSkillDraft(
            mode: .edit(existingName: name),
            name: name,
            description: description,
            body: body,
            sourceURLString: ""
        )
    }

    static func imported(from rawText: String, sourceURL: URL) throws -> EditableSkillDraft {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw URLError(.cannotDecodeRawData)
        }

        let lines = trimmed.components(separatedBy: .newlines)
        var importedName = sourceURL.deletingPathExtension().lastPathComponent
        var importedDescription = ""
        var importedBody = trimmed

        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            var closingIndex: Int?
            for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                closingIndex = index
                break
            }

            if let closingIndex {
                let frontmatter = Array(lines[1..<closingIndex])
                if let nameLine = frontmatter.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:") }) {
                    importedName = String(nameLine.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let descriptionLine = frontmatter.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("description:") }) {
                    importedDescription = String(descriptionLine.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                importedBody = Array(lines[(closingIndex + 1)...]).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let sanitizedName = importedName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        return EditableSkillDraft(
            mode: .create,
            name: sanitizedName.isEmpty ? "imported-skill" : sanitizedName,
            description: importedDescription,
            body: importedBody,
            sourceURLString: sourceURL.absoluteString
        )
    }
}

struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: EditableSkillDraft
    @State private var isImporting = false
    @State private var importError: String?
    let onSave: (EditableSkillDraft) -> Void

    init(draft: EditableSkillDraft, onSave: @escaping (EditableSkillDraft) -> Void) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Text(draft.title)
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Import from URL")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("https://raw.githubusercontent.com/.../SKILL.md", text: $draft.sourceURLString)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button(isImporting ? "Importing…" : "Import") {
                        Task { await importFromURL() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isImporting || draft.sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("Import a remote SKILL.md, review it locally, then decide whether to save it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.headline)
                TextField("daily-journal-helper", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(draft.isEditing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.headline)
                TextField("What this skill does", text: $draft.description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.headline)
                TextEditor(text: $draft.body)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            securityReviewSection

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(draft.actionTitle) {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    draft.trimmedName.isEmpty
                    || draft.trimmedDescription.count < 10
                    || draft.trimmedBody.count < 20
                )
            }
        }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var securityReviewSection: some View {
        let findings = SkillSecurityReviewer.review(
            name: draft.trimmedName,
            description: draft.trimmedDescription,
            body: draft.trimmedBody,
            sourceURL: URL(string: draft.sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text("Security review")
                .font(.headline)
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color(for: finding.severity))
                    Text(finding.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color(for: finding.severity).opacity(0.08))
                )
            }
        }
    }

    private func color(for severity: SkillSecurityReviewFinding.Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .notice: return .blue
        }
    }

    @MainActor
    private func importFromURL() async {
        isImporting = true
        importError = nil
        defer { isImporting = false }

        do {
            let imported = try await SkillImportService.importDraft(from: draft.sourceURLString)
            draft.name = imported.name
            draft.description = imported.description
            draft.body = imported.body
            draft.sourceURLString = imported.sourceURLString
        } catch {
            importError = error.localizedDescription
        }
    }
}
