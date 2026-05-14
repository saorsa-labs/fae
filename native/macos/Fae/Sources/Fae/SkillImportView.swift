import AppKit
import SwiftUI

/// Sheet for importing a custom skill from a URL.
///
/// The user pastes a URL, fetches the content, reviews it in a monospaced
/// editor, and optionally saves it as a directory-based `SKILL.md` entry in
/// `~/Library/Application Support/fae/skills/`.
///
/// When hosted in a standalone NSPanel (via `suggest_import`), pass a
/// `dismissAction` closure — SwiftUI's `@Environment(\.dismiss)` does not
/// close AppKit panels.
struct SkillImportView: View {
    @Environment(\.dismiss) private var dismiss
    let commandSender: HostCommandSender?
    /// Pre-populated URL from suggest_import tool action.
    var initialURL: String?
    /// Explicit close action for standalone NSPanel hosting.
    /// When nil, falls back to SwiftUI dismiss (works in sheet presentation).
    var dismissAction: (() -> Void)?

    @State private var urlText: String = ""
    @State private var skillName: String = ""
    @State private var skillContent: String = ""
    @State private var isFetching: Bool = false
    @State private var errorMessage: String? = nil
    @State private var hasFetched: Bool = false
    @State private var fetchedContentIsHTML: Bool = false
    @State private var executableSkillWarning: Bool = false
    @State private var overwriteTarget: String?
    @State private var showOverwriteConfirm: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Skill from URL")
                .font(.headline)

            Text("Paste a URL to a raw SKILL.md file. GitHub repo URLs are auto-converted to raw content.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // URL input
            HStack {
                TextField("Paste skill URL\u{2026}", text: $urlText)
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
                    Text("Fetching\u{2026}")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if executableSkillWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This skill references scripts but only SKILL.md was imported. "
                         + "The instructions will work, but executable scripts need the full repository. "
                         + "Clone the repo manually for full functionality.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
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
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if hasFetched {
                    Button("Save Skill") { saveSkill() }
                        .disabled(skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || skillContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || fetchedContentIsHTML)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
        .onAppear {
            if let url = initialURL, !url.isEmpty, urlText.isEmpty {
                urlText = url
            }
        }
        .alert("Overwrite Existing Skill?", isPresented: $showOverwriteConfirm) {
            Button("Cancel", role: .cancel) {
                overwriteTarget = nil
            }
            Button("Replace", role: .destructive) {
                // Re-call saveSkill — overwriteTarget is now set so it won't prompt again.
                saveSkill()
            }
        } message: {
            Text("A skill named '\(overwriteTarget ?? "")' already exists. Replacing it will remove the old version including any scripts and configuration.")
        }
    }

    // MARK: - Close

    private func closeWindow() {
        if let action = dismissAction {
            action()
        } else {
            dismiss()
        }
    }

    // MARK: - URL Normalization

    /// Convert GitHub repo/blob URLs to raw content URLs.
    ///
    /// - `github.com/user/repo/blob/main/SKILL.md` → `raw.githubusercontent.com/user/repo/main/SKILL.md`
    /// - `github.com/user/repo` → `raw.githubusercontent.com/user/repo/main/SKILL.md` (guess)
    /// - Already raw URLs pass through unchanged.
    static func normalizeGitHubURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString),
              url.host?.contains("github.com") == true
        else { return urlString }

        let path = url.pathComponents.filter { $0 != "/" }
        // github.com/user/repo/blob/branch/path/to/SKILL.md
        if path.count >= 4, path[2] == "blob" {
            let user = path[0]
            let repo = path[1]
            let branch = path[3]
            let filePath = path[4...].joined(separator: "/")
            return "https://raw.githubusercontent.com/\(user)/\(repo)/\(branch)/\(filePath)"
        }
        // github.com/user/repo — guess main/SKILL.md
        if path.count == 2 {
            return "https://raw.githubusercontent.com/\(path[0])/\(path[1])/main/SKILL.md"
        }
        return urlString
    }

    // MARK: - Fetch

    private func fetchSkill() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalizeGitHubURL(trimmed)
        guard let url = URL(string: normalized), url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "Please enter a valid HTTP or HTTPS URL."
            return
        }

        if normalized != trimmed {
            urlText = normalized
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

                // Detect HTML responses (repo pages, 404 pages, etc.)
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let looksLikeHTML = trimmedText.hasPrefix("<!") || trimmedText.hasPrefix("<html")
                    || trimmedText.lowercased().contains("<!doctype html")

                await MainActor.run {
                    skillContent = text
                    hasFetched = true
                    isFetching = false
                    fetchedContentIsHTML = looksLikeHTML

                    if looksLikeHTML {
                        errorMessage = "This URL returned HTML (a web page), not a raw SKILL.md file. "
                            + "For GitHub repos, use the raw file URL or navigate to the SKILL.md file and click 'Raw'. "
                            + "Save is disabled until valid skill content is fetched."
                    }

                    // Detect executable skills that reference scripts we can't import.
                    executableSkillWarning = !looksLikeHTML
                        && (text.contains("scripts/") || text.contains("script_name")
                            || text.contains("run_skill"))

                    // Derive name from URL filename if not already set.
                    if skillName.isEmpty {
                        let filename = url.deletingPathExtension().lastPathComponent
                        let sanitized = filename
                            .replacingOccurrences(of: " ", with: "-")
                            .lowercased()
                            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                        if !sanitized.isEmpty, sanitized != "skill" {
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
        let uiName = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = skillContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uiName.isEmpty, !content.isEmpty else { return }

        // Agent Skills spec: name must be lowercase alphanumeric + hyphens.
        // Underscores and uppercase are normalized away.
        let dirName = uiName
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !dirName.isEmpty else {
            errorMessage = "Invalid skill name '\(uiName)'. Use lowercase letters, numbers, and hyphens."
            return
        }

        // Ensure frontmatter name == directory name (Agent Skills spec requirement).
        // If the content has a frontmatter name that differs, rewrite it.
        var normalized = normalizeSkillMarkdown(name: dirName, content: content)
        let frontmatterName = Self.extractFrontmatterName(from: normalized)
        if let fmName = frontmatterName, fmName != dirName {
            // Rewrite the name: line in frontmatter to match directory name.
            normalized = Self.rewriteFrontmatterName(in: normalized, newName: dirName)
        }

        if dirName != uiName {
            skillName = dirName
        }

        // Validate frontmatter before touching disk — write to a temp file and parse.
        let skillsDir = SkillManager.skillsDirectory
        let skillDir = skillsDir.appendingPathComponent(dirName, isDirectory: true)
        let existsAlready = FileManager.default.fileExists(atPath: skillDir.path)

        // Confirm overwrite if the skill already exists.
        if existsAlready && overwriteTarget != dirName {
            overwriteTarget = dirName
            showOverwriteConfirm = true
            return
        }
        overwriteTarget = nil

        do {
            // Validate in a temp location first so we never corrupt an existing skill.
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("fae-skill-validate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let tempFile = tempDir.appendingPathComponent("SKILL.md")
            try normalized.write(to: tempFile, atomically: true, encoding: .utf8)

            guard SkillParser.parse(skillURL: tempFile, tier: .personal) != nil else {
                errorMessage = "The skill has invalid or missing frontmatter (name and description are required). "
                    + "Edit the content to add valid YAML frontmatter before saving."
                return
            }

            // Validation passed — now write to the real location.
            // On re-import: remove old directory to clear stale scripts/manifest.
            if existsAlready {
                try FileManager.default.removeItem(at: skillDir)
                NSLog("SkillImportView: removed existing skill '%@' for clean re-import", dirName)
            }
            try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

            let filePath = skillDir.appendingPathComponent("SKILL.md")
            try normalized.write(to: filePath, atomically: true, encoding: .utf8)
            NSLog("SkillImportView: saved skill '%@' to %@", dirName, filePath.path)

            // Warn if the skill references scripts but we only imported SKILL.md.
            if executableSkillWarning {
                NSLog("SkillImportView: warning — skill '%@' references scripts but none were imported", dirName)
            }

            commandSender?.sendCommand(name: "skills.reload", payload: [:])

            closeWindow()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    /// Extract the `name:` field from SKILL.md YAML frontmatter.
    static func extractFrontmatterName(from content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                let value = String(trimmed.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Rewrite the `name:` line in YAML frontmatter to match the directory name.
    private static func rewriteFrontmatterName(in content: String, newName: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                // Preserve leading whitespace from the original line.
                let leadingWhitespace = lines[i].prefix(while: { $0 == " " })
                lines[i] = "\(leadingWhitespace)name: \(newName)"
                return lines.joined(separator: "\n")
            }
        }
        return content
    }

    private func normalizeSkillMarkdown(name: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("---") {
            return trimmed + (trimmed.hasSuffix("\n") ? "" : "\n")
        }

        return """
            ---
            name: \(name)
            description: Imported skill (update this description if needed).
            metadata:
              author: imported
              version: "1.0"
            ---

            \(trimmed)
            """
    }
}
