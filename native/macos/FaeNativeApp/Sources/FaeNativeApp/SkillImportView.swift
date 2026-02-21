import AppKit
import SwiftUI

/// Sheet for importing a custom skill from a URL.
///
/// The user pastes a URL, fetches the content, reviews it in a monospaced
/// editor, and optionally saves it as a `.md` file in `~/.fae/skills/`.
struct SkillImportView: View {
    @Environment(\.dismiss) private var dismiss
    let commandSender: HostCommandSender?

    @State private var urlText: String = ""
    @State private var skillName: String = ""
    @State private var skillContent: String = ""
    @State private var isFetching: Bool = false
    @State private var errorMessage: String? = nil
    @State private var hasFetched: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Skill from URL")
                .font(.headline)

            // URL input
            HStack {
                TextField("Paste skill URL…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { fetchSkill() }

                Button("Fetch") { fetchSkill() }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
                    .buttonStyle(.bordered)
            }

            if isFetching {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if hasFetched {
                // Skill name
                HStack {
                    Text("Skill Name:")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    TextField("my-skill", text: $skillName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }

                // Content editor
                Text("Review the skill content below. Edit if needed, then save or cancel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $skillContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .border(Color.secondary.opacity(0.3), width: 1)
            }

            Spacer()

            // Action buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if hasFetched {
                    Button("Save Skill") { saveSkill() }
                        .disabled(skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || skillContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
    }

    // MARK: - Fetch

    private func fetchSkill() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "Please enter a valid HTTP or HTTPS URL."
            return
        }

        errorMessage = nil
        isFetching = true

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode)
                else {
                    await MainActor.run {
                        errorMessage = "Server returned an error. Check the URL and try again."
                        isFetching = false
                    }
                    return
                }
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    await MainActor.run {
                        errorMessage = "The URL returned empty or non-text content."
                        isFetching = false
                    }
                    return
                }
                await MainActor.run {
                    skillContent = text
                    hasFetched = true
                    isFetching = false

                    // Derive name from URL filename if not already set.
                    if skillName.isEmpty {
                        let filename = url.deletingPathExtension().lastPathComponent
                        let sanitized = filename
                            .replacingOccurrences(of: " ", with: "-")
                            .lowercased()
                            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                        if !sanitized.isEmpty {
                            skillName = sanitized
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Fetch failed: \(error.localizedDescription)"
                    isFetching = false
                }
            }
        }
    }

    // MARK: - Save

    private func saveSkill() {
        let name = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = skillContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !content.isEmpty else { return }

        let skillsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fae/skills")
        do {
            try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            let filePath = skillsDir.appendingPathComponent("\(name).md")
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            NSLog("SkillImportView: saved skill to %@", filePath.path)

            // Tell backend to reload skills.
            commandSender?.sendCommand(name: "skills.reload", payload: [:])

            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}
