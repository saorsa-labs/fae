import AppKit
import SwiftUI

@MainActor
final class CoworkWindowController: NSObject, NSWindowDelegate {
    enum TestingError: LocalizedError {
        case controllerUnavailable
        case invalidImage(String)
        case pasteboardWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .controllerUnavailable:
                return "Cowork controller is not available."
            case .invalidImage(let path):
                return "Could not load image from \(path)."
            case .pasteboardWriteFailed(let detail):
                return "Failed to write test data to the pasteboard: \(detail)"
            }
        }
    }

    private var window: NSWindow?
    private var controller: CoworkWorkspaceController?
    private static let snapshotDateFormatter = ISO8601DateFormatter()

    var currentWindow: NSWindow? { window }

    var faeCore: FaeCore?
    var conversation: ConversationController?
    var runtimeDescriptor: FaeLocalRuntimeDescriptor?
    var orbAnimation: OrbAnimationState?
    var pipelineAux: PipelineAuxBridgeController?

    func show() {
        if let window {
            controller?.scheduleRefresh(after: 0.05)
            announceVisibility(true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let faeCore, let conversation else {
            NSLog("CoworkWindowController: dependencies not wired")
            return
        }

        let controller = CoworkWorkspaceController(
            faeCore: faeCore,
            conversation: conversation,
            runtimeDescriptor: runtimeDescriptor
        )
        let rootView = CoworkWorkspaceView(
            controller: controller,
            faeCore: faeCore,
            conversation: conversation
        )

        let hostingController = NSHostingController(rootView: rootView)
        // Allow the window to freely resize without SwiftUI constraining it to ideal size.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = .minSize
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Work with Fae"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1120, height: 760)
        window.center()
        window.delegate = self
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.controller = controller
        self.window = window
        announceVisibility(true)
    }

    func windowWillClose(_ notification: Notification) {
        announceVisibility(false)
        window = nil
        controller = nil
    }

    private func announceVisibility(_ visible: Bool) {
        NotificationCenter.default.post(
            name: .faeCoworkWindowVisibilityChanged,
            object: nil,
            userInfo: ["visible": visible]
        )
    }

    func openForTesting(section: CoworkWorkspaceSection? = nil) {
        show()

        guard let section else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(
                name: .faeCoworkOpenUtilityRequested,
                object: nil,
                userInfo: ["section": section.rawValue]
            )
        }
    }

    func snapshotForTesting() -> [String: Any] {
        guard let controller else {
            return [
                "visible": window?.isVisible ?? false,
                "initialized": false,
                "attachment_count": 0,
                "attachments": [],
            ]
        }

        return snapshotDictionary(for: controller)
    }

    func clearAttachmentsForTesting() -> [String: Any] {
        guard let controller = ensureControllerForTesting() else {
            return snapshotForTesting()
        }

        controller.clearAttachmentsForTesting()
        return snapshotDictionary(for: controller)
    }

    func addAttachmentsForTesting(paths: [String], replaceExisting: Bool = false) -> [String: Any] {
        guard let controller = ensureControllerForTesting() else {
            return snapshotForTesting()
        }

        if replaceExisting {
            controller.clearAttachmentsForTesting()
        }

        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        controller.addAttachments(from: urls)
        return snapshotDictionary(for: controller)
    }

    func pasteTextForTesting(_ text: String, replaceExisting: Bool = false) throws -> [String: Any] {
        guard let controller = ensureControllerForTesting() else {
            throw TestingError.controllerUnavailable
        }

        if replaceExisting {
            controller.clearAttachmentsForTesting()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TestingError.pasteboardWriteFailed("text")
        }

        controller.addPastedContent()
        return snapshotDictionary(for: controller)
    }

    func pasteImageForTesting(at path: String, replaceExisting: Bool = false) throws -> [String: Any] {
        guard let controller = ensureControllerForTesting() else {
            throw TestingError.controllerUnavailable
        }

        guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else {
            throw TestingError.invalidImage(path)
        }

        if replaceExisting {
            controller.clearAttachmentsForTesting()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            throw TestingError.pasteboardWriteFailed("image")
        }

        controller.addPastedContent()
        return snapshotDictionary(for: controller)
    }

    func pasteFilesForTesting(paths: [String], replaceExisting: Bool = false) throws -> [String: Any] {
        guard let controller = ensureControllerForTesting() else {
            throw TestingError.controllerUnavailable
        }

        if replaceExisting {
            controller.clearAttachmentsForTesting()
        }

        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else {
            throw TestingError.pasteboardWriteFailed("file URLs")
        }

        controller.addPastedContent()
        return snapshotDictionary(for: controller)
    }

    func clearConversationForTesting() -> [String: Any] {
        controller?.clearConversationForTesting()
        conversation?.resetBackgroundLookups()
        return conversationSnapshotForTesting()
    }

    func submitPromptForTesting(_ prompt: String, clearConversation: Bool = false) throws -> [String: Any] {
        guard let controller = ensureControllerForTesting() else {
            throw TestingError.controllerUnavailable
        }

        if clearConversation {
            _ = clearConversationForTesting()
        }

        controller.useQuickPrompt(prompt)
        return conversationSnapshotForTesting()
    }

    func conversationSnapshotForTesting() -> [String: Any] {
        let messages = conversation?.messages.map { message in
            [
                "id": message.id.uuidString,
                "role": message.role.rawValue,
                "content": message.content,
                "timestamp": Self.snapshotDateFormatter.string(from: message.timestamp),
            ]
        } ?? []

        return [
            "visible": window?.isVisible ?? false,
            "message_count": messages.count,
            "messages": messages,
            "is_generating": conversation?.isGenerating ?? false,
            "is_streaming": conversation?.isStreaming ?? false,
            "streaming_text": conversation?.streamingText ?? "",
        ]
    }

    private func ensureControllerForTesting() -> CoworkWorkspaceController? {
        if controller == nil {
            show()
        }
        return controller
    }

    private func snapshotDictionary(for controller: CoworkWorkspaceController) -> [String: Any] {
        let attachments = controller.workspaceState.attachments.map { attachment in
            let preview = WorkWithFaeWorkspaceStore.preview(for: attachment)
            var payload: [String: Any] = [
                "id": attachment.id.uuidString,
                "kind": attachment.kind.rawValue,
                "display_name": attachment.displayName,
                "created_at": Self.snapshotDateFormatter.string(from: attachment.createdAt),
                "is_selected": controller.selectedAttachment?.id == attachment.id,
                "preview_kind": preview.kind,
            ]
            if let path = attachment.path {
                payload["path"] = path
            }
            if let inlineText = attachment.inlineText {
                payload["inline_text"] = String(inlineText.prefix(2_000))
            }
            if let subtitle = preview.subtitle {
                payload["preview_subtitle"] = subtitle
            }
            if let previewText = preview.textPreview {
                payload["preview_text"] = String(previewText.prefix(4_000))
            }
            return payload
        }

        var payload: [String: Any] = [
            "visible": window?.isVisible ?? false,
            "initialized": true,
            "selected_section": controller.selectedSection.rawValue,
            "provider_kind": controller.providerKind.rawValue,
            "provider_status": controller.providerStatus,
            "attachment_count": attachments.count,
            "attachments": attachments,
            "workspace_message_count": controller.workspaceState.conversationMessages.count,
            "recent_activity": controller.activityItems.prefix(5).map { item in
                [
                    "title": item.title,
                    "detail": item.detail,
                    "tone": toneLabel(for: item.tone),
                    "timestamp": Self.snapshotDateFormatter.string(from: item.timestamp),
                ]
            },
        ]

        if let selectedWorkspace = controller.selectedWorkspace {
            payload["selected_workspace_name"] = selectedWorkspace.name
        }
        if let selectedDirectoryPath = controller.workspaceState.selectedDirectoryPath {
            payload["selected_directory_path"] = selectedDirectoryPath
        }
        if let selectedAttachment = controller.selectedAttachment {
            payload["selected_attachment_name"] = selectedAttachment.displayName
        }
        if let preview = controller.focusedPreview {
            payload["focused_preview"] = previewDictionary(preview)
        }

        return payload
    }

    private func previewDictionary(_ preview: WorkWithFaePreview) -> [String: Any] {
        var payload: [String: Any] = [
            "source": preview.source.rawValue,
            "title": preview.title,
            "kind": preview.kind,
        ]
        if let subtitle = preview.subtitle {
            payload["subtitle"] = subtitle
        }
        if let path = preview.path {
            payload["path"] = path
        }
        if let textPreview = preview.textPreview {
            payload["text_preview"] = String(textPreview.prefix(4_000))
        }
        return payload
    }

    private func toneLabel(for tone: CoworkActivityItem.Tone) -> String {
        switch tone {
        case .neutral:
            return "neutral"
        case .success:
            return "success"
        case .warning:
            return "warning"
        }
    }
}
