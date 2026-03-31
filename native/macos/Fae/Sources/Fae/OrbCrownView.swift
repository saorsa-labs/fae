import SwiftUI

/// Dedicated 300pt orb section at the top of the main window.
///
/// The orb is the hero — always visible, never covered by conversation text.
/// Includes an ambient glow halo that reflects the current palette color,
/// a mood arc above the orb, a status capsule at the bottom,
/// progress bar at the top, and rescue badge.
struct OrbCrownView: View {
    @EnvironmentObject private var orbAnimation: OrbAnimationState
    @EnvironmentObject private var orbState: OrbStateController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var subtitles: SubtitleStateController
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var rescueMode: RescueMode

    /// Whether the mood arc is expanded (tap to collapse).
    @AppStorage("orbMoodExpanded") private var moodExpanded: Bool = true

    /// Breathing animation phase — drives scale and opacity pulsing.
    @State private var breathe: Bool = false

    /// Mood linger: keeps the arc visible after pipeline goes idle.
    @State private var moodLingerActive: Bool = false
    @State private var moodLingerTask: Task<Void, Never>?

    /// Gentle pulse phase for the status dot.
    @State private var dotPulse: Bool = false

    /// Optional callback fired when the Metal orb view finishes loading.
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

            // Metal orb — centered, organic SDF blob, 260x260.
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
                        NotificationCenter.default.post(
                            name: .faePTTPressed,
                            object: nil
                        )
                    } else if windowState.mode == .compact {
                        windowState.transitionToCollapsed()
                    }
                },
                onOrbContextMenu: {
                    showOrbContextMenu()
                }
            )
            .frame(width: 260, height: 260)

            // Mood arc — above the orb, arched text with breathing animation.
            moodArc
                .offset(y: -100)

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

            // Dev mode badge — top-right.
            if FaeEnvironment.isDev {
                VStack {
                    HStack {
                        Spacer()
                        Text("DEV")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(.trailing, 10)
                            .padding(.top, 8)
                    }
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
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                breathe = true
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                dotPulse = true
            }
        }
        .onChange(of: orbState.feeling) { _, newFeeling in
            moodLingerTask?.cancel()
            if newFeeling != .neutral {
                withAnimation(.easeInOut(duration: 0.4)) { moodLingerActive = true }
                moodLingerTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 1.2)) { moodLingerActive = false }
                }
            } else {
                withAnimation(.easeOut(duration: 0.8)) { moodLingerActive = false }
            }
        }
    }

    // MARK: - Mood Arc (above the orb)

    /// Large, friendly mood display arced above the orb with breathing animation.
    @ViewBuilder
    private var moodArc: some View {
        let feeling = orbState.feeling
        let isActive = statusMode != nil
        // Show mood arc when engaged (Listening/Thinking/Speaking) OR when lingering after idle.
        // During active states, show the mode as "engaged" mood even if feeling is still .neutral.
        let showMood = moodExpanded && (isActive || moodLingerActive)

        if showMood {
            let color = feelingColor(feeling)
            let label = (isActive && feeling == .neutral) ? statusModeLabel : feeling.label
            let icon = (isActive && feeling == .neutral) ? statusModeIcon : feelingIcon(feeling)

            VStack(spacing: 4) {
                // Icon — large, breathing.
                Text(icon)
                    .font(.system(size: 22))
                    .scaleEffect(breathe ? 1.12 : 0.92)
                    .opacity(breathe ? 1.0 : 0.7)

                // Label — warm, readable.
                Text(label)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
                    .opacity(breathe ? 1.0 : 0.75)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(color.opacity(breathe ? 0.14 : 0.08))
                    .blur(radius: 1)
            )
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(breathe ? 0.25 : 0.10), lineWidth: 1)
            )
            .scaleEffect(breathe ? 1.02 : 0.98)
            .shadow(color: color.opacity(0.3), radius: breathe ? 12 : 6)
            .transition(.opacity.combined(with: .scale(scale: 0.8)).combined(with: .move(edge: .bottom)))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) { moodExpanded.toggle() }
            }
        }
    }

    /// Mode name to use as mood label when feeling is .neutral during active states.
    private var statusModeLabel: String {
        statusMode ?? "Engaged"
    }

    /// Mode icon to use as mood icon when feeling is .neutral during active states.
    private var statusModeIcon: String {
        switch statusMode {
        case "Listening\u{2026}": return "\u{1F50A}"  // 🔊
        case "Thinking\u{2026}": return "\u{1F4AD}"  // 💭
        case "Speaking\u{2026}": return "\u{1F50A}"  // 🔊
        default: return "\u{25CB}"  // ○
        }
    }

    // MARK: - Status Capsule (below the orb)

    /// Mode indicator — Listening/Thinking/Speaking with pulsing dot.
    @ViewBuilder
    private var statusCapsule: some View {
        let mode = statusMode
        let feeling = orbState.feeling

        if let mode {
            HStack(spacing: 5) {
                Circle()
                    .fill(feelingColor(feeling))
                    .frame(width: 6, height: 6)
                    .scaleEffect(dotPulse ? 1.15 : 0.85)
                    .opacity(dotPulse ? 1.0 : 0.7)

                Text(mode)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
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

    /// Color associated with each feeling — warm, saturated for visibility.
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

    /// Larger, friendlier icon for each feeling.
    private func feelingIcon(_ feeling: OrbFeeling) -> String {
        switch feeling {
        case .neutral:   return "\u{25CB}"  // ○
        case .calm:      return "\u{1F30A}" // 🌊
        case .curiosity: return "\u{2728}"  // ✨
        case .warmth:    return "\u{1F9E1}" // 🧡
        case .concern:   return "\u{1F494}" // 💔
        case .delight:   return "\u{2B50}"  // ⭐
        case .focus:     return "\u{1F3AF}" // 🎯
        case .playful:   return "\u{1F60A}" // 😊
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
