import SwiftUI
import AppKit

// MARK: - Window view

struct DebugConsoleWindowView: View {
    @ObservedObject var controller: DebugConsoleController
    @State private var autoScroll = true
    @State private var copyConfirmation: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            eventList
        }
        .font(.system(.caption, design: .monospaced))
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Debug Console")
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)

            Button("Clear") {
                controller.clear()
                copyConfirmation = nil
            }
            .buttonStyle(.borderless)
            .font(.system(.caption, design: .monospaced))
            .disabled(controller.events.isEmpty)

            if let copyConfirmation {
                Text(copyConfirmation)
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.leading, 4)
            }

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(.caption, design: .monospaced))

            Divider()
                .frame(height: 14)

            Button("Copy All") {
                controller.copyAll()
                copyConfirmation = "Copied"
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copyConfirmation = nil
                }
            }
            .buttonStyle(.borderless)
            .font(.system(.caption, design: .monospaced))
            .disabled(controller.events.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(controller.events) { event in
                        DebugEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: controller.events.count) {
                if autoScroll, let last = controller.events.last {
                    withAnimation(.none) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Event row

private struct DebugEventRow: View {
    let event: DebugEvent

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: event.timestamp))
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)

            Text(event.kind.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(event.kind.color)
                .frame(width: 62, alignment: .leading)

            Text(event.text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}
