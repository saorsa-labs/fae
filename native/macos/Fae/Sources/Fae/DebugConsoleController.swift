import Foundation
import AppKit
import SwiftUI

// MARK: - Event types

enum DebugEventKind: String, CaseIterable {
    case stt = "STT"
    case llmToken = "LLM"
    case llmThink = "Think"
    case speaker = "Speaker"
    case toolCall = "Tool→"
    case toolResult = "Tool←"
    case memory = "Memory"
    case command = "Command"
    case governance = "Govern"
    case approval = "Approve"
    case qa = "QA"
    case pipeline = "Pipeline"

    var color: Color {
        switch self {
        case .stt:        return .blue
        case .llmToken:   return .purple
        case .llmThink:   return .indigo
        case .speaker:    return .teal
        case .toolCall:   return .orange
        case .toolResult: return Color(red: 0.9, green: 0.7, blue: 0)
        case .memory:     return .green
        case .command:    return .mint
        case .governance: return .pink
        case .approval:   return .yellow
        case .qa:         return .cyan
        case .pipeline:   return .gray
        }
    }
}

struct DebugEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let kind: DebugEventKind
    let text: String
}

// MARK: - Controller

/// Accumulates real-time debug events from the Fae pipeline.
///
/// Call `log(_:_:)` from any actor context — it dispatches to the main actor
/// internally, so callers need not be `@MainActor`.
@MainActor
final class DebugConsoleController: ObservableObject {
    @Published var events: [DebugEvent] = []

    /// When false, `log()` is a no-op (zero overhead when console is hidden).
    var isEnabled: Bool = true

    /// Optional callback for file logging (set by TestServer when active).
    /// Called with (event, sequenceIndex) after each event is appended.
    var fileLoggerCallback: ((DebugEvent, Int) -> Void)?

    private static let maxEvents = 500

    func log(_ kind: DebugEventKind, _ text: String) {
        guard isEnabled else { return }
        let event = DebugEvent(timestamp: Date(), kind: kind, text: text)
        events.append(event)
        fileLoggerCallback?(event, events.count - 1)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    func clear() {
        events.removeAll()
    }

    /// Copies all events to the pasteboard as plain text.
    func copyAll() {
        let lines = events.map { event in
            "[\(Self.timeFormatter.string(from: event.timestamp))] [\(event.kind.rawValue)] \(event.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Helper: log from a non-isolated (actor) context without `await`.
/// Dispatches to the main actor asynchronously — call sites do not need to `await`.
func debugLog(_ controller: DebugConsoleController?, _ kind: DebugEventKind, _ text: String) {
    guard let controller else { return }
    Task { @MainActor in
        controller.log(kind, text)
    }
}
