import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var orbState: OrbStateController
    @State private var orbLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                OrbWebView(
                    mode: orbState.mode,
                    palette: orbState.palette,
                    feeling: orbState.feeling,
                    onLoad: { withAnimation(.easeIn(duration: 0.4)) { orbLoaded = true } }
                )
                .opacity(orbLoaded ? 1 : 0)

                if !orbLoaded {
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 200, height: 200)
                        .scaleEffect(0.95)
                        .opacity(0.5)
                        .animation(
                            .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: orbLoaded
                        )
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Fae orb, currently \(orbState.mode.label) and feeling \(orbState.feeling.label)")

            statusBar
        }
        .background(Color.black)
    }

    private var header: some View {
        HStack {
            Text("Fae")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Spacer()
            Text(handoff.currentTarget.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var statusBar: some View {
        HStack {
            Text(handoff.handoffStateText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(orbState.mode.label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }
}
