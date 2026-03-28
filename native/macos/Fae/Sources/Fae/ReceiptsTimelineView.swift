import SwiftUI

// MARK: - ReceiptsTimelineView

/// Displays action receipts grouped into time buckets with one-tap undo.
///
/// Groups receipts into "This conversation" (last 30 min), "Today" (same calendar day),
/// and "This week" (last 7 days). Only non-empty groups are shown.
struct ReceiptsTimelineView: View {
    let receipts: [ActionReceiptRecord]
    let onUndo: (String) async -> Void

    var body: some View {
        if receipts.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let grouped = groupReceipts(receipts)
                    ForEach(grouped, id: \.label) { group in
                        sectionHeader(group.label)
                        ForEach(group.items, id: \.id) { receipt in
                            ReceiptRowView(receipt: receipt, onUndo: onUndo)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FaeDesign.textFaint)
            Text("Nothing yet")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(FaeDesign.textMuted)
            Text("Fae will log changes here as she works.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(FaeDesign.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(1.5)
            .foregroundStyle(FaeDesign.textFaint)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    // MARK: - Grouping

    private struct ReceiptGroup {
        let label: String
        let items: [ActionReceiptRecord]
    }

    private func groupReceipts(_ items: [ActionReceiptRecord]) -> [ReceiptGroup] {
        let now = Date()
        let conversationCutoff = now.addingTimeInterval(-30 * 60)
        let todayStart = Calendar.current.startOfDay(for: now)
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)

        var conversation: [ActionReceiptRecord] = []
        var today: [ActionReceiptRecord] = []
        var week: [ActionReceiptRecord] = []

        for item in items {
            let date = Date(timeIntervalSince1970: Double(item.createdAt))
            if date >= conversationCutoff {
                conversation.append(item)
            } else if date >= todayStart {
                today.append(item)
            } else if date >= weekCutoff {
                week.append(item)
            }
        }

        var groups: [ReceiptGroup] = []
        if !conversation.isEmpty { groups.append(ReceiptGroup(label: "This conversation", items: conversation)) }
        if !today.isEmpty { groups.append(ReceiptGroup(label: "Earlier today", items: today)) }
        if !week.isEmpty { groups.append(ReceiptGroup(label: "This week", items: week)) }
        return groups
    }
}

// MARK: - ReceiptRowView

private struct ReceiptRowView: View {
    let receipt: ActionReceiptRecord
    let onUndo: (String) async -> Void

    @State private var isUndoing = false

    var body: some View {
        HStack(spacing: 10) {
            // Tool icon
            Image(systemName: toolIcon(for: receipt.toolName))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(FaeDesign.heatherMistText)
                .frame(width: 20)

            // Label + timestamp
            VStack(alignment: .leading, spacing: 2) {
                Text(humanLabel(for: receipt))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FaeDesign.textSecondary)
                    .lineLimit(2)
                Text(relativeTime(from: receipt.createdAt))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(FaeDesign.textFaint)
            }

            Spacer()

            // Undo button (reversible only, not already undone)
            if receipt.reversibility == ActionReversibility.reversible.rawValue {
                if receipt.undoneAt != nil {
                    Text("Undone")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FaeDesign.glenGreenText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(FaeDesign.glenGreen.opacity(0.18))
                        .clipShape(Capsule())
                } else {
                    Button {
                        Task {
                            isUndoing = true
                            await onUndo(receipt.id)
                            isUndoing = false
                        }
                    } label: {
                        if isUndoing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 44, height: 20)
                        } else {
                            Text("Undo")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(FaeDesign.heatherMistText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .background(FaeDesign.heatherMist.opacity(0.18))
                    .clipShape(Capsule())
                    .disabled(isUndoing)
                }
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
        }
    }

    // MARK: - Tool Icon

    private func toolIcon(for toolName: String) -> String {
        switch toolName {
        case "write", "edit": return "doc.badge.plus"
        case "bash": return "terminal"
        case "calendar": return "calendar"
        case "reminders": return "checklist"
        case "contacts": return "person.crop.circle"
        case "notes": return "note.text"
        case "mail": return "envelope"
        case "self_config": return "gearshape"
        case "channel_setup": return "bubble.left.and.bubble.right"
        case "scheduler_create", "scheduler_update", "scheduler_delete": return "calendar.badge.clock"
        case "manage_skill": return "sparkles"
        case "plugin_manage": return "puzzlepiece.extension"
        case "voice_identity": return "waveform.and.person.filled"
        default: return "wrench"
        }
    }

    // MARK: - Human Label

    private func humanLabel(for receipt: ActionReceiptRecord) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(receipt.argumentsJSON.utf8))) as? [String: Any] ?? [:]

        switch receipt.toolName {
        case "write":
            if let path = args["path"] as? String {
                return "Wrote \(shortPath(path))"
            }
            return "Wrote a file"
        case "edit":
            if let path = args["path"] as? String {
                return "Edited \(shortPath(path))"
            }
            return "Edited a file"
        case "bash":
            if let command = args["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = String(trimmed.prefix(48))
                return "Ran: \(preview)\(trimmed.count > 48 ? "…" : "")"
            }
            return "Ran a shell command"
        case "calendar":
            let action = args["action"] as? String ?? "updated"
            if let title = args["title"] as? String {
                return "\(action.capitalized) calendar event: \(title)"
            }
            return "\(action.capitalized) a calendar event"
        case "reminders":
            let action = args["action"] as? String ?? "updated"
            if let title = args["title"] as? String {
                return "\(action.capitalized) reminder: \(title)"
            }
            return "\(action.capitalized) a reminder"
        case "contacts":
            let action = args["action"] as? String ?? "updated"
            return "\(action.capitalized) a contact"
        case "notes":
            let action = args["action"] as? String ?? "updated"
            if let title = args["title"] as? String {
                return "\(action.capitalized) note: \(title)"
            }
            return "\(action.capitalized) a note"
        case "mail":
            if let to = args["to"] as? String {
                return "Sent email to \(to)"
            }
            return "Sent an email"
        case "self_config":
            let op = args["operation"] as? String ?? "updated"
            if let key = args["key"] as? String {
                return "Config \(op): \(key)"
            }
            return "Updated a config setting"
        case "scheduler_create":
            return "Scheduled a task"
        case "scheduler_update":
            return "Updated a scheduled task"
        case "scheduler_delete":
            return "Deleted a scheduled task"
        case "manage_skill":
            let action = args["action"] as? String ?? "updated"
            if let name = args["name"] as? String {
                return "\(action.capitalized) skill: \(name)"
            }
            return "\(action.capitalized) a skill"
        case "plugin_manage":
            let action = args["action"] as? String ?? "updated"
            return "\(action.capitalized) a plugin"
        case "voice_identity":
            let action = args["action"] as? String ?? "updated"
            return "\(action.capitalized) voice identity"
        default:
            return receipt.toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortened = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let components = (shortened as NSString).pathComponents
        if components.count <= 3 {
            return shortened
        }
        let last = components.last ?? ""
        let parent = components[components.count - 2]
        return "…/\(parent)/\(last)"
    }

    // MARK: - Relative Time

    private func relativeTime(from timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) hr ago" }
        let days = seconds / 86400
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
