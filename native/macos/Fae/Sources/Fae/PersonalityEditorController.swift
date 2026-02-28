import AppKit
import Foundation

/// Provides Edit-menu actions for editing Fae's personality files.
///
/// Opens the user's editable soul.md and custom_instructions.txt in
/// the system default text editor. Files are read fresh every turn,
/// so edits take effect on the next query.
@MainActor
final class PersonalityEditorController {

    // MARK: - Actions

    /// Open the user's soul.md in the default text editor.
    func showSoulEditor() {
        SoulManager.ensureUserCopy()
        NSWorkspace.shared.open(SoulManager.userSoulURL)
    }

    /// Open the user's custom_instructions.txt in the default text editor.
    func showInstructionsEditor() {
        let url = customInstructionsURL
        ensureCustomInstructionsFile(at: url)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private var customInstructionsURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/custom_instructions.txt")
    }

    private func ensureCustomInstructionsFile(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let placeholder = """
            # Fae Custom Instructions
            # Add your personal style preferences here.
            # Changes take effect on the next conversation turn.
            """
        try? placeholder.write(to: url, atomically: true, encoding: .utf8)
    }
}
