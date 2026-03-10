import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum CoworkPalette {
    static let ink = Color.black.opacity(0.12)
    static let panel = Color.primary.opacity(0.035)
    static let outline = Color.primary.opacity(0.075)
    static let heather = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)
    static let amber = Color(red: 204 / 255, green: 163 / 255, blue: 92 / 255)
    static let cyan = Color(red: 138 / 255, green: 154 / 255, blue: 181 / 255)
    static let rose = Color(red: 142 / 255, green: 108 / 255, blue: 128 / 255)
    static let mint = Color(red: 150 / 255, green: 172 / 255, blue: 160 / 255)
}

private enum ModelPickerTarget {
    case agentEditor
    case selectedConversationAgent
    case newWorkspaceAgent
}

private struct EditableSchedulerTaskDraft: Identifiable, Equatable {
    enum Mode: Equatable {
        case create
        case edit(existingID: String)
    }

    let id = UUID()
    let mode: Mode
    var name: String
    var description: String
    var body: String
    var scheduleType: String
    var intervalHours: String
    var dailyHour: String
    var dailyMinute: String
    var weeklyDay: String
    var weeklyHour: String
    var weeklyMinute: String
    var allowedTools: String

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var title: String {
        isEditing ? "Edit Task" : "New Task"
    }

    var actionTitle: String {
        isEditing ? "Save Changes" : "Create Task"
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
    var computedActionSummary: String {
        if !trimmedDescription.isEmpty { return trimmedDescription }
        if let firstLine = trimmedBody.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstLine.isEmpty
        {
            return firstLine
        }
        return trimmedName
    }

    static func new() -> EditableSchedulerTaskDraft {
        EditableSchedulerTaskDraft(
            mode: .create,
            name: "",
            description: "",
            body: "",
            scheduleType: "interval",
            intervalHours: "6",
            dailyHour: "9",
            dailyMinute: "0",
            weeklyDay: "monday",
            weeklyHour: "9",
            weeklyMinute: "0",
            allowedTools: "web_search,fetch_url"
        )
    }

    static func from(task: CoworkSchedulerTask) -> EditableSchedulerTaskDraft {
        EditableSchedulerTaskDraft(
            mode: .edit(existingID: task.id),
            name: task.name,
            description: task.taskDescription ?? task.action,
            body: task.instructionBody ?? task.action,
            scheduleType: task.scheduleType,
            intervalHours: task.scheduleParams["hours"] ?? "6",
            dailyHour: task.scheduleParams["hour"] ?? "9",
            dailyMinute: task.scheduleParams["minute"] ?? "0",
            weeklyDay: task.scheduleParams["day"] ?? "monday",
            weeklyHour: task.scheduleParams["hour"] ?? "9",
            weeklyMinute: task.scheduleParams["minute"] ?? "0",
            allowedTools: task.allowedTools.joined(separator: ",")
        )
    }
}

private struct CoworkModelOptionSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let options: [CoworkModelOption]
}

private struct CoworkCapabilityBadge: View {
    let capability: CoworkModelCapability

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(badgeColor)
            .help(helpText)
    }

    private var symbolName: String {
        switch capability {
        case .vision:    return "eye"
        case .toolUse:   return "wrench.and.screwdriver"
        case .reasoning: return "sparkles"
        }
    }

    private var badgeColor: Color {
        switch capability {
        case .vision:    return .blue
        case .toolUse:   return CoworkPalette.mint
        case .reasoning: return .purple
        }
    }

    private var helpText: String {
        switch capability {
        case .vision:    return "Supports image inputs"
        case .toolUse:   return "Supports tool / function calling"
        case .reasoning: return "Extended reasoning / chain-of-thought"
        }
    }
}

private struct WorkspaceSidebarCapsule: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(accent.opacity(0.16))
                    .overlay(Capsule().stroke(accent.opacity(0.28), lineWidth: 1))
            )
    }
}

private struct WorkspaceSidebarRow: View {
    let workspaceID: UUID
    let workspaceName: String
    let summary: String
    let isLocal: Bool
    let isSelected: Bool
    let depth: Int
    let childrenCount: Int
    let parentName: String?
    let hasFolder: Bool
    let attachmentCount: Int
    let compareAlwaysOn: Bool
    let isDragged: Bool
    let namespace: Namespace.ID

    private var metadataFragments: [String] {
        var fragments: [String] = [isLocal ? "On-device" : "Remote"]
        if !summary.isEmpty {
            fragments.append(summary)
        }
        if let parentName {
            fragments.append("Fork of \(parentName)")
        } else if childrenCount > 0 {
            fragments.append("\(childrenCount) fork\(childrenCount == 1 ? "" : "s")")
        }
        if hasFolder {
            fragments.append("Folder")
        }
        if attachmentCount > 0 {
            fragments.append("\(attachmentCount) file\(attachmentCount == 1 ? "" : "s")")
        }
        if compareAlwaysOn {
            fragments.append("Compare")
        }
        return fragments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if depth > 0 {
                    HStack(spacing: 4) {
                        ForEach(0 ..< depth, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 6, height: 1)
                        }
                    }
                    .frame(width: CGFloat(depth * 10), alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspaceName)
                        .font(.system(size: isSelected ? 13.5 : 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(metadataFragments.joined(separator: "  ·  "))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle((isLocal ? CoworkPalette.mint : CoworkPalette.cyan).opacity(0.78))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if isSelected {
                    WorkspaceSidebarCapsule(
                        text: isLocal ? "On-device" : "Remote",
                        accent: isLocal ? CoworkPalette.mint : CoworkPalette.cyan
                    )
                }
            }

        }
        .padding(.leading, 12 + CGFloat(depth * 8))
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05), lineWidth: 1)
                )
                .matchedGeometryEffect(id: "workspace-row-\(workspaceID.uuidString)", in: namespace)
        )
        .scaleEffect(isSelected ? 1.0 : 0.99)
        .opacity(isDragged ? 0.72 : 1)
    }
}

private struct WorkspaceSidebarButtonView: View {
    let workspace: WorkWithFaeWorkspaceRecord
    let summary: String
    let isLocal: Bool
    let isSelected: Bool
    let depth: Int
    let childrenCount: Int
    let parentName: String?
    let canDelete: Bool
    let namespace: Namespace.ID
    @Binding var draggedWorkspaceID: UUID?
    let onSelect: () -> Void
    let onFork: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMoveBefore: () -> Bool

    var body: some View {
        Button(action: onSelect) {
            WorkspaceSidebarRow(
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                summary: summary,
                isLocal: isLocal,
                isSelected: isSelected,
                depth: depth,
                childrenCount: childrenCount,
                parentName: parentName,
                hasFolder: workspace.state.selectedDirectoryPath != nil,
                attachmentCount: workspace.state.attachments.count,
                compareAlwaysOn: workspace.policy.compareBehavior == .alwaysCompare,
                isDragged: draggedWorkspaceID == workspace.id,
                namespace: namespace
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name)
        .accessibilityValue(summary)
        .accessibilityHint(isSelected ? "Current conversation." : "Open this conversation.")
        .contextMenu {
            Button("Fork conversation", action: onFork)
            Button("Rename conversation", action: onRename)
            Divider()
            Button("Delete conversation", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
        .onDrag {
            draggedWorkspaceID = workspace.id
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text.identifier], isTargeted: nil) { _ in
            onMoveBefore()
        }
    }
}

private struct CoworkSchedulerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: EditableSchedulerTaskDraft
    let onSave: (EditableSchedulerTaskDraft) -> Void

    private static let weeklyDays = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    init(draft: EditableSchedulerTaskDraft, onSave: @escaping (EditableSchedulerTaskDraft) -> Void) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("Task name")
                    .font(.headline)
                TextField("Nightly research sweep", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.headline)
                TextField("Short summary shown in the scheduler", text: $draft.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.headline)
                TextEditor(text: $draft.body)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Schedule")
                    .font(.headline)
                Picker("Schedule type", selection: $draft.scheduleType) {
                    Text("Every few hours").tag("interval")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                }
                .pickerStyle(.segmented)

                switch draft.scheduleType {
                case "daily":
                    HStack(spacing: 12) {
                        TextField("Hour", text: $draft.dailyHour)
                            .textFieldStyle(.roundedBorder)
                        TextField("Minute", text: $draft.dailyMinute)
                            .textFieldStyle(.roundedBorder)
                    }
                case "weekly":
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Day", selection: $draft.weeklyDay) {
                            ForEach(Self.weeklyDays, id: \.self) { day in
                                Text(day.capitalized).tag(day)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack(spacing: 12) {
                            TextField("Hour", text: $draft.weeklyHour)
                                .textFieldStyle(.roundedBorder)
                            TextField("Minute", text: $draft.weeklyMinute)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                default:
                    TextField("Interval hours", text: $draft.intervalHours)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Allowed tools (comma separated)")
                    .font(.headline)
                TextField("web_search,fetch_url", text: $draft.allowedTools)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(draft.actionTitle) {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var isValid: Bool {
        guard !draft.trimmedName.isEmpty, !draft.trimmedBody.isEmpty else { return false }

        switch draft.scheduleType {
        case "daily":
            return !draft.dailyHour.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draft.dailyMinute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "weekly":
            return !draft.weeklyDay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draft.weeklyHour.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draft.weeklyMinute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !draft.intervalHours.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private struct CoworkBrandOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let inset = min(size.width, size.height) * 0.1
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let orbPath = Path(ellipseIn: rect)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = min(rect.width, rect.height) * 0.5
                let motion = reduceMotion ? 0.22 : 1.0
                let phase = time * motion

                context.fill(
                    Path(ellipseIn: rect.insetBy(dx: -radius * 0.46, dy: -radius * 0.46)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 1.0, green: 0.48, blue: 0.12).opacity(0.22),
                            Color(red: 0.72, green: 0.25, blue: 0.04).opacity(0.1),
                            .clear,
                        ]),
                        center: center,
                        startRadius: radius * 0.08,
                        endRadius: radius * 1.5
                    )
                )

                context.fill(
                    orbPath,
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(red: 0.44, green: 0.18, blue: 0.03), location: 0.02),
                            .init(color: Color(red: 0.19, green: 0.06, blue: 0.01), location: 0.48),
                            .init(color: Color.black.opacity(0.98), location: 1),
                        ]),
                        center: CGPoint(x: center.x + radius * 0.18, y: center.y - radius * 0.22),
                        startRadius: radius * 0.08,
                        endRadius: radius * 1.1
                    )
                )

                context.stroke(
                    orbPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.22),
                            Color(red: 1.0, green: 0.71, blue: 0.34).opacity(0.16),
                            Color.black.opacity(0.28),
                        ]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                    ),
                    lineWidth: 1
                )

                var clipped = context
                clipped.clip(to: orbPath)

                drawRibbon(
                    in: &clipped,
                    rect: rect,
                    phase: phase * 0.85 + 0.4,
                    rotation: -.pi / 5,
                    thickness: 0.34,
                    brightness: 1.0
                )
                drawRibbon(
                    in: &clipped,
                    rect: rect,
                    phase: phase * 0.72 + 1.8,
                    rotation: .pi / 3.2,
                    thickness: 0.28,
                    brightness: 0.86
                )
                drawRibbon(
                    in: &clipped,
                    rect: rect,
                    phase: phase * 0.96 + 3.2,
                    rotation: .pi / 1.1,
                    thickness: 0.2,
                    brightness: 0.74
                )

                let sparkAngle = phase * 0.7 + .pi * 0.18
                let sparkCenter = CGPoint(
                    x: center.x + cos(sparkAngle) * radius * 0.28,
                    y: center.y + sin(sparkAngle * 1.22) * radius * 0.18
                )
                clipped.fill(
                    Path(ellipseIn: CGRect(x: sparkCenter.x - radius * 0.1, y: sparkCenter.y - radius * 0.1, width: radius * 0.2, height: radius * 0.2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.92),
                            Color(red: 1.0, green: 0.84, blue: 0.46).opacity(0.88),
                            Color(red: 1.0, green: 0.5, blue: 0.16).opacity(0.0),
                        ]),
                        center: sparkCenter,
                        startRadius: 0,
                        endRadius: radius * 0.18
                    )
                )

                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: radius * 0.04, dy: radius * 0.04)),
                    with: .color(Color.white.opacity(0.08)),
                    lineWidth: 0.8
                )
            }
        }
        .drawingGroup()
        .aspectRatio(1, contentMode: .fit)
        .background(
            Circle()
                .fill(Color.black.opacity(0.24))
        )
        .shadow(color: Color(red: 1.0, green: 0.45, blue: 0.08).opacity(0.28), radius: 18, y: 6)
        .accessibilityHidden(true)
    }

    private func drawRibbon(
        in context: inout GraphicsContext,
        rect: CGRect,
        phase: Double,
        rotation: Double,
        thickness: CGFloat,
        brightness: CGFloat
    ) {
        let path = ribbonPath(in: rect, phase: phase)

        var ribbonContext = context
        ribbonContext.blendMode = .screen
        ribbonContext.translateBy(x: rect.midX, y: rect.midY)
        ribbonContext.rotate(by: .radians(rotation + sin(phase * 0.45) * 0.18))
        ribbonContext.translateBy(x: -rect.midX, y: -rect.midY)

        let warmCore = Color(red: 1.0, green: 0.84, blue: 0.52).opacity(0.92 * brightness)
        let warmMid = Color(red: 1.0, green: 0.6, blue: 0.19).opacity(0.44 * brightness)
        let warmEdge = Color(red: 0.92, green: 0.28, blue: 0.06).opacity(0.16 * brightness)
        let lineWidth = rect.width * thickness

        ribbonContext.stroke(
            path,
            with: .color(warmEdge),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
        ribbonContext.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [warmMid.opacity(0.22), warmMid, warmCore.opacity(0.84), warmMid]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            ),
            style: StrokeStyle(lineWidth: lineWidth * 0.56, lineCap: .round, lineJoin: .round)
        )
        ribbonContext.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.08), warmCore, Color.white.opacity(0.14)]),
                startPoint: CGPoint(x: rect.minX, y: rect.midY),
                endPoint: CGPoint(x: rect.maxX, y: rect.midY)
            ),
            style: StrokeStyle(lineWidth: lineWidth * 0.18, lineCap: .round, lineJoin: .round)
        )
    }

    private func ribbonPath(in rect: CGRect, phase: Double) -> Path {
        let radius = min(rect.width, rect.height) * 0.5
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 96

        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)
        for step in 0 ... steps {
            let progress = Double(step) / Double(steps)
            let local = progress * 2 - 1
            let taper = max(0.12, 1 - pow(abs(local), 1.45))
            let horizontal = sin(progress * .pi * 2.15 + phase) * 0.55 + sin(progress * .pi * 6.2 - phase * 0.7) * 0.08
            let vertical = local + cos(progress * .pi * 2.8 + phase * 0.6) * 0.08

            points.append(
                CGPoint(
                    x: center.x + horizontal * radius * taper,
                    y: center.y + vertical * radius * 0.92
                )
            )
        }

        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1 ..< points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(x: (previous.x + current.x) * 0.5, y: (previous.y + current.y) * 0.5)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }
}

private struct CoworkComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder, measuredHeight: $measuredHeight, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.92)
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.delegate = context.coordinator
        textView.submitHandler = onSubmit
        textView.placeholderString = placeholder
        textView.string = text
        textView.setAccessibilityLabel("Conversation message")
        textView.setAccessibilityHelp("Type a message for this conversation. Press Return to send, or Shift-Return for a new line.")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.documentView = textView
        scrollView.setAccessibilityLabel("Conversation composer")
        scrollView.setAccessibilityHelp("Type a message for this conversation. Press Return to send, or Shift-Return for a new line.")

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(for: textView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SubmitTextView else { return }
        textView.submitHandler = onSubmit
        textView.placeholderString = placeholder
        if textView.string != text {
            textView.string = text
        }
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(for: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let placeholder: String
        @Binding private var measuredHeight: CGFloat
        let onSubmit: () -> Void

        init(text: Binding<String>, placeholder: String, measuredHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            _text = text
            self.placeholder = placeholder
            _measuredHeight = measuredHeight
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SubmitTextView else { return }
            text = textView.string
            recalculateHeight(for: textView)
        }

        func recalculateHeight(for textView: NSTextView) {
            let fittingHeight = min(max(textView.intrinsicContentSize.height + 4, 52), 144)
            if abs(measuredHeight - fittingHeight) > 1 {
                measuredHeight = fittingHeight
            }
        }
    }
}

private final class SubmitTextView: NSTextView {
    var submitHandler: (() -> Void)?
    var placeholderString: String = ""

    override var intrinsicContentSize: NSSize {
        let width = textContainer?.containerSize.width ?? bounds.width
        guard width > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 52) }
        layoutManager?.ensureLayout(for: textContainer!)
        let used = layoutManager?.usedRect(for: textContainer!).height ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: used + textContainerInset.height * 2 + 8)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                super.insertNewline(nil)
            } else {
                submitHandler?()
            }
            return
        }
        super.keyDown(with: event)
    }
}

struct CoworkWorkspaceView: View {
    @ObservedObject var controller: CoworkWorkspaceController
    @ObservedObject var faeCore: FaeCore
    @ObservedObject var conversation: ConversationController

    @State private var isDropTargeted = false
    @State private var showingAddWorkspaceSheet = false
    @State private var showingRenameWorkspaceSheet = false
    @State private var showingAddAgentSheet = false
    @State private var showingDeleteAgentAlert = false
    @State private var showingDeleteWorkspaceAlert = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceAgentID = WorkWithFaeAgentProfile.faeLocal.id
    @State private var newWorkspaceModel = ""
    @State private var newWorkspaceDirectoryURL: URL?
    @State private var renameWorkspaceName = ""
    @State private var draggedWorkspaceID: UUID?
    @State private var editingAgentID: String?
    @State private var newAgentName = ""
    @State private var newAgentBackendPresetID = "openai"
    @State private var newAgentProvider: CoworkLLMProviderKind = .openAICompatibleExternal
    @State private var newAgentModel = ""
    @State private var newAgentBaseURL = ""
    @State private var newAgentAPIKey = ""
    @State private var clearStoredAPIKey = false
    @State private var assignNewAgentToWorkspace = true
    @State private var isTestingAgentConnection = false
    @State private var agentTestStatus: String?
    @State private var agentConnectionOK: Bool? = nil   // nil=untested, true=ok, false=failed
    @State private var discoveredModels: [String] = []
    @State private var agentModelSearchText = ""
    @State private var apiKeyTestTask: Task<Void, Never>?
    @State private var showingModelPickerSheet = false
    @State private var modelPickerTarget: ModelPickerTarget = .agentEditor
    @State private var modelSearchText = ""
    @State private var browsableModelOptions: [CoworkModelOption] = []
    @State private var isLoadingModelPickerOptions = false
    @State private var composerHeight: CGFloat = 64
    @State private var showConsensusDetails = false
    @State private var showWorkspacePolicies = false
    @State private var showDetailsRail = false
    @State private var showCompareUnavailablePopover = false
    @State private var presentedUtilitySection: CoworkWorkspaceSection?
    @State private var schedulerEditorDraft: EditableSchedulerTaskDraft?
    @State private var pendingTaskDeletion: CoworkSchedulerTask?
    @State private var skillEditorDraft: EditableSkillDraft?
    @State private var pendingSkillDeletionName: String?
    @State private var showContextFolderSection = true
    @State private var showContextAttachmentsSection = false
    @State private var showContextIndexedFilesSection = false
    @State private var showContextPreviewSection = true
    @Namespace private var workspaceSelectionAnimation

    var body: some View {
        presentedWorkspaceRoot
    }

    private var presentedWorkspaceRoot: some View {
        interactiveWorkspaceRoot
            .sheet(isPresented: $showingAddWorkspaceSheet) {
                workspaceCreationSheet
            }
            .sheet(isPresented: $showingRenameWorkspaceSheet) {
                workspaceRenameSheet
            }
            .sheet(isPresented: $showingAddAgentSheet) {
                agentCreationSheet
            }
            .sheet(isPresented: $showingModelPickerSheet) {
                modelPickerSheet
            }
            .sheet(item: $presentedUtilitySection) { section in
                utilitySheet(for: section)
            }
            .sheet(item: $schedulerEditorDraft) { draft in
                schedulerEditorSheet(draft: draft)
            }
            .sheet(item: $skillEditorDraft) { draft in
                SkillEditorSheet(draft: draft) { savedDraft in
                    persistSkillDraft(savedDraft)
                }
            }
            .alert("Delete task?", isPresented: taskDeletionBinding, presenting: pendingTaskDeletion) { task in
                Button("Delete", role: .destructive) {
                    controller.deleteTask(task)
                    pendingTaskDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingTaskDeletion = nil
                }
            } message: { task in
                Text("Delete \(task.name)? This scheduled task will stop running.")
            }
            .alert("Delete skill?", isPresented: skillDeletionBinding, presenting: pendingSkillDeletionName) { name in
                Button("Delete", role: .destructive) {
                    controller.deleteSkill(name: name)
                    pendingSkillDeletionName = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingSkillDeletionName = nil
                }
            } message: { name in
                Text("Delete \(name)? This removes the skill from Fae.")
            }
            .alert("Remove agent?", isPresented: $showingDeleteAgentAlert, presenting: controller.selectedAgent) { agent in
                Button("Remove", role: .destructive) {
                    controller.deleteAgent(agent)
                }
                Button("Cancel", role: .cancel) {}
            } message: { agent in
                Text("Remove \(agent.name)? Any workspaces using it will fall back to Fae Local.")
            }
            .alert("Delete conversation?", isPresented: $showingDeleteWorkspaceAlert, presenting: controller.selectedWorkspace) { workspace in
                Button("Delete", role: .destructive) {
                    controller.deleteSelectedWorkspace()
                }
                Button("Cancel", role: .cancel) {}
            } message: { workspace in
                Text("Delete \(workspace.name)? Its folder, attachments, and compare settings will be removed from Work with Fae.")
            }
    }

    private var interactiveWorkspaceRoot: some View {
        workspaceRoot
            .onAppear {
                controller.scheduleRefresh(after: 0.05)
            }
            .onChange(of: controller.latestConsensusResults.count) {
                showConsensusDetails = false
            }
            .onChange(of: controller.workspaces.map(\.id)) {
                draggedWorkspaceID = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .faeCoworkToggleInspectorRequested)) { _ in
                showDetailsRail.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .faeCoworkOpenModelPickerRequested)) { _ in
                guard controller.selectedAgent != nil else { return }
                openModelPickerForSelectedAgent()
            }
            .onReceive(NotificationCenter.default.publisher(for: .faeCoworkOpenUtilityRequested)) { notification in
                guard let rawValue = notification.userInfo?["section"] as? String,
                      let section = CoworkWorkspaceSection(rawValue: rawValue)
                else { return }
                presentedUtilitySection = section
            }
            .onReceive(NotificationCenter.default.publisher(for: .faeCoworkNewTaskRequested)) { _ in
                presentSchedulerEditor(.new())
            }
            .onReceive(NotificationCenter.default.publisher(for: .faeCoworkNewSkillRequested)) { _ in
                presentSkillEditor(.new())
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: controller.selectedWorkspace?.id)
            .animation(.easeInOut(duration: 0.22), value: showDetailsRail)
            .animation(.easeInOut(duration: 0.22), value: showWorkspacePolicies)
            .animation(.easeInOut(duration: 0.22), value: showConsensusDetails)
    }

    private var workspaceRoot: some View {
        ZStack {
            backdrop

            HStack(spacing: 16) {
                sidebar
                    .frame(width: 236)

                VStack(spacing: 14) {
                    header
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
        }
        .background(
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                .ignoresSafeArea()
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(CoworkPalette.heather.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                    .padding(18)
                    .overlay {
                        Text("Drop files or images to add them to Work with Fae")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            WorkWithFaeWorkspaceStore.dropURLs(from: providers) { urls in
                controller.addAttachments(from: urls)
            }
            return true
        }
    }

    private var backdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .padding(10)
                .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.heather.opacity(0.10), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.amber.opacity(0.07), .clear],
                center: .topLeading,
                startRadius: 24,
                endRadius: 280
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var header: some View {
        workspaceHeader
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(controller.selectedWorkspace?.name ?? "Conversation")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if controller.isStrictLocalWorkspace {
                        capsule(text: "Local only", accent: CoworkPalette.mint)
                    }
                }

                Text(workspaceHeaderCaption)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.62))
                    .lineLimit(2)

                if let workspaceHeaderMetaLine, !workspaceHeaderMetaLine.isEmpty {
                    Text(workspaceHeaderMetaLine)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.46))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if controller.selectedAgent != nil {
                        modelPickerPill
                        thinkingLevelPill
                    }
                    detailsRailToggleButton(labelStyle: .titleAndIcon)
                    workspaceOverflowMenu
                }

                HStack(spacing: 8) {
                    if controller.selectedAgent != nil {
                        modelPickerCompactPill
                        thinkingLevelCompactPill
                    }
                    detailsRailToggleButton(labelStyle: .iconOnly)
                    workspaceOverflowMenu
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        workspaceSection
    }

    private var workspaceSection: some View {
        HStack(alignment: .top, spacing: 12) {
            workspaceConversationPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showDetailsRail {
                workspaceContextPanel
                    .frame(width: 228)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceContextPanel: some View {
        glassCard {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Context")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(detailsRailCaption)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.54))
                    }

                    DisclosureGroup(isExpanded: $showWorkspacePolicies) {
                        VStack(alignment: .leading, spacing: 10) {
                            policyMenuRow(
                                title: "Remote execution",
                                value: controller.selectedWorkspacePolicy.remoteExecution.displayName,
                                icon: controller.selectedWorkspacePolicy.remoteExecution == .strictLocalOnly ? "lock.shield.fill" : "network"
                            ) {
                                ForEach(WorkWithFaeRemoteExecutionPolicy.allCases) { policy in
                                    Button(policy.displayName) {
                                        controller.updateWorkspaceRemoteExecution(policy)
                                    }
                                }
                            }

                            policyMenuRow(
                                title: "Compare behavior",
                                value: controller.selectedWorkspacePolicy.compareBehavior.displayName,
                                icon: controller.selectedWorkspacePolicy.compareBehavior == .alwaysCompare ? "square.stack.3d.up.fill" : "paperplane"
                            ) {
                                ForEach(WorkWithFaeCompareBehavior.allCases) { policy in
                                    Button(policy.displayName) {
                                        controller.updateWorkspaceCompareBehavior(policy)
                                    }
                                }
                            }

                            policyMenuRow(
                                title: "Consensus participants",
                                value: controller.usesAutomaticConsensusSelection ? "Automatic" : "Custom selection",
                                icon: controller.usesAutomaticConsensusSelection ? "wand.and.stars" : "person.3.fill"
                            ) {
                                Button {
                                    controller.resetConsensusParticipantsToAutomatic()
                                } label: {
                                    Label("Automatic selection", systemImage: controller.usesAutomaticConsensusSelection ? "checkmark" : "wand.and.stars")
                                }

                                Divider()

                                ForEach(controller.agents) { agent in
                                    Button {
                                        controller.toggleConsensusParticipant(agent)
                                    } label: {
                                        Label(
                                            agent.name,
                                            systemImage: controller.isConsensusParticipantSelected(agent) ? "checkmark.circle.fill" : "circle"
                                        )
                                    }
                                    .disabled(controller.isStrictLocalWorkspace && !agent.isTrustedLocal)
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        contextSectionLabel(title: "Workspace rules", subtitle: controller.selectedWorkspacePolicy.compareBehavior.displayName)
                    }
                    .tint(.primary)

                    DisclosureGroup(isExpanded: $showContextFolderSection) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let path = controller.workspaceState.selectedDirectoryPath {
                                let directoryURL = URL(fileURLWithPath: path)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(directoryURL.lastPathComponent)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Text("Connected locally and used for grounded file lookups.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.52))

                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
                                    } label: {
                                        Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(
                                                Capsule()
                                                    .fill(Color.primary.opacity(0.05))
                                                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Text("Choose a folder to let Fae ground answers in local files.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.55))
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        contextSectionLabel(title: "Folder & grounding", subtitle: controller.workspaceState.selectedDirectoryPath == nil ? "Not connected" : "Connected")
                    }
                    .tint(.primary)

                    DisclosureGroup(isExpanded: $showContextAttachmentsSection) {
                        VStack(alignment: .leading, spacing: 8) {
                            if controller.workspaceState.attachments.isEmpty {
                                Text("Add files, pasted text, or screenshots when you want more focused context.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.55))
                            } else {
                                ForEach(controller.workspaceState.attachments.prefix(8)) { attachment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: attachment.kind == .image ? "photo" : (attachment.kind == .text ? "doc.text" : "paperclip"))
                                            .foregroundStyle(CoworkPalette.heather)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(attachment.displayName)
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                            Text(attachmentMetadataLabel(for: attachment))
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundStyle(.primary.opacity(0.42))
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(controller.selectedAttachment?.id == attachment.id ? CoworkPalette.heather.opacity(0.14) : Color.primary.opacity(0.03))
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture {
                                        controller.selectAttachment(attachment)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        contextSectionLabel(title: "Attachments", subtitle: controller.workspaceState.attachments.isEmpty ? "Nothing attached" : "\(controller.workspaceState.attachments.count) attached")
                    }
                    .tint(.primary)

                    DisclosureGroup(isExpanded: $showContextIndexedFilesSection) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Search files by name or type", text: $controller.workspaceSearchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                                        )
                                )

                            if controller.workspaceState.indexedFiles.isEmpty {
                                Text("No indexed files yet.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.55))
                            } else {
                                ForEach(controller.filteredWorkspaceFiles.prefix(20)) { file in
                                    Button {
                                        controller.selectWorkspaceFile(file)
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: file.kind == "image" ? "photo" : "doc")
                                                .foregroundStyle(CoworkPalette.amber)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.relativePath)
                                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(2)
                                                Text(file.kind.capitalized)
                                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                                    .foregroundStyle(.primary.opacity(0.42))
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(controller.selectedWorkspaceFile?.id == file.id ? CoworkPalette.heather.opacity(0.14) : Color.clear)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        contextSectionLabel(title: "Indexed files", subtitle: controller.workspaceState.indexedFiles.isEmpty ? "No files indexed" : "\(controller.filteredWorkspaceFiles.count)/\(controller.workspaceState.indexedFiles.count) visible")
                    }
                    .tint(.primary)

                    if let focusedPreview = controller.focusedPreview {
                        DisclosureGroup(isExpanded: $showContextPreviewSection) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(focusedPreview.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)

                                if focusedPreview.kind == "image", let path = focusedPreview.path,
                                   let image = NSImage(contentsOf: URL(fileURLWithPath: path))
                                {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                } else if let textPreview = focusedPreview.textPreview, !textPreview.isEmpty {
                                    Text(textPreview)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.74))
                                        .lineLimit(10)
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color.primary.opacity(0.04))
                                        )
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            contextSectionLabel(title: "Focused preview", subtitle: focusedPreview.subtitle ?? focusedPreview.kind.capitalized)
                        }
                        .tint(.primary)
                    }
                }
            }
        }
    }

    private var workspaceConversationPanel: some View {
        primaryConversationSurface {
            VStack(alignment: .leading, spacing: 18) {
                if conversation.isGenerating || !controller.latestConsensusResults.isEmpty {
                    HStack {
                        if conversation.isGenerating
                            && !conversation.isStreaming
                            && !conversation.streamingThinkText.isEmpty
                        {
                            ThinkingCrawlView(text: conversation.streamingThinkText)
                                .transition(.opacity)
                        } else if conversation.isGenerating && conversation.isStreaming {
                            Label("Replying live", systemImage: "waveform.badge.mic")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(CoworkPalette.cyan.opacity(0.14)))
                                .overlay(Capsule().stroke(CoworkPalette.cyan.opacity(0.26), lineWidth: 1))
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        Spacer()
                    }
                    .animation(.easeInOut(duration: 0.2), value: conversation.streamingThinkText.isEmpty)
                }

                if !controller.latestConsensusResults.isEmpty {
                    consensusSummaryStrip
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if conversation.messages.isEmpty && conversation.streamingText.isEmpty {
                                emptyConversationState
                            } else {
                                ForEach(Array(conversation.messages.suffix(40).enumerated()), id: \.element.id) { offset, message in
                                    let absoluteIndex = max(0, conversation.messages.count - 40) + offset
                                    conversationBubble(message)
                                        .transition(.move(edge: message.role == .assistant ? .leading : .trailing).combined(with: .opacity))
                                        .contextMenu {
                                            Button {
                                                controller.forkWorkspace(upToMessageIndex: absoluteIndex)
                                            } label: {
                                                Label("Fork from here", systemImage: "arrow.branch")
                                            }
                                        }
                                }

                                // Completed think trace — brain icon after reasoning finishes
                                if let trace = conversation.completedThinkTrace,
                                   !conversation.isGenerating
                                {
                                    ThinkIconBubble(thinkTrace: trace)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id("cowork-think-icon")
                                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                }

                                if conversation.isStreaming, !conversation.streamingText.isEmpty {
                                    streamingBubble(conversation.streamingText)
                                        .transition(.move(edge: .leading).combined(with: .opacity))
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("cowork-bottom")
                            }
                        }
                        .padding(.trailing, 10)
                        .padding(.vertical, 12)
                    }
                    .onAppear {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                    .onChange(of: conversation.messages.count) {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                    .onChange(of: conversation.messages.last?.id) {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                    .onChange(of: controller.selectedWorkspace?.id) {
                        DispatchQueue.main.async {
                            proxy.scrollTo("cowork-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: conversation.streamingText) {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let blocked = controller.blockedRemoteEgressRequest {
                        blockedRemoteEgressCard(blocked)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                if controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Ask Fae to work with this folder, these files, or what you want her to inspect…")
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.34))
                                        .padding(.top, 11)
                                        .padding(.leading, 2)
                                }

                                CoworkComposerTextView(
                                    text: $controller.draft,
                                    placeholder: "Ask Fae to work with this folder, these files, or what you want her to inspect…",
                                    measuredHeight: $composerHeight,
                                    onSubmit: controller.submitDraft
                                )
                                .frame(minHeight: max(52, composerHeight), maxHeight: 144)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Conversation composer")
                            .accessibilityHint("Type a message, then press Return to send. Use Shift-Return for a new line.")

                            HStack(alignment: .center, spacing: 8) {
                                voiceCaptureButton
                                replayLatestReplyButton
                                contextActionMenu

                                thinkingLevelCompactPill

                                Button {
                                    controller.chooseWorkspaceDirectory()
                                } label: {
                                    conversationControlPill(icon: "folder", title: controller.workspaceState.selectedDirectoryPath == nil ? "Add folder" : "Folder")
                                }
                                .buttonStyle(.plain)

                                if let focusedTitle = controller.focusedPreview?.title {
                                    conversationControlPill(icon: "scope", title: focusedTitle)
                                }

                                Spacer()

                                Text(conversation.isGenerating ? (conversation.isStreaming ? "Replying live" : "Thinking") : "Ready")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.48))
                                    .contentTransition(.interpolate)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                                )
                        )

                        HStack(alignment: .center, spacing: 10) {
                            if controller.selectedWorkspacePolicy.compareBehavior == .alwaysCompare {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CoworkPalette.amber.opacity(0.92))
                                    Text(controller.canCompareAcrossAgents
                                         ? "Auto compare on send for \(controller.consensusParticipants.count) agents"
                                         : "Auto compare is on, but only one agent is available")
                                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.58))
                                        .lineLimit(2)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(controller.canCompareAcrossAgents
                                                    ? "Auto compare on send for \(controller.consensusParticipants.count) agents"
                                                    : "Auto compare on, but only one agent is available")
                            } else {
                                Button(action: {
                                    if controller.canCompareAcrossAgents {
                                        controller.compareDraftAcrossAgents()
                                    } else {
                                        showCompareUnavailablePopover = true
                                    }
                                }) {
                                    HStack(spacing: 7) {
                                        Image(systemName: "square.stack.3d.up.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("Compare \(controller.consensusParticipants.count)")
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    }
                                    .foregroundStyle(.primary.opacity(controller.canCompareAcrossAgents ? 0.84 : 0.42))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(Color.primary.opacity(0.05))
                                            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                                    )
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showCompareUnavailablePopover) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label("Comparison needs 2+ agents", systemImage: "square.stack.3d.up.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text("Add a second agent to this workspace to compare responses side by side.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Button("Add Agent") {
                                            showCompareUnavailablePopover = false
                                            showingAddAgentSheet = true
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(16)
                                    .frame(width: 260)
                                }
                                .help(controller.isStrictLocalWorkspace ? "This workspace is strict local only, so comparison stays disabled." : "Ask multiple agents to answer this draft and let Fae summarize the results.")
                                .accessibilityLabel("Compare models")
                                .accessibilityValue("\(controller.consensusParticipants.count) agents")
                                .accessibilityHint("Ask multiple agents to answer this draft.")
                            }

                            Spacer(minLength: 8)

                            Button(action: controller.submitDraft) {
                                Label(controller.shouldCompareOnSubmit ? "Compare & Send" : "Send", systemImage: "paperplane.fill")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [CoworkPalette.heather, CoworkPalette.amber],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Send message")
                            .accessibilityHint("Send the draft in this conversation.")
                        }
                    }
                }
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyConversationState: some View {
        let setupState = controller.selectedWorkspaceSetupState

        return VStack(alignment: .center, spacing: 14) {
            Text(setupState.isFreshWorkspace ? "Start working in this conversation." : "Pick up where you left off.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(setupState.isFreshWorkspace
                 ? "Choose a folder or add a few files, then ask Fae what you need."
                 : "This thread keeps its own model, context, and branch history.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.62))
                .multilineTextAlignment(.center)

            compactWorkspaceSetupStrip
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    private var schedulerSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scheduler board")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Live view across Fae's persistent automations and built-ins.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.62))
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        workspaceActionButton(
                            title: "New task",
                            systemImage: "plus",
                            accent: CoworkPalette.mint,
                            action: { presentSchedulerEditor(.new()) }
                        )
                        workspaceActionButton(
                            title: "Run skill health",
                            systemImage: "stethoscope",
                            accent: CoworkPalette.cyan,
                            action: { controller.runTask(id: "skill_health_check") }
                        )
                    }
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(controller.schedulerTasks) { task in
                            schedulerTaskCard(task)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private var skillsSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skills surface")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Installed and active Fae skills, ready for cowork use.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.62))
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Text("\(snapshot.skills.count) skills")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.70))
                        workspaceActionButton(
                            title: "New skill",
                            systemImage: "plus",
                            accent: CoworkPalette.mint,
                            action: { presentSkillEditor(.new()) }
                        )
                    }
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(snapshot.skills) { skill in
                            glassCard(padding: 16) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(skill.id)
                                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        capsule(text: skill.isActive ? "Active" : "Installed", accent: skill.isActive ? CoworkPalette.mint : CoworkPalette.cyan)
                                    }

                                    Text(skill.description)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.68))
                                        .lineLimit(4)

                                    HStack(spacing: 8) {
                                        capsule(text: skill.type.capitalized, accent: CoworkPalette.amber)
                                        capsule(text: skill.tier.capitalized, accent: CoworkPalette.rose)
                                        if !skill.isEnabled {
                                            capsule(text: "Disabled", accent: .gray)
                                        }
                                    }

                                    if skill.tier.lowercased() != "builtin" {
                                        HStack(spacing: 10) {
                                            Button("Edit") {
                                                guard let draft = EditableSkillDraft.loadPersonalSkill(named: skill.id) else { return }
                                                presentSkillEditor(draft)
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule()
                                                    .fill(Color.primary.opacity(0.05))
                                                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                                            )

                                            Button("Remove") {
                                                pendingSkillDeletionName = skill.id
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(CoworkPalette.rose)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private var toolsSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tool deck")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Filtered to the current tool mode so the cowork surface matches Fae's runtime permissions.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.62))
                    }
                    Spacer()
                    Text(snapshot.toolMode.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.70))
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(snapshot.tools) { tool in
                            glassCard(padding: 16) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(tool.displayName)
                                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        capsule(text: tool.riskLevel.capitalized, accent: riskAccent(tool.riskLevel))
                                    }

                                    Text(tool.description)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.68))
                                        .lineLimit(4)

                                    capsule(text: tool.category, accent: CoworkPalette.cyan)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private var sidebar: some View {
        glassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 14) {
                sidebarHeader

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.workspaces) { workspace in
                            workspaceButton(for: workspace)
                        }

                        if draggedWorkspaceID != nil {
                            workspaceDropTail
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var compactWorkspaceSetupStrip: some View {
        let setupState = controller.selectedWorkspaceSetupState

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(setupState.nextStep?.title ?? "Workspace ready")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(setupState.nextStep?.detail ?? "Grounded context is ready.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.52))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if controller.workspaceState.selectedDirectoryPath == nil {
                quickActionPill(title: "Choose folder", accent: CoworkPalette.heather) {
                    controller.chooseWorkspaceDirectory()
                }
            }
            if controller.workspaceState.attachments.isEmpty {
                quickActionPill(title: "Add files", accent: CoworkPalette.cyan) {
                    controller.addAttachmentsViaPicker()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var workspaceDropTail: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .frame(height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CoworkPalette.heather.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                    .overlay {
                        Text("Drop to move to the end")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.6))
                    }
            }
            .onDrop(of: [UTType.text.identifier], isTargeted: nil) { _ in
                guard let draggedWorkspaceID,
                      let workspace = controller.workspaces.first(where: { $0.id == draggedWorkspaceID })
                else {
                    return false
                }
                controller.moveWorkspace(workspace, before: nil)
                self.draggedWorkspaceID = nil
                return true
            }
    }

    private func workspaceButton(for workspace: WorkWithFaeWorkspaceRecord) -> some View {
        let isSelected = controller.selectedWorkspace?.id == workspace.id
        let agent = controller.agents.first(where: { $0.id == workspace.agentID })
        let depth = controller.forkDepth(for: workspace)
        let childrenCount = controller.forkChildrenCount(for: workspace)
        let parentName = controller.parentWorkspace(for: workspace)?.name
        let summary = agentSummary(for: agent)
        return WorkspaceSidebarButtonView(
            workspace: workspace,
            summary: summary,
            isLocal: agent?.isTrustedLocal == true,
            isSelected: isSelected,
            depth: depth,
            childrenCount: childrenCount,
            parentName: parentName,
            canDelete: controller.workspaces.count > 1,
            namespace: workspaceSelectionAnimation,
            draggedWorkspaceID: $draggedWorkspaceID,
            onSelect: {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    controller.selectWorkspace(workspace)
                }
            },
            onFork: {
                controller.selectWorkspace(workspace)
                controller.forkSelectedWorkspace()
            },
            onRename: {
                controller.selectWorkspace(workspace)
                renameWorkspaceName = workspace.name
                showingRenameWorkspaceSheet = true
            },
            onDelete: {
                controller.selectWorkspace(workspace)
                showingDeleteWorkspaceAlert = true
            },
            onMoveBefore: {
                guard let draggedWorkspaceID,
                      draggedWorkspaceID != workspace.id,
                      let draggedWorkspace = controller.workspaces.first(where: { $0.id == draggedWorkspaceID })
                else {
                    return false
                }
                controller.moveWorkspace(draggedWorkspace, before: workspace)
                self.draggedWorkspaceID = nil
                return true
            }
        )
    }

    private func sidebarButton(for section: CoworkWorkspaceSection) -> some View {
        let isSelected = controller.selectedSection == section
        let count = sidebarCount(for: section)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                controller.selectedSection = section
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.72))

                Text(section.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.primary.opacity(0.72))

                Spacer()

                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.primary.opacity(0.56))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
            .scaleEffect(isSelected ? 1.0 : 0.985)
        }
        .buttonStyle(.plain)
    }

    private var workspaceCreationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New conversation")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Text("Every conversation can use a different model, folder, and context set.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            TextField("Conversation name", text: $newWorkspaceName)
                .textFieldStyle(.roundedBorder)

            Picker("Agent", selection: $newWorkspaceAgentID) {
                ForEach(controller.agents) { agent in
                    Text(agent.name).tag(agent.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: newWorkspaceAgentID) {
                syncNewWorkspaceModelSelection()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Selected backend")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(newWorkspaceBackendSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                if let agent = newWorkspaceSelectedAgent {
                    HStack(spacing: 8) {
                        Text(newWorkspaceModelDisplayValue)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(newWorkspaceModelDisplayValue == "No model selected" ? Color.primary.opacity(0.55) : Color.primary.opacity(0.82))
                            .lineLimit(1)

                        Spacer()

                        if agent.providerKind != .faeLocalhost {
                            Button("Choose") {
                                openModelPickerForNewWorkspaceAgent()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    Text(newWorkspaceDirectoryURL?.path ?? "No folder selected")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.72))
                        .lineLimit(2)

                    Spacer()

                    Button("Choose") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Use Folder"
                        panel.title = "Choose a conversation folder"
                        if panel.runModal() == .OK {
                            newWorkspaceDirectoryURL = panel.url
                        }
                    }

                    if newWorkspaceDirectoryURL != nil {
                        Button("Clear") {
                            newWorkspaceDirectoryURL = nil
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showingAddWorkspaceSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    controller.createWorkspace(
                        named: newWorkspaceName,
                        agentID: newWorkspaceAgentID,
                        modelIdentifier: newWorkspaceModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        directoryURL: newWorkspaceDirectoryURL
                    )
                    showingAddWorkspaceSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var workspaceRenameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename conversation")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            TextField("Conversation name", text: $renameWorkspaceName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    showingRenameWorkspaceSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.renameSelectedWorkspace(to: renameWorkspaceName)
                    showingRenameWorkspaceSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var modelPickerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(modelPickerTarget == .selectedConversationAgent ? "Choose conversation model" : "Choose model")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(modelPickerTarget == .selectedConversationAgent
                 ? "Switch between local and remote models without losing the conversation. Model names stay primary; provider details are secondary."
                 : "Pick the model this agent should use.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search models", text: $modelSearchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search available models")

            if isLoadingModelPickerOptions {
                ProgressView("Loading models…")
                    .tint(.primary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredModelOptionSections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.primary)
                                Text(section.subtitle)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.44))
                            }

                            ForEach(section.options) { option in
                                Button {
                                    switch modelPickerTarget {
                                    case .agentEditor:
                                        newAgentModel = option.modelIdentifier
                                    case .selectedConversationAgent:
                                        controller.applyConversationModelSelection(option)
                                    case .newWorkspaceAgent:
                                        newWorkspaceModel = option.modelIdentifier
                                    }
                                    showingModelPickerSheet = false
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 5) {
                                                Text(option.displayTitle)
                                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                if let ctxLabel = option.contextWindowLabel {
                                                    Text(ctxLabel)
                                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                                        .foregroundStyle(.primary.opacity(0.48))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                                                }
                                                let sortedCaps = Array(option.capabilities).sorted { $0.rawValue < $1.rawValue }
                                                ForEach(sortedCaps, id: \.self) { cap in
                                                    CoworkCapabilityBadge(capability: cap)
                                                }
                                            }
                                            Text(option.displaySubtitle)
                                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(.primary.opacity(0.52))
                                                .lineLimit(1)
                                            Text(option.modelIdentifier)
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.primary.opacity(0.32))
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 6) {
                                            if selectedModelOptionID == option.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(CoworkPalette.mint)
                                            }
                                            if !option.isConfigured {
                                                Text("Needs key")
                                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                                    .foregroundStyle(CoworkPalette.amber)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(option.accessibilityLabel)
                                .accessibilityHint(option.isConfigured ? "Use this model for the active conversation." : "Select this model, then add an API key before sending.")
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingModelPickerSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Done choosing model")
                .accessibilityHint("Close the model picker.")
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
    }

    private var agentCreationSheet: some View {
        let preset = selectedBackendPreset
        let editingAgent = editingAgent
        let inlineModels = agentInlineModelOptions
        return VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text(editingAgent == nil ? "Add agent" : "Edit agent")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Configure a provider and model, then save.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            // ── Name ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("Agent name", text: $newAgentName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.bottom, 18)

            // ── Provider tabs ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(controller.backendPresets, id: \.id) { backend in
                            let isSelected = newAgentBackendPresetID == backend.id
                            Button {
                                newAgentBackendPresetID = backend.id
                                let updatedPreset = CoworkBackendPresetCatalog.preset(id: backend.id) ?? backend
                                newAgentProvider = updatedPreset.providerKind
                                newAgentBaseURL = updatedPreset.defaultBaseURL
                                if newAgentModel.isEmpty || presetSuggestedModels.contains(newAgentModel) {
                                    newAgentModel = updatedPreset.suggestedModels.first
                                        ?? (updatedPreset.providerKind == .faeLocalhost ? "fae-agent-local" : "")
                                }
                                if !updatedPreset.requiresAPIKey {
                                    newAgentAPIKey = ""
                                    clearStoredAPIKey = false
                                }
                                discoveredModels = []
                                agentTestStatus = nil
                                agentConnectionOK = nil
                                agentModelSearchText = ""
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: providerSystemImage(for: backend.id))
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(backend.displayName)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.72))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? CoworkPalette.mint : Color.primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 18)

            // ── API key (if needed) ─────────────────────────────────────────
            if preset.requiresAPIKey {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(preset.id == "openrouter" ? "OpenRouter API key" : "API key")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isTestingAgentConnection {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                            Text("Checking…")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else if let ok = agentConnectionOK {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(ok ? CoworkPalette.mint : Color.red.opacity(0.8))
                            Text(ok ? "Connected" : "Failed")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(ok ? CoworkPalette.mint : Color.red.opacity(0.8))
                        }
                    }
                    SecureField(
                        editingAgent == nil ? preset.apiKeyPlaceholder : "New key (blank = keep current)",
                        text: $newAgentAPIKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: newAgentAPIKey) {
                        agentConnectionOK = nil
                        agentTestStatus = nil
                        apiKeyTestTask?.cancel()
                        let keyNow = newAgentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !keyNow.isEmpty else { return }
                        apiKeyTestTask = Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            guard !Task.isCancelled else { return }
                            await MainActor.run { isTestingAgentConnection = true }
                            do {
                                let report = try await controller.testConnection(
                                    providerKind: preset.providerKind,
                                    baseURL: newAgentBaseURL,
                                    apiKey: keyNow
                                )
                                await MainActor.run {
                                    isTestingAgentConnection = false
                                    agentConnectionOK = report.isReachable
                                    agentTestStatus = report.statusText
                                    if !report.discoveredModels.isEmpty {
                                        discoveredModels = report.discoveredModels
                                        if newAgentModel.isEmpty || presetSuggestedModels.contains(newAgentModel) {
                                            newAgentModel = report.discoveredModels.first ?? newAgentModel
                                        }
                                    }
                                }
                            } catch {
                                await MainActor.run {
                                    isTestingAgentConnection = false
                                    agentConnectionOK = false
                                    agentTestStatus = error.localizedDescription
                                }
                            }
                        }
                    }
                    if let editingAgent, controller.hasStoredCredential(for: editingAgent) {
                        Toggle("Clear stored API key", isOn: $clearStoredAPIKey)
                    }
                    if let status = agentTestStatus, agentConnectionOK == false {
                        Text(status)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.red.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                .padding(.bottom, 14)
            }

            // ── Base URL (custom endpoint / advanced) ───────────────────────
            if preset.allowsCustomBaseURL || preset.id == "custom-openai-compatible" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    TextField("https://…", text: $newAgentBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.bottom, 14)
            }

            // ── Model picker (inline) ───────────────────────────────────────
            agentModelPickerSection(preset: preset, inlineModels: inlineModels)
                .padding(.bottom, 18)

            // ── Options ─────────────────────────────────────────────────────
            Toggle(
                editingAgent == nil ? "Attach to current workspace" : "Attach updated agent to current workspace",
                isOn: $assignNewAgentToWorkspace
            )
            .padding(.bottom, 18)

            // ── Actions ─────────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Cancel") {
                    showingAddAgentSheet = false
                    apiKeyTestTask?.cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(editingAgent == nil ? "Save" : "Update") {
                    if let editingAgent {
                        controller.updateAgent(
                            id: editingAgent.id,
                            name: newAgentName,
                            backendPresetID: preset.id,
                            providerKind: preset.providerKind,
                            modelIdentifier: newAgentModel,
                            baseURL: newAgentBaseURL,
                            apiKey: newAgentAPIKey,
                            clearStoredAPIKey: clearStoredAPIKey,
                            assignToSelectedWorkspace: assignNewAgentToWorkspace
                        )
                    } else {
                        controller.createAgent(
                            name: newAgentName,
                            backendPresetID: preset.id,
                            providerKind: preset.providerKind,
                            modelIdentifier: newAgentModel,
                            baseURL: newAgentBaseURL,
                            apiKey: newAgentAPIKey,
                            assignToSelectedWorkspace: assignNewAgentToWorkspace
                        )
                    }
                    apiKeyTestTask?.cancel()
                    showingAddAgentSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private func agentModelPickerSection(preset: CoworkBackendPreset, inlineModels: [CoworkModelOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if preset.providerKind == .faeLocalhost {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CoworkPalette.mint)
                    Text("Fae Local")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("On-device, private")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                TextField("Search models…", text: $agentModelSearchText)
                    .textFieldStyle(.roundedBorder)

                agentModelList(inlineModels: inlineModels)

                HStack(spacing: 6) {
                    TextField("Or type a model ID manually", text: $newAgentModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private func agentModelList(inlineModels: [CoworkModelOption]) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(inlineModels, id: \.modelIdentifier) { option in
                    let isSelected = newAgentModel == option.modelIdentifier
                    Button {
                        newAgentModel = option.modelIdentifier
                    } label: {
                        agentModelRow(option: option, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                }

                if inlineModels.isEmpty {
                    HStack {
                        Text(agentModelSearchText.isEmpty
                             ? "Enter an API key to discover models."
                             : "No models match \"\(agentModelSearchText)\".")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(height: 170)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func agentModelRow(option: CoworkModelOption, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(option.displayTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    if let ctxLabel = option.contextWindowLabel {
                        Text(ctxLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    let sortedCaps = Array(option.capabilities).sorted { $0.rawValue < $1.rawValue }
                    ForEach(sortedCaps, id: \.self) { cap in
                        CoworkCapabilityBadge(capability: cap)
                    }
                }
                Text(option.modelIdentifier)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CoworkPalette.mint)
                    .font(.system(size: 14))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? CoworkPalette.mint.opacity(0.10) : Color.primary.opacity(0.03))
        )
    }

    private func providerSystemImage(for presetID: String) -> String {
        switch presetID {
        case "fae-local":              return "sparkles"
        case "anthropic":              return "a.circle.fill"
        case "openai":                 return "bolt.circle.fill"
        case "openrouter":             return "network"
        case "custom-openai-compatible": return "wrench.and.screwdriver.fill"
        default:                       return "cloud"
        }
    }

    private func glassCard<Content: View>(
        padding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(CoworkPalette.panel)
                .background(
                    VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(CoworkPalette.outline, lineWidth: 1)

            content()
                .padding(padding)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .contentTransition(.interpolate)
    }

    private func primaryConversationSurface<Content: View>(
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.primary.opacity(0.02))
                .background(
                    VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                )

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 1)

            content()
                .padding(padding)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private func contextSectionLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.46))
        }
    }

    private func quickSuggestionChip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func utilitySheet(for section: CoworkWorkspaceSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Additional power, kept out of the main conversation surface.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.58))
                }
                Spacer()
                Button("Done") {
                    presentedUtilitySection = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Group {
                switch section {
                case .workspace:
                    EmptyView()
                case .scheduler:
                    schedulerSection
                case .skills:
                    skillsSection
                case .tools:
                    toolsSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private var workspaceOverflowMenu: some View {
        Menu {
            if let selectedWorkspace = controller.selectedWorkspace {
                Button("Rename conversation") {
                    renameWorkspaceName = selectedWorkspace.name
                    showingRenameWorkspaceSheet = true
                }
                Button("Fork conversation") {
                    controller.forkSelectedWorkspace()
                }
                Divider()
            }

            if let selectedWorkspace = controller.selectedWorkspace {
                Menu("Switch agent") {
                    ForEach(controller.agents) { agent in
                        Button(agent.name) {
                            controller.assignAgent(agent, to: selectedWorkspace)
                        }
                    }
                }
            }

            Button("Add agent") {
                prepareNewAgentForm()
                showingAddAgentSheet = true
            }

            if let selectedAgent = controller.selectedAgent {
                Button("Edit current agent") {
                    prepareAgentFormForEditing(selectedAgent)
                    showingAddAgentSheet = true
                }
            }

            Divider()

            Button("Refresh conversation") {
                controller.refreshNow()
            }

            ForEach(CoworkWorkspaceSection.allCases.filter { $0 != .workspace }) { section in
                Button("Open \(section.title)") {
                    presentedUtilitySection = section
                }
            }

            Divider()

            Button("Open settings") {
                controller.openSettings()
            }

            if controller.selectedWorkspace != nil {
                Button("Delete conversation", role: .destructive) {
                    showingDeleteWorkspaceAlert = true
                }
                .disabled(controller.workspaces.count <= 1)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.72))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Conversation actions")
        .accessibilityHint("Rename the conversation, manage agents, open tools, or open settings.")
    }

    private var modelPickerPill: some View {
        Button {
            openModelPickerForSelectedAgent()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedAgentLocalityIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selectedAgentLocalityAccent.opacity(0.92))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedAgentModelLabel ?? "Model")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(selectedAgentLocalityCaption)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.48))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Choose the model for this conversation. Switching models keeps the same thread.")
        .accessibilityLabel("Conversation model")
        .accessibilityValue(selectedAgentModelLabel ?? "No model selected")
        .accessibilityHint("Browse local and remote models for this conversation.")
    }

    private var modelPickerCompactPill: some View {
        Button {
            openModelPickerForSelectedAgent()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedAgentLocalityIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selectedAgentLocalityAccent.opacity(0.92))
                Text(selectedAgentModelLabel ?? "Model")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("Choose the model for this conversation. Switching models keeps the same thread.")
        .accessibilityLabel("Conversation model")
        .accessibilityValue(selectedAgentModelLabel ?? "No model selected")
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            CoworkBrandOrbView()
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Work with Fae")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Private cowork on your Mac")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.46).opacity(0.78))
                Text("\(controller.workspaces.count) conversation\(controller.workspaces.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.52))
            }

            Spacer()

            Button {
                newWorkspaceName = ""
                newWorkspaceAgentID = controller.selectedAgent?.id ?? WorkWithFaeAgentProfile.faeLocal.id
                newWorkspaceModel = (controller.selectedAgent?.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                    ?? (newWorkspaceSelectedAgent?.backendPreset?.suggestedModels.first ?? "")
                newWorkspaceDirectoryURL = nil
                showingAddWorkspaceSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .help("New conversation")
            .accessibilityLabel("New conversation")
            .accessibilityHint("Create a new cowork conversation with its own model and context.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var contextActionMenu: some View {
        Menu {
            Button {
                controller.addAttachmentsViaPicker()
            } label: {
                Label("Add files", systemImage: "plus.square.on.square")
            }

            Button {
                controller.addPastedContent()
            } label: {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
            }

            Button {
                controller.inspectCamera()
            } label: {
                Label("Use camera", systemImage: "camera")
            }

            Button {
                controller.inspectScreen()
            } label: {
                Label("Look at screen", systemImage: "rectangle.on.rectangle")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .overlay(Circle().stroke(Color.primary.opacity(0.09), lineWidth: 1))
                )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Add context")
        .accessibilityHint("Add files, paste content, use the camera, or inspect the screen.")
    }

    private var voiceCaptureButton: some View {
        Button {
            conversation.toggleListening()
        } label: {
            conversationControlPill(
                icon: conversation.isListening ? "mic.fill" : "mic.slash.fill",
                title: conversation.isListening ? "Listening" : "Voice off",
                accent: conversation.isListening ? CoworkPalette.mint : CoworkPalette.rose
            )
        }
        .buttonStyle(.plain)
        .help("Keep Fae listening while you type or speak.")
        .accessibilityLabel(conversation.isListening ? "Listening" : "Voice off")
        .accessibilityHint("Toggle shared voice capture for Fae.")
    }

    private var replayLatestReplyButton: some View {
        Button {
            if let latestAssistantReply {
                faeCore.speakDirect(latestAssistantReply)
            }
        } label: {
            conversationControlPill(
                icon: "speaker.wave.2.fill",
                title: "Read reply",
                accent: latestAssistantReply == nil ? CoworkPalette.heather : CoworkPalette.amber
            )
            .opacity(latestAssistantReply == nil ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(latestAssistantReply == nil)
        .help("Read the latest assistant reply aloud in Fae's voice.")
        .accessibilityLabel("Read latest reply aloud")
        .accessibilityHint("Replay the latest assistant response using Fae's voice.")
    }

    private func workspaceActionButton(
        title: String,
        systemImage: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(accent.opacity(0.18))
                        .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func iconActionButton(
        systemImage: String,
        accent: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(accent.opacity(0.16))
                        .overlay(Circle().stroke(accent.opacity(0.28), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private enum HeaderButtonLabelStyle {
        case iconOnly
        case titleAndIcon
    }

    private func detailsRailToggleButton(labelStyle: HeaderButtonLabelStyle) -> some View {
        Button {
            showDetailsRail.toggle()
        } label: {
            Group {
                switch labelStyle {
                case .iconOnly:
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(CoworkPalette.heather.opacity(0.16))
                                .overlay(Circle().stroke(CoworkPalette.heather.opacity(0.28), lineWidth: 1))
                        )
                case .titleAndIcon:
                    Label(showDetailsRail ? "Hide inspector" : "Inspector", systemImage: "sidebar.right")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(CoworkPalette.heather.opacity(0.16))
                                .overlay(Capsule().stroke(CoworkPalette.heather.opacity(0.28), lineWidth: 1))
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .help(showDetailsRail ? "Hide details" : "Show details")
        .accessibilityLabel(showDetailsRail ? "Hide inspector" : "Show inspector")
        .accessibilityHint("Open or close the cowork inspector rail.")
    }

    private var thinkingLevelPill: some View {
        Menu {
            ForEach(FaeThinkingLevel.allCases) { level in
                Button {
                    controller.setThinkingLevel(level)
                } label: {
                    if faeCore.thinkingLevel == level {
                        Label(level.displayName, systemImage: "checkmark")
                    } else {
                        Label(level.displayName, systemImage: level.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: faeCore.thinkingLevel.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoworkPalette.amber.opacity(0.9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(faeCore.thinkingLevel.displayName)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Response style")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.48))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Thinking level")
        .accessibilityValue(faeCore.thinkingLevel.displayName)
    }

    private var thinkingLevelCompactPill: some View {
        Menu {
            ForEach(FaeThinkingLevel.allCases) { level in
                Button {
                    controller.setThinkingLevel(level)
                } label: {
                    if faeCore.thinkingLevel == level {
                        Label(level.displayName, systemImage: "checkmark")
                    } else {
                        Label(level.displayName, systemImage: level.systemImage)
                    }
                }
            }
        } label: {
            conversationControlPill(icon: faeCore.thinkingLevel.systemImage, title: faeCore.thinkingLevel.displayName)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Thinking level")
        .accessibilityValue(faeCore.thinkingLevel.displayName)
    }

    private var consensusSummaryStrip: some View {
        let successCount = controller.latestConsensusResults.filter { $0.errorText == nil }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fae consensus")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(controller.selectedConsensusParticipantsSummary)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.58))
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 8) {
                    capsule(text: "\(successCount)/\(controller.latestConsensusResults.count) replied", accent: successCount == controller.latestConsensusResults.count ? CoworkPalette.mint : CoworkPalette.amber)

                    Button(showConsensusDetails ? "Hide answers" : "Show answers") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            showConsensusDetails.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    )
                }
            }

            FlowLayout(spacing: 8) {
                ForEach(controller.latestConsensusResults) { result in
                    capsule(
                        text: result.errorText == nil ? result.agentName : "\(result.agentName) failed",
                        accent: result.errorText == nil ? (result.isTrustedLocal ? CoworkPalette.mint : CoworkPalette.cyan) : CoworkPalette.rose
                    )
                }
            }

            if showConsensusDetails {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(controller.latestConsensusResults) { result in
                            consensusResultCard(result)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
        .shadow(color: showConsensusDetails ? CoworkPalette.heather.opacity(0.12) : .clear, radius: 16, y: 10)
    }

    private func consensusResultCard(_ result: WorkWithFaeConsensusResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.agentName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(result.providerLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.56))
                        .lineLimit(2)
                }
                Spacer()
                capsule(
                    text: result.errorText == nil ? (result.isTrustedLocal ? "Local" : "Remote") : "Issue",
                    accent: result.errorText == nil ? (result.isTrustedLocal ? CoworkPalette.mint : CoworkPalette.cyan) : CoworkPalette.rose
                )
            }

            Divider().overlay(Color.primary.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                if let responseText = result.responseText {
                    Text(responseText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.90))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label(result.errorText ?? "Unknown error", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(CoworkPalette.rose)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func conversationBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .assistant {
                bubble(message.content, accent: Color.primary.opacity(0.10), borderAccent: Color.primary.opacity(0.10), isTrailing: false)
                Spacer(minLength: 60)
            } else {
                Spacer(minLength: 60)
                bubble(message.content, accent: CoworkPalette.heather.opacity(0.18), borderAccent: CoworkPalette.heather.opacity(0.28), isTrailing: true)
            }
        }
    }

    private func streamingBubble(_ text: String) -> some View {
        HStack {
            bubble(text, accent: Color.primary.opacity(0.10), borderAccent: CoworkPalette.heather.opacity(0.34), isTrailing: false, isStreaming: true)
            Spacer(minLength: 60)
        }
    }

    private func bubble(_ text: String, accent: Color, borderAccent: Color, isTrailing: Bool, isStreaming: Bool = false) -> some View {
        let rendered = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        return Text(rendered)
            .font(.system(size: 14.5, weight: .regular, design: .rounded))
            .foregroundStyle(.primary.opacity(0.94))
            .multilineTextAlignment(isTrailing ? .trailing : .leading)
            .lineSpacing(4)
            .textSelection(.enabled)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(borderAccent, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(isStreaming ? 0.14 : 0.06), radius: 10, y: 4)
            .frame(maxWidth: 680, alignment: isTrailing ? .trailing : .leading)
    }

    private func schedulerTaskCard(_ task: CoworkSchedulerTask) -> some View {
        glassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(task.scheduleDescription)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.62))
                    }
                    Spacer()
                    capsule(text: task.isBuiltin ? "Built-in" : "Custom", accent: task.isBuiltin ? CoworkPalette.amber : CoworkPalette.cyan)
                }

                HStack(spacing: 10) {
                    schedulerMeta(label: "Next", value: relativeDate(task.nextRun))
                    schedulerMeta(label: "Last", value: relativeDate(task.lastRun))
                }

                if let taskDescription = task.taskDescription, !taskDescription.isEmpty {
                    Text(taskDescription)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.68))
                        .lineLimit(3)
                }

                if let lastError = task.lastError {
                    Text(lastError)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(CoworkPalette.rose)
                        .lineLimit(3)
                }

                HStack {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { task.enabled },
                            set: { controller.setTask(task, enabled: $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)

                    Text(task.enabled ? "Enabled" : "Paused")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(task.enabled ? CoworkPalette.mint : Color.primary.opacity(0.52))

                    Spacer()

                    Button("Run now") {
                        controller.runTask(task)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.05))
                            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    )
                }

                if !task.isBuiltin {
                    HStack(spacing: 10) {
                        Button("Edit") {
                            presentSchedulerEditor(.from(task: task))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.05))
                                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                        )

                        Button("Delete") {
                            pendingTaskDeletion = task
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(CoworkPalette.rose)
                    }
                }
            }
        }
    }

    private var taskDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingTaskDeletion != nil },
            set: { if !$0 { pendingTaskDeletion = nil } }
        )
    }

    private var skillDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingSkillDeletionName != nil },
            set: { if !$0 { pendingSkillDeletionName = nil } }
        )
    }

    private func schedulerEditorSheet(draft: EditableSchedulerTaskDraft) -> some View {
        CoworkSchedulerEditorSheet(draft: draft) { savedDraft in
            persistSchedulerDraft(savedDraft)
        }
    }

    private func persistSchedulerDraft(_ draft: EditableSchedulerTaskDraft) {
        let allowedTools = draft.allowedTools
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let scheduleParams: [String: String]
        switch draft.scheduleType {
        case "daily":
            scheduleParams = [
                "hour": draft.dailyHour.trimmingCharacters(in: .whitespacesAndNewlines),
                "minute": draft.dailyMinute.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        case "weekly":
            scheduleParams = [
                "day": draft.weeklyDay.trimmingCharacters(in: .whitespacesAndNewlines),
                "hour": draft.weeklyHour.trimmingCharacters(in: .whitespacesAndNewlines),
                "minute": draft.weeklyMinute.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        default:
            scheduleParams = [
                "hours": draft.intervalHours.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        }

        switch draft.mode {
        case .create:
            controller.createTask(
                name: draft.trimmedName,
                scheduleType: draft.scheduleType,
                scheduleParams: scheduleParams,
                action: draft.computedActionSummary,
                description: draft.trimmedDescription,
                instructionBody: draft.trimmedBody,
                allowedTools: allowedTools
            )
        case let .edit(existingID):
            guard let task = controller.schedulerTasks.first(where: { $0.id == existingID }) else { return }
            controller.updateTask(
                task,
                name: draft.trimmedName,
                scheduleType: draft.scheduleType,
                scheduleParams: scheduleParams,
                action: draft.computedActionSummary,
                description: draft.trimmedDescription,
                instructionBody: draft.trimmedBody,
                allowedTools: allowedTools
            )
        }
    }

    private func persistSkillDraft(_ draft: EditableSkillDraft) {
        switch draft.mode {
        case .create:
            controller.createSkill(
                name: draft.trimmedName,
                description: draft.trimmedDescription,
                body: draft.trimmedBody
            )
        case .edit:
            controller.updateSkill(
                name: draft.trimmedName,
                description: draft.trimmedDescription,
                body: draft.trimmedBody
            )
        }
    }

    private func presentSchedulerEditor(_ draft: EditableSchedulerTaskDraft) {
        presentedUtilitySection = nil
        DispatchQueue.main.async {
            schedulerEditorDraft = draft
        }
    }

    private func presentSkillEditor(_ draft: EditableSkillDraft) {
        presentedUtilitySection = nil
        DispatchQueue.main.async {
            skillEditorDraft = draft
        }
    }

    private func schedulerMeta(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.45))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachmentMetadataLabel(for attachment: WorkWithFaeAttachment) -> String {
        switch attachment.kind {
        case .image:
            return "Image"
        case .text:
            return "Pasted text"
        case .file:
            if let path = attachment.path {
                return URL(fileURLWithPath: path).pathExtension.isEmpty
                    ? "File"
                    : URL(fileURLWithPath: path).pathExtension.uppercased()
            }
            return "File"
        }
    }

    private func policyMenuRow<Content: View>(
        title: String,
        value: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoworkPalette.heather)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.52))
                    Text(value)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.46))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
    }

    private func blockedRemoteEgressCard(_ blocked: CoworkWorkspaceController.BlockedRemoteEgressRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CoworkPalette.amber)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Possible secret detected")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Fae kept this request on your Mac because it may contain a password, API key, token, or other secret. Nothing was sent to \(blocked.destinationList) yet. If this is a false positive, you can choose Send anyway.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Button("Send anyway") {
                    controller.sendBlockedRemoteEgressRequestAnyway()
                }
                .buttonStyle(.borderedProminent)

                Button("Keep local") {
                    controller.dismissBlockedRemoteEgressRequest()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CoworkPalette.rose.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CoworkPalette.amber.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func conversationControlPill(icon: String, title: String, accent: Color = CoworkPalette.heather) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.04))
                .overlay(Capsule().stroke(Color.primary.opacity(0.065), lineWidth: 1))
        )
    }

    private func heroDetailColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.38))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.84))
                .lineLimit(2)
                .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func quickActionPill(title: String, accent: Color = CoworkPalette.heather, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(accent.opacity(0.14))
                        .overlay(Capsule().stroke(accent.opacity(0.22), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func capsule(text: String, accent: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(accent.opacity(0.18))
                    .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
            )
    }

    private func relativeDate(_ date: Date?) -> String {
        guard let date else { return "Pending" }
        return date.formatted(.relative(presentation: .named))
    }

    private func sidebarCount(for section: CoworkWorkspaceSection) -> Int {
        switch section {
        case .workspace:
            return conversation.messages.count
        case .scheduler:
            return controller.schedulerTasks.count
        case .skills:
            return snapshot.skills.count
        case .tools:
            return snapshot.tools.count
        }
    }

    private func riskAccent(_ risk: String) -> Color {
        switch risk {
        case "high": return CoworkPalette.rose
        case "medium": return CoworkPalette.amber
        default: return CoworkPalette.mint
        }
    }

    private var selectedBackendPreset: CoworkBackendPreset {
        CoworkBackendPresetCatalog.preset(id: newAgentBackendPresetID) ?? CoworkLLMProviderKind.openAICompatibleExternal.defaultPreset
    }

    /// Inline model list for the agent creation sheet — suggested + discovered, filtered by search text.
    private var agentInlineModelOptions: [CoworkModelOption] {
        let preset = selectedBackendPreset
        let all = modelOptions(from: suggestedModels, for: preset, baseURL: newAgentBaseURL)
        let query = agentModelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return all }
        return all.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }

    private var editingAgent: WorkWithFaeAgentProfile? {
        guard let editingAgentID else { return nil }
        return controller.agents.first(where: { $0.id == editingAgentID })
    }

    private var effectiveAPIKeyForTesting: String? {
        let trimmed = newAgentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if selectedBackendPreset.id == "openrouter" {
            return CredentialManager.retrieve(key: "llm.openrouter.api_key")
        }
        guard !clearStoredAPIKey, let editingAgent, let credentialKey = editingAgent.credentialKey else {
            return nil
        }
        return CredentialManager.retrieve(key: credentialKey)
    }

    private var selectedAgentModelLabel: String? {
        guard let agent = controller.selectedAgent else {
            return nil
        }
        let preset = agent.backendPreset ?? agent.providerKind.defaultPreset
        let model = agent.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return agent.backendDisplayName
        }
        return compactModelLabel(for: model, preset: preset)
    }

    private var selectedAgentLocalityCaption: String {
        guard let agent = controller.selectedAgent else { return "Choose a model" }
        if agent.isTrustedLocal {
            return "On-device"
        }
        return controller.isStrictLocalWorkspace ? "Remote blocked by workspace policy" : "Remote model"
    }

    private var selectedAgentLocalityIcon: String {
        guard let agent = controller.selectedAgent else { return "sparkles.rectangle.stack" }
        return agent.isTrustedLocal ? "lock.shield.fill" : "network"
    }

    private var selectedAgentLocalityAccent: Color {
        guard let agent = controller.selectedAgent else { return CoworkPalette.heather }
        if agent.isTrustedLocal {
            return CoworkPalette.mint
        }
        return controller.isStrictLocalWorkspace ? CoworkPalette.rose : CoworkPalette.cyan
    }

    private var latestAssistantReply: String? {
        conversation.messages.last(where: { $0.role == .assistant })?.content.nilIfEmpty
    }

    private var newWorkspaceResolvedModelIdentifier: String {
        let model = newWorkspaceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            return model
        }
        return newWorkspaceSelectedAgent?.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var selectedModelValue: String {
        switch modelPickerTarget {
        case .agentEditor:
            return newAgentModel
        case .selectedConversationAgent:
            return controller.selectedAgent?.modelIdentifier ?? ""
        case .newWorkspaceAgent:
            return newWorkspaceModel
        }
    }

    private var selectedModelOptionID: String? {
        switch modelPickerTarget {
        case .agentEditor:
            return modelOptionID(for: newAgentModel, preset: selectedBackendPreset, baseURL: newAgentBaseURL)
        case .selectedConversationAgent:
            guard let agent = controller.selectedAgent else { return nil }
            let preset = agent.backendPreset ?? agent.providerKind.defaultPreset
            return modelOptionID(for: agent.modelIdentifier, preset: preset, baseURL: agent.baseURL)
        case .newWorkspaceAgent:
            guard let agent = newWorkspaceSelectedAgent else { return nil }
            let preset = agent.backendPreset ?? agent.providerKind.defaultPreset
            return modelOptionID(for: newWorkspaceResolvedModelIdentifier, preset: preset, baseURL: agent.baseURL)
        }
    }

    private var presetSuggestedModels: [String] {
        selectedBackendPreset.suggestedModels
    }

    private var suggestedModels: [String] {
        var seen = Set<String>()
        return (presetSuggestedModels + discoveredModels).filter { seen.insert($0).inserted }
    }

    private var suggestedModelOptions: [CoworkModelOption] {
        modelOptions(from: suggestedModels, for: selectedBackendPreset, baseURL: newAgentBaseURL)
    }

    private var filteredModelOptions: [CoworkModelOption] {
        let source = browsableModelOptions.isEmpty ? suggestedModelOptions : browsableModelOptions
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }

    private var filteredModelOptionSections: [CoworkModelOptionSection] {
        let grouped = Dictionary(grouping: filteredModelOptions) { option in
            option.sectionGroupKey
        }

        return grouped.keys.sorted { lhsKey, rhsKey in
            let lhsRank = grouped[lhsKey]?.first?.sectionSortRank ?? Int.max
            let rhsRank = grouped[rhsKey]?.first?.sectionSortRank ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsTitle = grouped[lhsKey]?.first?.sectionTitle ?? lhsKey
            let rhsTitle = grouped[rhsKey]?.first?.sectionTitle ?? rhsKey
            return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
        }.compactMap { key in
            guard let options = grouped[key], let first = options.first else { return nil }
            let configuredCount = options.filter(\.isConfigured).count
            let readyText = configuredCount == options.count
                ? "Ready"
                : (configuredCount == 0 ? "Needs setup" : "\(configuredCount) ready")
            let subtitle = first.sectionSubtitleExtra.isEmpty
                ? readyText
                : "\(first.sectionSubtitleExtra) · \(readyText)"
            return CoworkModelOptionSection(
                id: key,
                title: first.sectionTitle,
                subtitle: subtitle,
                options: options.sorted { lhs, rhs in
                    if lhs.isConfigured != rhs.isConfigured { return lhs.isConfigured && !rhs.isConfigured }
                    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
                }
            )
        }
    }

    private func openModelPickerForSelectedAgent() {
        modelPickerTarget = .selectedConversationAgent
        modelSearchText = ""
        isLoadingModelPickerOptions = false
        browsableModelOptions = controller.availableConversationModelOptions()
        showingModelPickerSheet = true
    }

    private func openModelPickerForNewWorkspaceAgent() {
        guard let agent = newWorkspaceSelectedAgent else { return }
        openModelPicker(for: agent, target: .newWorkspaceAgent)
    }

    private func openModelPicker(for agent: WorkWithFaeAgentProfile, target: ModelPickerTarget) {
        modelPickerTarget = target
        modelSearchText = ""
        isLoadingModelPickerOptions = true
        let preset = agent.backendPreset ?? agent.providerKind.defaultPreset
        let currentModel: String
        switch target {
        case .newWorkspaceAgent:
            currentModel = newWorkspaceModel
        case .agentEditor, .selectedConversationAgent:
            currentModel = agent.modelIdentifier
        }
        let cachedModels = controller.cachedModels(for: agent, maxAge: CoworkRemoteModelCatalog.defaultFreshnessTTL)
        let initialModels = Array(([currentModel] + preset.suggestedModels + cachedModels).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).reduce(into: [String]()) { result, item in
            if !result.contains(item) {
                result.append(item)
            }
        }
        browsableModelOptions = modelOptions(from: initialModels, for: preset, baseURL: agent.baseURL)
        showingModelPickerSheet = true

        Task {
            do {
                let report = try await controller.testConnection(for: agent)
                await MainActor.run {
                    let discovered = report.discoveredModels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let merged = ([currentModel] + preset.suggestedModels + discovered).reduce(into: [String]()) { result, item in
                        if !result.contains(item) {
                            result.append(item)
                        }
                    }
                    browsableModelOptions = modelOptions(from: merged, for: preset, baseURL: agent.baseURL)
                    isLoadingModelPickerOptions = false
                }
            } catch {
                await MainActor.run {
                    isLoadingModelPickerOptions = false
                }
            }
        }
    }

    private var newWorkspaceSelectedAgent: WorkWithFaeAgentProfile? {
        controller.agents.first(where: { $0.id == newWorkspaceAgentID })
    }

    private var newWorkspaceSelectedPreset: CoworkBackendPreset? {
        newWorkspaceSelectedAgent?.backendPreset ?? newWorkspaceSelectedAgent?.providerKind.defaultPreset
    }

    private var newWorkspaceBackendSummary: String {
        guard let agent = newWorkspaceSelectedAgent else { return "No agent selected" }
        let option = modelOption(for: newWorkspaceResolvedModelIdentifier, preset: newWorkspaceSelectedPreset ?? agent.providerKind.defaultPreset)
        guard let option else { return agent.backendDisplayName }
        return "\(option.displayTitle) · \(option.providerDisplayName)"
    }

    private var newWorkspaceModelDisplayValue: String {
        let model = newWorkspaceResolvedModelIdentifier
        guard !model.isEmpty else { return "No model selected" }
        guard let preset = newWorkspaceSelectedPreset else { return model }
        return modelOption(for: model, preset: preset)?.compactLabel ?? model
    }

    private func syncNewWorkspaceModelSelection() {
        guard let agent = newWorkspaceSelectedAgent else {
            newWorkspaceModel = ""
            return
        }
        let currentSelection = newWorkspaceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentSelection.isEmpty {
            return
        }
        let existing = agent.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            newWorkspaceModel = existing
            return
        }
        newWorkspaceModel = (newWorkspaceSelectedPreset?.suggestedModels.first ?? "")
    }

    private func prepareNewAgentForm() {
        let config = FaeConfig.load()
        let preset = CoworkBackendPresetCatalog.preset(id: config.llm.remoteProviderPreset)
            ?? CoworkBackendPresetCatalog.preset(id: "openrouter")
            ?? CoworkLLMProviderKind.openAICompatibleExternal.defaultPreset
        editingAgentID = nil
        newAgentName = ""
        newAgentBackendPresetID = preset.id
        newAgentProvider = preset.providerKind
        newAgentModel = config.llm.remoteModel.isEmpty ? (preset.suggestedModels.first ?? "") : config.llm.remoteModel
        newAgentBaseURL = config.llm.remoteBaseURL.isEmpty ? preset.defaultBaseURL : config.llm.remoteBaseURL
        newAgentAPIKey = ""
        clearStoredAPIKey = false
        discoveredModels = []
        agentTestStatus = nil
        assignNewAgentToWorkspace = true
    }

    private func prepareAgentFormForEditing(_ agent: WorkWithFaeAgentProfile) {
        let preset = agent.backendPreset ?? agent.providerKind.defaultPreset
        editingAgentID = agent.id
        newAgentName = agent.name
        newAgentBackendPresetID = preset.id
        newAgentProvider = agent.providerKind
        newAgentModel = agent.modelIdentifier
        newAgentBaseURL = agent.baseURL ?? preset.defaultBaseURL
        newAgentAPIKey = ""
        clearStoredAPIKey = false
        discoveredModels = []
        agentTestStatus = nil
        assignNewAgentToWorkspace = controller.selectedWorkspace?.agentID == agent.id
    }

    private func agentSummary(for agent: WorkWithFaeAgentProfile?) -> String {
        guard let agent else { return "No agent" }
        let preset = agent.backendPreset ?? agent.providerKind.defaultPreset
        let model = agent.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return agent.backendDisplayName }
        return compactModelLabel(for: model, preset: preset)
    }

    private var snapshot: CoworkWorkspaceSnapshot { controller.snapshot }

    private var workspaceHeaderCaption: String {
        var parts: [String] = []
        if controller.remoteAgentBlockedByPolicy {
            parts.append("Fae Local is handling this thread")
        } else {
            parts.append(selectedAgentModelLabel ?? agentSummary(for: controller.selectedAgent))
            parts.append(selectedAgentLocalityCaption)
        }
        if controller.workspaceState.selectedDirectoryPath != nil {
            parts.append("folder attached")
        } else {
            parts.append("no folder yet")
        }
        if controller.workspaceState.attachments.isEmpty == false {
            parts.append("\(controller.workspaceState.attachments.count) attachment\(controller.workspaceState.attachments.count == 1 ? "" : "s")")
        }
        if controller.selectedWorkspacePolicy.compareBehavior == .alwaysCompare {
            parts.append("auto compare on")
        }
        return parts.joined(separator: " · ")
    }

    private var workspaceHeaderMetaLine: String? {
        var parts: [String] = []
        if controller.workspaceState.selectedDirectoryPath != nil {
            parts.append("Folder attached")
        }
        if controller.workspaceState.attachments.isEmpty == false {
            parts.append("\(controller.workspaceState.attachments.count) attachment\(controller.workspaceState.attachments.count == 1 ? "" : "s")")
        }
        if let workspace = controller.selectedWorkspace,
           let parent = controller.parentWorkspace(for: workspace)
        {
            parts.append("Fork of \(parent.name)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var detailsRailCaption: String {
        var parts: [String] = []
        parts.append(controller.workspaceState.selectedDirectoryPath == nil ? "No folder" : "Folder ready")
        parts.append("\(controller.workspaceState.attachments.count) attachment\(controller.workspaceState.attachments.count == 1 ? "" : "s")")
        if !controller.workspaceState.indexedFiles.isEmpty {
            parts.append("\(controller.workspaceState.indexedFiles.count) indexed")
        }
        return parts.joined(separator: "  ·  ")
    }

}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
