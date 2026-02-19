import SwiftUI

/// A small device-icon button for the conversation toolbar that opens a
/// popover with the device transfer picker. Hidden when handoff is disabled.
struct HandoffToolbarButton: View {
    @EnvironmentObject private var handoff: DeviceHandoffController
    @EnvironmentObject private var orbState: OrbStateController
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Transfer conversation to another device")
        .accessibilityLabel("Device handoff")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Transfer to")
                    .font(.headline)
                    .padding(.bottom, 2)

                ForEach([DeviceTarget.iphone, DeviceTarget.watch]) { target in
                    Button {
                        handoff.move(
                            to: target,
                            sourceCommand: "move to my \(target.label.lowercased())"
                        )
                        orbState.mode = .listening
                        showPopover = false
                    } label: {
                        Label(target.label, systemImage: target.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Transfer to \(target.label)")
                }
            }
            .padding()
            .frame(width: 180)
        }
    }
}
