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
        EditableSkillDraft(mode: .create, name: "", description: "", body: "")
    }

    static func loadPersonalSkill(named name: String) -> EditableSkillDraft? {
        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(name)
        let skillURL = skillDir.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillURL, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return EditableSkillDraft(mode: .edit(existingName: name), name: name, description: "", body: text)
        }

        var closingIndex: Int?
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            closingIndex = index
            break
        }
        guard let closingIndex else {
            return EditableSkillDraft(mode: .edit(existingName: name), name: name, description: "", body: text)
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
            body: body
        )
    }
}

struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: EditableSkillDraft
    let onSave: (EditableSkillDraft) -> Void

    init(draft: EditableSkillDraft, onSave: @escaping (EditableSkillDraft) -> Void) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.title)
                .font(.title2.bold())

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
        .padding(24)
        .frame(minWidth: 560, minHeight: 520)
    }
}
