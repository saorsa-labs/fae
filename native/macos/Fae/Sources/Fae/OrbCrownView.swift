import SwiftUI

/// Dedicated 300pt orb section at the top of the main window.
///
/// The orb is the hero — always visible, never covered by conversation text.
/// Includes an ambient glow halo that reflects the current palette color,
/// a status capsule at the bottom (mode + feeling), progress bar at the top,
/// and rescue badge.
struct OrbCrownView: View {
    @EnvironmentObject private var orbAnimation: OrbAnimationState
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var subtitles: SubtitleStateController
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var rescueMode: RescueMode

    /// Whether the mood detail row beneath the status is expanded.
    @AppStorage("orbMoodExpanded") private var moodExpanded: Bool = true

    /// Gentle pulse phase for the mood dot.
    @State private var moodPulse: Bool = false

    /// Optional callback fired when the Metal orb view finishes loading.
    /// Used by ContentView to coordinate the `viewLoaded` fade-in.
    var onLoad: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Ambient glow — soft radial gradient using current palette color.
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

            // Status capsule — bottom of crown.
            VStack(spacing: 3) {
                Spacer()
                statusCapsule
            }
            .padding(.bottom, 4)

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
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                moodPulse = true
            }
        }
    }

    // MARK: - Status Capsule

    /// Combined status + mood indicator with collapse toggle.
    @ViewBuilder
    private var statusCapsule: some View {
        let mode = statusMode
        let feeling = orbState.feeling
        let isActive = mode != nil

        VStack(spacing: 2) {
            // Primary status line — always visible when active.
            if let mode {
                HStack(spacing: 5) {
                    // Pulsing dot in the mood color.
                    Circle()
                        .fill(feelingColor(feeling))
                        .frame(width: 6, height: 6)
                        .scaleEffect(moodPulse ? 1.15 : 0.85)
                        .opacity(moodPulse ? 1.0 : 0.7)

                    Text(mode)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Expandable mood detail — shows feeling label with icon.
            if isActive, moodExpanded, feeling != .neutral {
                HStack(spacing: 4) {
                    Text(feelingIcon(feeling))
                        .font(.system(size: 9))
                    Text(feeling.label)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(feelingColor(feeling).opacity(0.9))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(feelingColor(feeling).opacity(0.12))
                .clipShape(Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: mode)
        .animation(.easeInOut(duration: 0.4), value: feeling)
        .animation(.easeInOut(duration: 0.3), value: moodExpanded)
        .onTapGesture {
            withAnimation { moodExpanded.toggle() }
        }
    }

    // MARK: - Status Mode

    /// Current mode as display text, or nil when idle.
    private var statusMode: String? {
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
        return nil
    }

    // MARK: - Feeling Appearance

    /// Color associated with each feeling — reflects the emotional tone.
    private func feelingColor(_ feeling: OrbFeeling) -> Color {
        switch feeling {
        case .neutral:   return .white
        case .calm:      return Color(red: 0.55, green: 0.75, blue: 0.95) // soft blue
        case .curiosity: return Color(red: 0.65, green: 0.82, blue: 0.55) // sage green
        case .warmth:    return Color(red: 0.95, green: 0.75, blue: 0.45) // warm amber
        case .concern:   return Color(red: 0.85, green: 0.55, blue: 0.55) // muted rose
        case .delight:   return Color(red: 0.95, green: 0.85, blue: 0.40) // golden
        case .focus:     return Color(red: 0.55, green: 0.60, blue: 0.90) // indigo
        case .playful:   return Color(red: 0.85, green: 0.60, blue: 0.90) // lavender
        }
    }

    /// Subtle icon for each feeling — keeps it lightweight.
    private func feelingIcon(_ feeling: OrbFeeling) -> String {
        switch feeling {
        case .neutral:   return "\u{25CB}" // ○
        case .calm:      return "\u{223F}" // ∿
        case .curiosity: return "\u{2727}" // ✧
        case .warmth:    return "\u{2665}" // ♥
        case .concern:   return "\u{25C7}" // ◇
        case .delight:   return "\u{2736}" // ✶
        case .focus:     return "\u{25CE}" // ◎
        case .playful:   return "\u{2605}" // ★
        }
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
