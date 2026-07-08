import AppKit

/// The hardware-click-only authorize card (security-override Wave 2, L2/L12).
///
/// This is the ONLY production wiring that can produce an `.allow` decision. Its
/// buttons are the ONLY callers of `SecurityOverridePrompt.approve(_:)`; the panel
/// is deliberately NOT connected to any legacy approval route (VoiceCommandParser,
/// TestServer `/approve`, `respondToApproval()`), so a prompt-injected model — which
/// can drive speech/TTS and those routes — cannot self-authorize an override
/// (Invariant H). A hardware click on this card is the sole authorizer.
@MainActor
enum SecurityOverridePanel {

    /// Present the authorize card and await the human's decision. The one-shot
    /// resolve + 10 s timeout (→ Deny) live in `SecurityOverridePrompt`; a late
    /// click after the panel closes is a no-op there. Fae-integrity denials never
    /// reach here (they are not overridable), but if one did the card shows NO
    /// Allow button — Deny only.
    static func present(denial: SecurityDenial, command: String) async -> SecurityOverrideDecision {
        let prompt = SecurityOverridePrompt(denial: denial, command: command)
        let controller = SecurityOverrideWindowController(prompt: prompt)
        controller.show()
        let decision = await prompt.result()
        controller.dismiss()
        return decision
    }
}

/// The AppKit window backing one authorize card. Buttons are wired ONLY to the
/// prompt's `approve(_:)` / `deny()`.
@MainActor
private final class SecurityOverrideWindowController {
    private let prompt: SecurityOverridePrompt
    private let panel: NSPanel
    /// Retains self for the panel's lifetime so button targets stay live.
    private var retain: SecurityOverrideWindowController?

    init(prompt: SecurityOverridePrompt) {
        self.prompt = prompt
        let width: CGFloat = 460
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Authorize sandbox override"
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        buildContent(width: width)
    }

    private func buildContent(width: CGFloat) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 260))

        let heading = NSTextField(labelWithString: "Fae wants to step outside her sandbox")
        heading.font = .boldSystemFont(ofSize: 14)
        heading.frame = NSRect(x: 20, y: 224, width: width - 40, height: 22)
        content.addSubview(heading)

        let body = NSTextField(wrappingLabelWithString: prompt.consentText)
        body.font = .systemFont(ofSize: 12)
        body.isSelectable = true
        body.frame = NSRect(x: 20, y: 64, width: width - 40, height: 152)
        content.addSubview(body)

        // Buttons, right-aligned: Deny (default/safe) + the tier's allow kinds.
        var x = width - 20
        let deny = makeButton(title: "Deny") { [weak self] in self?.prompt.deny() }
        deny.keyEquivalent = "\u{1b}" // Esc → Deny is the safe default.
        x -= deny.frame.width
        deny.frame.origin = NSPoint(x: x, y: 18)
        content.addSubview(deny)

        for kind in prompt.allowedGrantKinds.reversed() {
            let btn = makeButton(title: Self.title(for: kind)) { [weak self] in
                self?.prompt.approve(kind)
            }
            x -= (btn.frame.width + 8)
            btn.frame.origin = NSPoint(x: x, y: 18)
            content.addSubview(btn)
        }

        panel.contentView = content
    }

    private func makeButton(title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, 88)
        let handler = ButtonHandler(action: action)
        button.target = handler
        button.action = #selector(ButtonHandler.fire)
        buttonHandlers.append(handler)
        return button
    }

    private var buttonHandlers: [ButtonHandler] = []

    private static func title(for kind: SecurityGrantKind) -> String {
        switch kind {
        case .once: return "Allow once"
        case .expiring: return "Allow 5 min"
        case .persistent: return "Always allow"
        }
    }

    func show() {
        retain = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        panel.orderOut(nil)
        retain = nil
    }
}

/// A tiny `@objc` target trampoline so a closure can back an `NSButton` action.
@MainActor
private final class ButtonHandler: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
