import SwiftUI

/// Dedicated 300pt orb section at the top of the main window.
///
/// The orb is the hero — always visible, never covered by conversation text.
/// Includes an ambient glow halo that reflects the current palette color,
/// a status line at the bottom, progress bar at the top, and rescue badge.
struct OrbCrownView: View {
    @EnvironmentObject private var orbAnimation: OrbAnimationState
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var subtitles: SubtitleStateController
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var rescueMode: RescueMode

    /// Optional callback fired when the Metal orb view finishes loading.
    /// Used by ContentView to coordinate the `viewLoaded` fade-in.
    var onLoad: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Ambient glow — soft radial gradient using current palette color.
            // Extends beyond the orb circle to bleed emotional color into surroundings.
            RadialGradient(
                colors: [primaryPaletteColor.opacity(0.12), Color.clear],
                center: .center,
                startRadius: 80,
                endRadius: 200
            )

            // Metal orb — centered, circular, 260x260.
            NativeOrbView(
                orbAnimation: orbAnimation,
                audioRMS: pipelineAux.audioRMS,
                windowMode: windowState.mode.rawValue,
                onLoad: onLoad,
                onOrbClicked: {
                    if windowState.mode == .collapsed {
                        windowState.transitionToCompact()
                        NotificationCenter.default.post(
                            name: .faeConversationEngage,
                            object: nil
                        )
                    }
                },
                onOrbContextMenu: {
                    showOrbContextMenu()
                }
            )
            .frame(width: 260, height: 260)
            .clipShape(Circle())

            // Status line — bottom of crown.
            VStack {
                Spacer()
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: statusText)
                }
            }
            .padding(.bottom, 6)

            // Progress bar — top edge.
            if subtitles.progressPercent != nil {
                VStack {
                    ProgressOverlayView()
                    Spacer()
                }
            }

            // Rescue badge — top-left.
            if rescueMode.isActive {
                VStack {
                    HStack {
                        Text("Rescue Mode")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.gray.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(.leading, 10)
                            .padding(.top, 8)
                        Spacer()
                    }
                    Spacer()
                }
            }


        }
        .frame(height: 300)
    }

    // MARK: - Status Text

    /// Derives status from pipeline and conversation state.
    private var statusText: String {
        if !subtitles.toolText.isEmpty {
            return subtitles.toolText
        }
        if conversation.isStreaming {
            return "Speaking\u{2026}"
        }
        if conversation.isGenerating {
            return "Thinking\u{2026}"
        }
        if conversation.isListening {
            return "Listening\u{2026}"
        }
        return ""
    }

    // MARK: - Palette Color

    /// Primary palette color from the orb animation, converted to SwiftUI Color.
    private var primaryPaletteColor: Color {
        let c = orbAnimation.colors.0
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    // MARK: - Context Menu

    private func showOrbContextMenu() {
        guard let window = windowState.window,
              let contentView = window.contentView else { return }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: Selector(("showSettingsWindow:")),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        let coworkHandler = MenuActionHandler {
            NotificationCenter.default.post(name: .faeOpenCoworkRequested, object: nil)
        }
        let coworkItem = NSMenuItem(
            title: "Open Work with Fae",
            action: #selector(MenuActionHandler.invoke),
            keyEquivalent: ""
        )
        coworkItem.target = coworkHandler
        menu.addItem(coworkItem)

        menu.addItem(.separator())

        let resetHandler = MenuActionHandler { [conversation, subtitles] in
            conversation.clearMessages()
            subtitles.clearAll()
        }
        let resetItem = NSMenuItem(
            title: "Reset Conversation",
            action: #selector(MenuActionHandler.invoke),
            keyEquivalent: ""
        )
        resetItem.target = resetHandler
        menu.addItem(resetItem)

        let hideHandler = MenuActionHandler { [windowState] in
            windowState.hideWindow()
        }
        let hideItem = NSMenuItem(
            title: "Hide Fae",
            action: #selector(MenuActionHandler.invoke),
            keyEquivalent: ""
        )
        hideItem.target = hideHandler
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Fae",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        objc_setAssociatedObject(
            menu, &Self.menuHandlersKey,
            [coworkHandler, resetHandler, hideHandler] as NSArray,
            .OBJC_ASSOCIATION_RETAIN
        )

        let mouseLocation = window.mouseLocationOutsideOfEventStream
        menu.popUp(positioning: nil, at: mouseLocation, in: contentView)
    }

    private static var menuHandlersKey: UInt8 = 0
}

/// Lightweight Objective-C target for NSMenuItem action callbacks.
final class MenuActionHandler: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func invoke() {
        closure()
    }
}
