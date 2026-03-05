import AppKit
import Foundation

/// Provides Edit-menu actions for editing Fae's personality files.
///
/// Opens the user's editable soul.md, heartbeat.md, and directive.md in the system
/// default text editor. Files are read fresh every turn, so edits
/// take effect on the next query.
@MainActor
final class PersonalityEditorController {

    // MARK: - Actions

    /// Open the user's soul.md in the default text editor.
    func showSoulEditor() {
        SoulManager.ensureUserCopy()
        NSWorkspace.shared.open(SoulManager.userSoulURL)
    }

    /// Open the user's directive.md in the default text editor.
    func showInstructionsEditor() {
        let url = directiveURL
        ensureDirectiveFile(at: url)
        NSWorkspace.shared.open(url)
    }

    /// Open the user's heartbeat.md in the default text editor.
    func showHeartbeatEditor() {
        HeartbeatManager.ensureUserCopy()
        NSWorkspace.shared.open(HeartbeatManager.userHeartbeatURL)
    }

    // MARK: - Private

    private var directiveURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/directive.md")
    }

    private func ensureDirectiveFile(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let placeholder = """
            # Fae Directive
            # Critical instructions Fae follows in every conversation.
            # Usually empty — only add rules important enough to always apply.
            # Changes take effect on the next conversation turn.
            """
        try? placeholder.write(to: url, atomically: true, encoding: .utf8)
    }
}
