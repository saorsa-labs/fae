import AppKit
import SwiftUI

// MARK: - ReceiptsWindowController

/// Manages a floating NSPanel that shows the action receipts timeline.
///
/// The panel is a lightweight non-activating utility window, styled to match
/// ConversationWindowView. Call `show(receiptStore:)` to open/focus it.
///
/// Wiring:
/// - FaeApp creates a single instance and registers for `.faeShowReceiptsPanel`.
/// - FaeCore.receiptStore is passed at show-time (optional — panel opens even without a store).
@MainActor
final class ReceiptsWindowController: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isVisible: Bool = false
    @Published private(set) var receipts: [ActionReceiptRecord] = []

    // MARK: - Private

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    // MARK: - Show

    /// Open or focus the receipts panel. Fetches recent receipts from the store.
    func show(receiptStore: ReceiptStore?) {
        isVisible = true
        Task {
            await refreshReceipts(receiptStore: receiptStore)
            await MainActor.run {
                openOrFocusPanel(receiptStore: receiptStore)
            }
        }
    }

    // MARK: - Hide

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    // MARK: - Refresh

    /// Re-fetch receipts after an undo or other mutation.
    func refresh(receiptStore: ReceiptStore?) {
        Task {
            await refreshReceipts(receiptStore: receiptStore)
        }
    }

    // MARK: - Undo

    /// Perform an undo, refresh the list, and post a narration notification.
    func performUndo(receiptId: String, receiptStore: ReceiptStore?) {
        guard let store = receiptStore else { return }
        Task {
            let result = await store.undo(receiptId: receiptId)
            switch result {
            case .success:
                await refreshReceipts(receiptStore: store)
                NotificationCenter.default.post(
                    name: .faeReceiptUndone,
                    object: nil,
                    userInfo: ["receiptId": receiptId]
                )
            case .failure(let err):
                NSLog("ReceiptsWindowController: undo failed for %@: %@", receiptId, String(describing: err))
            }
        }
    }

    // MARK: - Private Helpers

    private func refreshReceipts(receiptStore: ReceiptStore?) async {
        guard let store = receiptStore else {
            receipts = []
            return
        }
        let fetched = await store.recentReceipts(speakerId: nil, limit: 100)
        receipts = fetched
    }

    private func openOrFocusPanel(receiptStore: ReceiptStore?) {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let newPanel = makePanel()
        let content = makeContentView(receiptStore: receiptStore)
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = newPanel.contentView else { return }
        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        hostingView = hosting
        panel = newPanel
        positionPanel(newPanel)
        newPanel.makeKeyAndOrderFront(nil)
    }

    private func makeContentView(receiptStore: ReceiptStore?) -> AnyView {
        AnyView(
            ReceiptsPanelContentView(
                controller: self,
                receiptStore: receiptStore
            )
            .preferredColorScheme(.dark)
        )
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 520)),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        p.title = "What Fae Changed"
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.backgroundColor = NSColor(red: 0.06, green: 0.063, blue: 0.075, alpha: 0.97)
        p.hasShadow = true
        p.minSize = NSSize(width: 300, height: 300)
        return p
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.maxX - panelSize.width - 20,
            y: screenFrame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - ReceiptsPanelContentView

/// The SwiftUI view hosted inside the receipts panel.
private struct ReceiptsPanelContentView: View {
    @ObservedObject var controller: ReceiptsWindowController
    let receiptStore: ReceiptStore?

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().opacity(0.07)
            ReceiptsTimelineView(
                receipts: controller.receipts,
                onUndo: { receiptId in
                    controller.performUndo(receiptId: receiptId, receiptStore: receiptStore)
                }
            )
        }
        .background(Color(red: 0.06, green: 0.063, blue: 0.075))
        .frame(minWidth: 300, minHeight: 300)
    }

    private var panelHeader: some View {
        HStack {
            Text("WHAT FAE CHANGED")
                .font(.system(size: 11, weight: .medium))
                .tracking(2)
                .foregroundStyle(.primary.opacity(0.45))

            Spacer()

            Button {
                controller.refresh(receiptStore: receiptStore)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted when the user requests the receipts panel to open.
    static let faeShowReceiptsPanel = Notification.Name("faeShowReceiptsPanel")
    /// Posted after a successful undo — pipeline can narrate the reversal.
    static let faeReceiptUndone = Notification.Name("faeReceiptUndone")
}
