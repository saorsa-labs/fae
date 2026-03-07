import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum CoworkPalette {
    static let ink = Color.black.opacity(0.12)
    static let panel = Color.white.opacity(0.035)
    static let outline = Color.white.opacity(0.075)
    static let heather = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)
    static let amber = Color(red: 204 / 255, green: 163 / 255, blue: 92 / 255)
    static let cyan = Color(red: 138 / 255, green: 154 / 255, blue: 181 / 255)
    static let rose = Color(red: 142 / 255, green: 108 / 255, blue: 128 / 255)
    static let mint = Color(red: 150 / 255, green: 172 / 255, blue: 160 / 255)
}

private enum CoworkArtwork {
    static let orb = FaeApp.renderStaticOrb()
}

private enum ModelPickerTarget {
    case agentEditor
    case selectedConversationAgent
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
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.delegate = context.coordinator
        textView.submitHandler = onSubmit
        textView.placeholderString = placeholder
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.documentView = textView

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
    @ObservedObject var orbAnimation: OrbAnimationState
    @ObservedObject var pipelineAux: PipelineAuxBridgeController

    @State private var isDropTargeted = false
    @State private var showingAddWorkspaceSheet = false
    @State private var showingRenameWorkspaceSheet = false
    @State private var showingAddAgentSheet = false
    @State private var showingDeleteAgentAlert = false
    @State private var showingDeleteWorkspaceAlert = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceAgentID = WorkWithFaeAgentProfile.faeLocal.id
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
    @State private var discoveredModels: [String] = []
    @State private var showingModelPickerSheet = false
    @State private var modelPickerTarget: ModelPickerTarget = .agentEditor
    @State private var modelSearchText = ""
    @State private var browsableModelOptions: [String] = []
    @State private var isLoadingModelPickerOptions = false
    @State private var composerHeight: CGFloat = 64
    @State private var showConsensusDetails = false
    @State private var showWorkspacePolicies = false
    @State private var showAgentControls = false
    @State private var showSidebarUtilities = false
    @State private var showSidebarAgents = false
    @State private var showDetailsRail = false
    @State private var presentedUtilitySection: CoworkWorkspaceSection?
    @State private var showContextFolderSection = true
    @State private var showContextAttachmentsSection = false
    @State private var showContextIndexedFilesSection = false
    @State private var showContextPreviewSection = true
    @State private var isHoveringPresenceOrb = false
    @Namespace private var workspaceSelectionAnimation

    var body: some View {
        ZStack {
            backdrop

            HStack(spacing: 16) {
                sidebar
                    .frame(width: 220)

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
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
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
                            .foregroundStyle(.white)
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
        .preferredColorScheme(.dark)
        .onAppear {
            controller.scheduleRefresh(after: 0.05)
        }
        .onChange(of: controller.latestConsensusResults.count) {
            showConsensusDetails = false
        }
        .onChange(of: controller.workspaces.map(\.id)) {
            draggedWorkspaceID = nil
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: controller.selectedWorkspace?.id)
        .animation(.easeInOut(duration: 0.22), value: showDetailsRail)
        .animation(.easeInOut(duration: 0.22), value: showWorkspacePolicies)
        .animation(.easeInOut(duration: 0.22), value: showAgentControls)
        .animation(.easeInOut(duration: 0.22), value: showConsensusDetails)
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
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(controller.selectedWorkspace?.name ?? "Conversation")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                FlowLayout(spacing: 8) {
                    headerPill(icon: controller.remoteAgentBlockedByPolicy ? "lock.shield" : "cpu", text: controller.remoteAgentBlockedByPolicy ? "Fae Local" : (controller.selectedAgent?.backendDisplayName ?? "Agent"))
                    if controller.workspaceState.selectedDirectoryPath != nil {
                        headerPill(icon: "folder", text: "Folder attached")
                    }
                    if let workspace = controller.selectedWorkspace,
                       let parent = controller.parentWorkspace(for: workspace)
                    {
                        headerPill(icon: "arrow.triangle.branch", text: "Fork of \(parent.name)")
                    }
                }
            }

            Spacer(minLength: 12)

            headerPresenceOrb
                .padding(.top, 2)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                agentPickerPill
                if controller.selectedAgent != nil {
                    modelPickerPill
                }
                quickActionPill(title: showDetailsRail ? "Hide details" : "Details", accent: CoworkPalette.heather) {
                    showDetailsRail.toggle()
                }
                utilityMenuPill
                if let selectedWorkspace = controller.selectedWorkspace {
                    Menu {
                        Button("Rename conversation") {
                            renameWorkspaceName = selectedWorkspace.name
                            showingRenameWorkspaceSheet = true
                        }
                        Button("Fork conversation") {
                            controller.forkSelectedWorkspace()
                        }
                        Divider()
                        Button("Move up") {
                            controller.moveSelectedWorkspaceUp()
                        }
                        .disabled(!controller.canMoveSelectedWorkspaceUp)
                        Button("Move down") {
                            controller.moveSelectedWorkspaceDown()
                        }
                        .disabled(!controller.canMoveSelectedWorkspaceDown)
                        Divider()
                        Button("Refresh workspace") {
                            controller.refreshNow()
                        }
                        Button("Open settings") {
                            controller.openSettings()
                        }
                        Divider()
                        Button("Delete conversation", role: .destructive) {
                            showingDeleteWorkspaceAlert = true
                        }
                        .disabled(controller.workspaces.count <= 1)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                            )
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
    }

    private var utilityHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Work with Fae")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer()
            workspaceActionButton(
                title: controller.isRefreshing ? "Refreshing" : "Refresh",
                systemImage: "arrow.clockwise",
                accent: CoworkPalette.cyan,
                action: { controller.refreshNow() }
            )
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
                    .frame(width: 208)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceHeroCard: some View {
        glassCard {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [CoworkPalette.heather.opacity(0.16), CoworkPalette.amber.opacity(0.08), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(nsImage: CoworkArtwork.orb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: CoworkPalette.heather.opacity(0.25), radius: 12, y: 6)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.selectedWorkspace?.name ?? "Workspace")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .contentTransition(.interpolate)
                            Text(currentWorkspaceSubtitle)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.68))
                                .lineLimit(3)
                            FlowLayout(spacing: 8) {
                                miniInfoBadge(icon: "sparkles", text: controller.selectedAgent?.backendDisplayName ?? "Fae Local")
                                miniInfoBadge(icon: controller.isStrictLocalWorkspace ? "lock.shield" : "network", text: controller.selectedWorkspacePolicy.remoteExecution.displayName)
                                miniInfoBadge(icon: "paperplane", text: controller.selectedWorkspacePolicy.compareBehavior.displayName)
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        metricTile(title: "Files", value: "\(controller.workspaceState.indexedFiles.count)", accent: CoworkPalette.amber)
                        metricTile(title: "Attached", value: "\(controller.workspaceState.attachments.count)", accent: CoworkPalette.cyan)
                        metricTile(title: "Tasks", value: "\(controller.schedulerTasks.filter(\.enabled).count)", accent: CoworkPalette.mint)
                    }

                    HStack(spacing: 10) {
                        workspaceActionButton(
                            title: controller.workspaceState.selectedDirectoryPath == nil ? "Choose folder" : "Change folder",
                            systemImage: "folder",
                            accent: CoworkPalette.heather,
                            action: controller.chooseWorkspaceDirectory
                        )

                        workspaceActionButton(
                            title: "Add files",
                            systemImage: "paperclip",
                            accent: CoworkPalette.cyan,
                            action: controller.addAttachmentsViaPicker
                        )

                        workspaceActionButton(
                            title: "Look at screen",
                            systemImage: "rectangle.on.rectangle",
                            accent: CoworkPalette.amber,
                            action: controller.inspectScreen
                        )

                        if controller.workspaceState.selectedDirectoryPath != nil {
                            workspaceActionButton(
                                title: "Clear",
                                systemImage: "xmark.circle",
                                accent: CoworkPalette.rose,
                                action: controller.clearWorkspaceDirectory
                            )
                        }
                    }
                }
            }
        }
        .matchedGeometryEffect(id: "workspace-hero", in: workspaceSelectionAnimation)
    }

    private var workspaceContextPanel: some View {
        glassCard {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Details")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Small, quiet context for this conversation.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.54))
                    }

                    FlowLayout(spacing: 8) {
                        miniInfoBadge(icon: "folder", text: controller.workspaceState.selectedDirectoryPath == nil ? "No folder" : "Folder attached")
                        miniInfoBadge(icon: "paperclip", text: "\(controller.workspaceState.attachments.count) items")
                        miniInfoBadge(icon: "doc.text", text: "\(controller.workspaceState.indexedFiles.count) files")
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
                    .tint(.white)

                    DisclosureGroup(isExpanded: $showContextFolderSection) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let path = controller.workspaceState.selectedDirectoryPath {
                                Text(path)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            } else {
                                Text("Choose a folder to let Fae ground answers in local files.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        contextSectionLabel(title: "Folder & grounding", subtitle: controller.workspaceState.selectedDirectoryPath == nil ? "Not connected" : "Connected")
                    }
                    .tint(.white)

                    DisclosureGroup(isExpanded: $showContextAttachmentsSection) {
                        VStack(alignment: .leading, spacing: 8) {
                            if controller.workspaceState.attachments.isEmpty {
                                Text("Add files, pasted text, or screenshots when you want more focused context.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            } else {
                                ForEach(controller.workspaceState.attachments.prefix(8)) { attachment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: attachment.kind == .image ? "photo" : (attachment.kind == .text ? "doc.text" : "paperclip"))
                                            .foregroundStyle(CoworkPalette.heather)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(attachment.displayName)
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.white)
                                                .lineLimit(2)
                                            if let path = attachment.path {
                                                Text(path)
                                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(Color.white.opacity(0.42))
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(controller.selectedAttachment?.id == attachment.id ? CoworkPalette.heather.opacity(0.14) : Color.white.opacity(0.03))
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
                    .tint(.white)

                    DisclosureGroup(isExpanded: $showContextIndexedFilesSection) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Search files by name or type", text: $controller.workspaceSearchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                                        )
                                )

                            if controller.workspaceState.indexedFiles.isEmpty {
                                Text("No indexed files yet.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.55))
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
                                                    .foregroundStyle(.white)
                                                    .lineLimit(2)
                                                Text(file.kind.capitalized)
                                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                                    .foregroundStyle(Color.white.opacity(0.42))
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
                    .tint(.white)

                    if let focusedPreview = controller.focusedPreview {
                        DisclosureGroup(isExpanded: $showContextPreviewSection) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(focusedPreview.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .textSelection(.enabled)

                                if let path = focusedPreview.path {
                                    Text(path)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }

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
                                        .foregroundStyle(Color.white.opacity(0.74))
                                        .lineLimit(10)
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color.white.opacity(0.04))
                                        )
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            contextSectionLabel(title: "Focused preview", subtitle: focusedPreview.subtitle ?? focusedPreview.kind.capitalized)
                        }
                        .tint(.white)
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
                        Spacer()
                        if conversation.isGenerating {
                            Label(conversation.isStreaming ? "Replying live" : "Thinking", systemImage: conversation.isStreaming ? "waveform.badge.mic" : "ellipsis.message.fill")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(CoworkPalette.cyan.opacity(0.14)))
                                .overlay(Capsule().stroke(CoworkPalette.cyan.opacity(0.26), lineWidth: 1))
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
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
                                ForEach(Array(conversation.messages.suffix(40))) { message in
                                    conversationBubble(message)
                                        .transition(.move(edge: message.role == .assistant ? .leading : .trailing).combined(with: .opacity))
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
                    FlowLayout(spacing: 8) {
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

                        Button {
                            if controller.workspaceState.selectedDirectoryPath == nil {
                                controller.chooseWorkspaceDirectory()
                            } else {
                                showDetailsRail = true
                            }
                        } label: {
                            conversationControlPill(icon: "folder", title: controller.workspaceState.selectedDirectoryPath == nil ? "Add folder" : "Folder")
                        }
                        .buttonStyle(.plain)

                        Button {
                            presentedUtilitySection = .tools
                        } label: {
                            conversationControlPill(icon: "wrench.and.screwdriver", title: "Tools")
                        }
                        .buttonStyle(.plain)

                        if let focusedTitle = controller.focusedPreview?.title {
                            conversationControlPill(icon: "scope", title: focusedTitle)
                        }
                    }

                    HStack(alignment: .bottom, spacing: 12) {
                        contextActionMenu

                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                if controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Ask Fae to work with this folder, these files, or what you want her to inspect…")
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.34))
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

                            HStack(spacing: 8) {
                                Text(conversation.isGenerating ? (conversation.isStreaming ? "Fae is replying live…" : "Fae is thinking…") : "Ready in this conversation.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.48))
                                    .contentTransition(.interpolate)

                                Spacer()

                                if !controller.latestConsensusResults.isEmpty {
                                    Text("Last compare: \(controller.latestConsensusResults.count) agents")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white.opacity(0.045))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                                )
                        )

                        Button(action: controller.compareDraftAcrossAgents) {
                            Label(controller.selectedWorkspacePolicy.compareBehavior == .alwaysCompare ? "Auto" : "Compare", systemImage: "square.stack.3d.up.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.08))
                                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                                )
                                .opacity(controller.canCompareAcrossAgents && controller.selectedWorkspacePolicy.compareBehavior != .alwaysCompare ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.canCompareAcrossAgents || controller.selectedWorkspacePolicy.compareBehavior == .alwaysCompare)
                        .help(controller.isStrictLocalWorkspace ? "This workspace is strict local only, so comparison stays disabled." : (controller.selectedWorkspacePolicy.compareBehavior == .alwaysCompare ? "This workspace already compares automatically when you send." : "Compare across the selected workspace agents now."))

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
                    }
                }
            }
        }
    }

    private var headerPresenceOrb: some View {
        VStack(spacing: 4) {
            ZStack {
                RadialGradient(
                    colors: [CoworkPalette.heather.opacity(isHoveringPresenceOrb ? 0.18 : 0.1), Color.clear],
                    center: .center,
                    startRadius: 6,
                    endRadius: 44
                )
                .frame(width: 72, height: 72)

                NativeOrbView(
                    orbAnimation: orbAnimation,
                    audioRMS: pipelineAux.audioRMS,
                    windowMode: "cowork",
                    onLoad: nil,
                    onOrbClicked: nil,
                    onOrbContextMenu: nil
                )
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .scaleEffect(isHoveringPresenceOrb ? 1.04 : 1)
                .shadow(color: CoworkPalette.heather.opacity(isHoveringPresenceOrb ? 0.16 : 0.08), radius: isHoveringPresenceOrb ? 12 : 6, y: 4)
            }
            .frame(width: 72, height: 40)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringPresenceOrb = hovering
            }
            .help("Fae is always watching over you, and she is listening.")

            if isHoveringPresenceOrb {
                Text("Fae is always watching over you, and she is listening.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.05))
                            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 120)
        .allowsHitTesting(true)
    }

    private var emptyConversationState: some View {
        let setupState = controller.selectedWorkspaceSetupState

        return VStack(alignment: .leading, spacing: 14) {
            Text(setupState.isFreshWorkspace ? "Start a new conversation here." : "Pick up exactly where you left off.")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(setupState.isFreshWorkspace
                 ? "Pick a folder, drop in files or images, then start working in this space."
                 : "This conversation keeps its own model, context, attachments, and branch history close at hand.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))

            FlowLayout(spacing: 10) {
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
                if controller.agents.count <= 1 {
                    quickActionPill(title: "Add agent", accent: CoworkPalette.amber) {
                        prepareNewAgentForm()
                        showingAddAgentSheet = true
                    }
                }
                quickActionPill(title: "Summarize workspace", accent: CoworkPalette.heather) {
                    controller.useQuickPrompt("Summarize this workspace and tell me where I should start.")
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var schedulerSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scheduler board")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Live view across Fae's persistent automations and built-ins.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }

                    Spacer()

                    workspaceActionButton(
                        title: "Run skill health",
                        systemImage: "stethoscope",
                        accent: CoworkPalette.cyan,
                        action: { controller.runTask(id: "skill_health_check") }
                    )
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
                            .foregroundStyle(.white)
                        Text("Installed and active Fae skills, ready for cowork use.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer()
                    Text("\(snapshot.skills.count) skills")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.70))
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(snapshot.skills) { skill in
                            glassCard(padding: 16) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(skill.id)
                                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Spacer()
                                        capsule(text: skill.isActive ? "Active" : "Installed", accent: skill.isActive ? CoworkPalette.mint : CoworkPalette.cyan)
                                    }

                                    Text(skill.description)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.68))
                                        .lineLimit(4)

                                    HStack(spacing: 8) {
                                        capsule(text: skill.type.capitalized, accent: CoworkPalette.amber)
                                        capsule(text: skill.tier.capitalized, accent: CoworkPalette.rose)
                                        if !skill.isEnabled {
                                            capsule(text: "Disabled", accent: .gray)
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
                            .foregroundStyle(.white)
                        Text("Filtered to the current tool mode so the cowork surface matches Fae's runtime permissions.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer()
                    Text(snapshot.toolMode.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.70))
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(snapshot.tools) { tool in
                            glassCard(padding: 16) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(tool.displayName)
                                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Spacer()
                                        capsule(text: tool.riskLevel.capitalized, accent: riskAccent(tool.riskLevel))
                                    }

                                    Text(tool.description)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.68))
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

    private var inspector: some View {
        VStack(spacing: 18) {
            glassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Runtime")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    inspectorRow(title: "Owner", value: snapshot.hasOwnerSetUp ? (snapshot.userName ?? "Configured") : "Not enrolled")
                    inspectorRow(title: "Listening", value: conversation.isListening ? "Open" : "Muted")
                    inspectorRow(title: "Model", value: conversation.loadedModelLabel.isEmpty ? "Loading..." : conversation.loadedModelLabel)
                    inspectorRow(title: "Background tools", value: "\(conversation.backgroundToolJobsInFlight)")

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack(spacing: 10) {
                        quickActionPill(title: "Morning briefing", action: { controller.runTask(id: "morning_briefing") })
                        quickActionPill(title: "Settings", action: controller.openSettings)
                    }
                }
            }

            glassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Latest reply")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(latestAssistantExcerpt)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.70))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            glassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Activity")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    if controller.activityItems.isEmpty {
                        Text("Tool calls, scheduler runs, and runtime changes appear here as they happen.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    } else {
                        ForEach(controller.activityItems.prefix(7)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle()
                                        .fill(activityAccent(item.tone))
                                        .frame(width: 8, height: 8)
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(item.timestamp, style: .time)
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.50))
                                }

                                Text(item.detail)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.62))
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Workspace at a glance")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    inspectorRow(title: "Folder", value: controller.workspaceState.selectedDirectoryPath == nil ? "Not selected" : "Selected")
                    inspectorRow(title: "Indexed files", value: "\(controller.workspaceState.indexedFiles.count)")
                    inspectorRow(title: "Attachments", value: "\(controller.workspaceState.attachments.count)")
                    inspectorRow(title: "Apple tools", value: "\(snapshot.appleTools.count)")

                    if !snapshot.appleTools.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(snapshot.appleTools) { tool in
                                capsule(text: tool.displayName, accent: CoworkPalette.cyan)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        glassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: CoworkArtwork.orb)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work with Fae")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Conversations")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.54))
                    }

                    Spacer()

                    Button {
                        newWorkspaceName = ""
                        newWorkspaceAgentID = controller.selectedAgent?.id ?? WorkWithFaeAgentProfile.faeLocal.id
                        newWorkspaceDirectoryURL = nil
                        showingAddWorkspaceSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("New conversation")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Text("Every workspace is a conversation with its own model, context, and permissions.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .padding(.horizontal, 16)

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

                HStack(spacing: 8) {
                    utilityMenuPill
                    quickActionPill(title: "Agent", accent: CoworkPalette.cyan) {
                        prepareNewAgentForm()
                        showingAddAgentSheet = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private var compactWorkspaceSetupStrip: some View {
        let setupState = controller.selectedWorkspaceSetupState

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(setupState.nextStep?.title ?? "Workspace ready")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(setupState.nextStep?.detail ?? "Grounded context is ready.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.52))
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
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var workspaceSetupCard: some View {
        let setupState = controller.selectedWorkspaceSetupState

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(setupState.isFreshWorkspace ? "Get this workspace ready" : "Workspace readiness")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(setupState.isReadyForGroundedWork
                         ? "Grounded context is ready. Add a specialist any time you want comparisons."
                         : (setupState.nextStep?.detail ?? "Add a little context so Fae can start grounded work."))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .lineLimit(3)
                }

                Spacer()

                Text("\(setupState.completedRequiredCount)/\(max(setupState.totalRequiredCount, 1))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(setupState.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.isComplete ? "checkmark.circle.fill" : (step.isOptional ? "circle.dashed" : "circle"))
                            .foregroundStyle(step.isComplete ? CoworkPalette.mint : (step.isOptional ? CoworkPalette.heather : Color.white.opacity(0.55)))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(step.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                if step.isOptional {
                                    capsule(text: "Optional", accent: CoworkPalette.heather)
                                }
                            }
                            Text(step.detail)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.54))
                                .lineLimit(2)
                        }
                    }
                }
            }

            FlowLayout(spacing: 8) {
                quickActionPill(title: controller.workspaceState.selectedDirectoryPath == nil ? "Choose folder" : "Change folder", accent: CoworkPalette.heather) {
                    controller.chooseWorkspaceDirectory()
                }
                quickActionPill(title: "Add files", accent: CoworkPalette.cyan) {
                    controller.addAttachmentsViaPicker()
                }
                if controller.agents.count <= 1 {
                    quickActionPill(title: "Add agent", accent: CoworkPalette.amber) {
                        prepareNewAgentForm()
                        showingAddAgentSheet = true
                    }
                } else if !controller.canCompareAcrossAgents {
                    quickActionPill(title: "Enable compare", accent: CoworkPalette.amber) {
                        controller.updateWorkspaceCompareBehavior(.alwaysCompare)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var workspaceDropTail: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.035))
            .frame(height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CoworkPalette.heather.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                    .overlay {
                        Text("Drop to move to the end")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.6))
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

        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                controller.selectWorkspace(workspace)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if depth > 0 {
                        HStack(spacing: 4) {
                            ForEach(0 ..< depth, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 6, height: 1)
                            }
                        }
                        .frame(width: CGFloat(depth * 10), alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.name)
                            .font(.system(size: isSelected ? 13.5 : 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(agentSummary(for: agent))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle((agent?.isTrustedLocal == true ? CoworkPalette.mint : CoworkPalette.cyan).opacity(0.84))
                                .lineLimit(1)

                            if let parentName {
                                Text("Fork of \(parentName)")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.42))
                                    .lineLimit(1)
                            } else if childrenCount > 0 {
                                Text("\(childrenCount) fork\(childrenCount == 1 ? "" : "s")")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.42))
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    if isSelected && agent?.isTrustedLocal == true {
                        capsule(text: "Local", accent: CoworkPalette.mint)
                    }
                }

                if isSelected {
                    FlowLayout(spacing: 6) {
                        if workspace.state.selectedDirectoryPath != nil {
                            capsule(text: "Folder", accent: CoworkPalette.heather)
                        }
                        if !workspace.state.attachments.isEmpty {
                            capsule(text: "\(workspace.state.attachments.count) files", accent: CoworkPalette.cyan)
                        }
                        if workspace.policy.compareBehavior == .alwaysCompare {
                            capsule(text: "Compare", accent: CoworkPalette.amber)
                        }
                    }
                }
            }
            .padding(.leading, 12 + CGFloat(depth * 8))
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.05), lineWidth: 1)
                    )
                    .matchedGeometryEffect(id: "workspace-row-\(workspace.id.uuidString)", in: workspaceSelectionAnimation)
            )
            .scaleEffect(isSelected ? 1.0 : 0.99)
            .opacity(draggedWorkspaceID == workspace.id ? 0.72 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Fork conversation") {
                controller.selectWorkspace(workspace)
                controller.forkSelectedWorkspace()
            }
            Button("Rename conversation") {
                controller.selectWorkspace(workspace)
                renameWorkspaceName = workspace.name
                showingRenameWorkspaceSheet = true
            }
            Divider()
            Button("Delete conversation", role: .destructive) {
                controller.selectWorkspace(workspace)
                showingDeleteWorkspaceAlert = true
            }
            .disabled(controller.workspaces.count <= 1)
        }
        .onDrag {
            draggedWorkspaceID = workspace.id
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text.identifier], isTargeted: nil) { _ in
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
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.72))

                Text(section.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.72))

                Spacer()

                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.56))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.06), lineWidth: 1)
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

            Picker("Model", selection: $newWorkspaceAgentID) {
                ForEach(controller.agents) { agent in
                    Text(agent.name).tag(agent.id)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    Text(newWorkspaceDirectoryURL?.path ?? "No folder selected")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.72))
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
                Button("Create") {
                    controller.createWorkspace(
                        named: newWorkspaceName,
                        agentID: newWorkspaceAgentID,
                        directoryURL: newWorkspaceDirectoryURL
                    )
                    showingAddWorkspaceSheet = false
                }
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
                Button("Save") {
                    controller.renameSelectedWorkspace(to: renameWorkspaceName)
                    showingRenameWorkspaceSheet = false
                }
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
            TextField("Search models", text: $modelSearchText)
                .textFieldStyle(.roundedBorder)

            if isLoadingModelPickerOptions {
                ProgressView("Loading models…")
                    .tint(.white)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredModelOptions, id: \.self) { model in
                        Button {
                            switch modelPickerTarget {
                            case .agentEditor:
                                newAgentModel = model
                            case .selectedConversationAgent:
                                controller.updateSelectedAgentModel(model)
                            }
                            showingModelPickerSheet = false
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                Spacer()
                                if selectedModelValue == model {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(CoworkPalette.mint)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingModelPickerSheet = false
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .preferredColorScheme(.dark)
    }

    private var agentCreationSheet: some View {
        let preset = selectedBackendPreset
        let editingAgent = editingAgent
        return VStack(alignment: .leading, spacing: 16) {
            Text(editingAgent == nil ? "Add agent" : "Edit agent")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(preset.setupHint)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            TextField("Agent name", text: $newAgentName)
                .textFieldStyle(.roundedBorder)

            Picker("Backend", selection: $newAgentBackendPresetID) {
                ForEach(controller.backendPresets, id: \.id) { backend in
                    Text(backend.displayName).tag(backend.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: newAgentBackendPresetID) {
                let updatedPreset = selectedBackendPreset
                newAgentProvider = updatedPreset.providerKind
                newAgentBaseURL = updatedPreset.defaultBaseURL
                if newAgentModel.isEmpty || presetSuggestedModels.contains(newAgentModel) {
                    newAgentModel = updatedPreset.suggestedModels.first ?? (updatedPreset.providerKind == .faeLocalhost ? "fae-agent-local" : "")
                }
                if !updatedPreset.requiresAPIKey {
                    newAgentAPIKey = ""
                    clearStoredAPIKey = false
                }
                discoveredModels = []
                agentTestStatus = nil
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(preset.providerKind == .openAICompatibleExternal ? "OpenAI-compatible" : preset.providerKind.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    TextField("Model identifier", text: $newAgentModel)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        modelPickerTarget = .agentEditor
                        modelSearchText = ""
                        isLoadingModelPickerOptions = true
                        browsableModelOptions = suggestedModels
                        showingModelPickerSheet = true
                        Task {
                            do {
                                let report = try await controller.testConnection(
                                    providerKind: preset.providerKind,
                                    baseURL: newAgentBaseURL,
                                    apiKey: effectiveAPIKeyForTesting
                                )
                                await MainActor.run {
                                    let merged = (suggestedModels + report.discoveredModels).reduce(into: [String]()) { result, item in
                                        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
                                        result.append(trimmed)
                                    }
                                    discoveredModels = report.discoveredModels
                                    browsableModelOptions = merged
                                    isLoadingModelPickerOptions = false
                                }
                            } catch {
                                await MainActor.run {
                                    isLoadingModelPickerOptions = false
                                }
                            }
                        }
                    }
                }
            }

            TextField(preset.allowsCustomBaseURL ? "Base URL" : "Base URL (fixed)", text: $newAgentBaseURL)
                .textFieldStyle(.roundedBorder)
                .disabled(!preset.allowsCustomBaseURL)

            if preset.requiresAPIKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preset.id == "openrouter" ? "OpenRouter API key" : "API key")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    SecureField(editingAgent == nil ? preset.apiKeyPlaceholder : "New API key (leave blank to keep current)", text: $newAgentAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text(preset.id == "openrouter"
                         ? "Paste your OpenRouter API key here so this conversation can call OpenRouter models. The key is stored securely in Keychain."
                         : "Stored securely in Keychain and only used for this agent/backend.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                    if let editingAgent, controller.hasStoredCredential(for: editingAgent) {
                        Toggle("Clear stored API key", isOn: $clearStoredAPIKey)
                    }
                }
            }

            if !suggestedModels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(discoveredModels.isEmpty ? "Suggested models" : "Suggested + discovered models")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestedModels, id: \.self) { model in
                                Button(model) {
                                    newAgentModel = model
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                                )
                            }
                        }
                    }
                }
            }

            if let agentTestStatus {
                Text(agentTestStatus)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Toggle(editingAgent == nil ? "Attach to current workspace" : "Attach updated agent to current workspace", isOn: $assignNewAgentToWorkspace)
            HStack {
                Button(isTestingAgentConnection ? "Testing…" : "Test connection") {
                    isTestingAgentConnection = true
                    agentTestStatus = nil
                    discoveredModels = []
                    Task {
                        do {
                            let report = try await controller.testConnection(
                                providerKind: preset.providerKind,
                                baseURL: newAgentBaseURL,
                                apiKey: effectiveAPIKeyForTesting
                            )
                            await MainActor.run {
                                isTestingAgentConnection = false
                                agentTestStatus = report.statusText
                                discoveredModels = report.discoveredModels
                                if newAgentModel.isEmpty, let first = report.discoveredModels.first {
                                    newAgentModel = first
                                }
                            }
                        } catch {
                            await MainActor.run {
                                isTestingAgentConnection = false
                                agentTestStatus = error.localizedDescription
                            }
                        }
                    }
                }
                .disabled(isTestingAgentConnection)

                Spacer()
                Button("Cancel") {
                    showingAddAgentSheet = false
                }
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
                    showingAddAgentSheet = false
                }
                .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
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
                .fill(Color.white.opacity(0.02))
                .background(
                    VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                )

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.045), lineWidth: 1)

            content()
                .padding(padding)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private func contextSectionLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.46))
        }
    }

    private func statusChip(icon: String, title: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(accent)
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func metricTile(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func quickPromptButton(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.60))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func quickSuggestionChip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func luxuryPromptCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CoworkPalette.heather)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
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
                        .foregroundStyle(.white)
                    Text("Additional power, kept out of the main conversation surface.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                Spacer()
                Button("Done") {
                    presentedUtilitySection = nil
                }
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
        .preferredColorScheme(.dark)
    }

    private var utilityMenuPill: some View {
        Menu {
            ForEach(CoworkWorkspaceSection.allCases.filter { $0 != .workspace }) { section in
                Button(section.title) {
                    presentedUtilitySection = section
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                Text("More")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.05))
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var agentPickerPill: some View {
        Menu {
            if let selectedWorkspace = controller.selectedWorkspace {
                ForEach(controller.agents) { agent in
                    Button(agent.name) {
                        controller.assignAgent(agent, to: selectedWorkspace)
                    }
                }
                Divider()
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
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                Text(controller.selectedAgent?.name ?? "Agent")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.05))
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var modelPickerPill: some View {
        Button {
            openModelPickerForSelectedAgent()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                Text(selectedAgentModelLabel ?? "Model")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.05))
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("Choose the model for this conversation. OpenRouter and other remote backends keep the same thread when you switch models.")
    }

    private func headerPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(0.82))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
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
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 1))
                )
        }
        .menuStyle(.borderlessButton)
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
                .foregroundStyle(.white)
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
                .foregroundStyle(.white)
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

    private var consensusSummaryStrip: some View {
        let successCount = controller.latestConsensusResults.filter { $0.errorText == nil }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fae consensus")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(controller.selectedConsensusParticipantsSummary)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
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
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
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
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(result.providerLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(2)
                }
                Spacer()
                capsule(
                    text: result.errorText == nil ? (result.isTrustedLocal ? "Local" : "Remote") : "Issue",
                    accent: result.errorText == nil ? (result.isTrustedLocal ? CoworkPalette.mint : CoworkPalette.cyan) : CoworkPalette.rose
                )
            }

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                if let responseText = result.responseText {
                    Text(responseText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.90))
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
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func conversationBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.role == .assistant {
                messageAccessory(role: .assistant, timestamp: message.timestamp)
                bubble(message.content, accent: CoworkPalette.heather, isTrailing: false)
                Spacer(minLength: 60)
            } else {
                Spacer(minLength: 60)
                bubble(message.content, accent: CoworkPalette.cyan, isTrailing: true)
                messageAccessory(role: .user, timestamp: message.timestamp)
            }
        }
    }

    private func streamingBubble(_ text: String) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            messageAccessory(role: .assistant, timestamp: Date(), showPulse: true)
            bubble(text, accent: CoworkPalette.heather, isTrailing: false, isStreaming: true)
            Spacer(minLength: 60)
        }
    }

    private func messageAccessory(role: ChatRole, timestamp: Date, showPulse: Bool = false) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(role == .assistant ? CoworkPalette.heather.opacity(0.9) : CoworkPalette.cyan.opacity(0.9))
                .frame(width: 8, height: 8)
                .overlay {
                    if showPulse {
                        Circle()
                            .stroke((role == .assistant ? CoworkPalette.heather : CoworkPalette.cyan).opacity(0.5), lineWidth: 1)
                            .scaleEffect(1.8)
                            .opacity(0.6)
                    }
                }
            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.38))
        }
        .frame(width: 42)
    }

    private func bubble(_ text: String, accent: Color, isTrailing: Bool, isStreaming: Bool = false) -> some View {
        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 8) {
            Text(isTrailing ? "You" : (isStreaming ? "Fae · live" : "Fae"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(accent.opacity(0.9))
                .textCase(.uppercase)

            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(isTrailing ? .trailing : .leading)
                .lineSpacing(3)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(accent.opacity(isStreaming ? 0.17 : 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accent.opacity(isStreaming ? 0.32 : 0.25), lineWidth: 1)
                )
        )
        .shadow(color: accent.opacity(isStreaming ? 0.16 : 0.08), radius: 12, y: 6)
        .frame(maxWidth: 620, alignment: isTrailing ? .trailing : .leading)
    }

    private func schedulerTaskCard(_ task: CoworkSchedulerTask) -> some View {
        glassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(task.scheduleDescription)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer()
                    capsule(text: task.isBuiltin ? "Built-in" : "Custom", accent: task.isBuiltin ? CoworkPalette.amber : CoworkPalette.cyan)
                }

                HStack(spacing: 10) {
                    schedulerMeta(label: "Next", value: relativeDate(task.nextRun))
                    schedulerMeta(label: "Last", value: relativeDate(task.lastRun))
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
                        .foregroundStyle(task.enabled ? CoworkPalette.mint : Color.white.opacity(0.52))

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
                            .fill(Color.white.opacity(0.05))
                            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
                }
            }
        }
    }

    private func schedulerMeta(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
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
                        .foregroundStyle(Color.white.opacity(0.52))
                    Text(value)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
    }

    private func miniWorkspaceStat(label: String, value: some CustomStringConvertible) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.40))
            Text(value.description)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
    }

    private func sidebarMiniSectionLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.48))
        }
    }

    private func sidebarSectionHeader(
        title: String,
        subtitle: String,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.86))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            Spacer()
            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func miniInfoBadge(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CoworkPalette.heather)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.76))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
        )
    }

    private func conversationControlPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CoworkPalette.heather)
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.04))
                .overlay(Capsule().stroke(Color.white.opacity(0.065), lineWidth: 1))
        )
    }

    private func heroDetailColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.38))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))
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
                .foregroundStyle(.white)
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
            .foregroundStyle(.white)
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

    private func activityAccent(_ tone: CoworkActivityItem.Tone) -> Color {
        switch tone {
        case .success: return CoworkPalette.mint
        case .warning: return CoworkPalette.rose
        case .neutral: return CoworkPalette.cyan
        }
    }

    private var selectedBackendPreset: CoworkBackendPreset {
        CoworkBackendPresetCatalog.preset(id: newAgentBackendPresetID) ?? CoworkLLMProviderKind.openAICompatibleExternal.defaultPreset
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
        guard let model = controller.selectedAgent?.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return nil
        }
        return model
    }

    private var selectedModelValue: String {
        switch modelPickerTarget {
        case .agentEditor:
            return newAgentModel
        case .selectedConversationAgent:
            return controller.selectedAgent?.modelIdentifier ?? ""
        }
    }

    private var presetSuggestedModels: [String] {
        selectedBackendPreset.suggestedModels
    }

    private var suggestedModels: [String] {
        var seen = Set<String>()
        return (presetSuggestedModels + discoveredModels).filter { seen.insert($0).inserted }
    }

    private var filteredModelOptions: [String] {
        let source = browsableModelOptions.isEmpty ? suggestedModels : browsableModelOptions
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func openModelPickerForSelectedAgent() {
        guard let selectedAgent = controller.selectedAgent else { return }
        modelPickerTarget = .selectedConversationAgent
        modelSearchText = ""
        isLoadingModelPickerOptions = true
        let preset = selectedAgent.backendPreset ?? selectedAgent.providerKind.defaultPreset
        browsableModelOptions = Array(([selectedAgent.modelIdentifier] + preset.suggestedModels).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).reduce(into: [String]()) { result, item in
            if !result.contains(item) {
                result.append(item)
            }
        }
        showingModelPickerSheet = true

        Task {
            do {
                let report = try await controller.testConnection(for: selectedAgent)
                await MainActor.run {
                    let discovered = report.discoveredModels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let merged = ([selectedAgent.modelIdentifier] + preset.suggestedModels + discovered).reduce(into: [String]()) { result, item in
                        if !result.contains(item) {
                            result.append(item)
                        }
                    }
                    browsableModelOptions = merged
                    isLoadingModelPickerOptions = false
                }
            } catch {
                await MainActor.run {
                    isLoadingModelPickerOptions = false
                }
            }
        }
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
        let model = agent.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return agent.backendDisplayName }
        return "\(agent.backendDisplayName) · \(model)"
    }

    private var snapshot: CoworkWorkspaceSnapshot { controller.snapshot }

    private var headerSubtitle: String {
        let user = snapshot.userName ?? "you"
        let workspaceName = controller.selectedWorkspace?.name ?? "this workspace"
        let agentName = controller.remoteAgentBlockedByPolicy ? "Fae Local" : (controller.selectedAgent?.name ?? "Fae Local")
        if faeCore.pipelineState == .running {
            if controller.isStrictLocalWorkspace {
                return "\(workspaceName) is in strict local mode for \(user). Fae keeps this workspace on-device, even if a remote agent is attached for later use."
            }
            return "\(workspaceName) is attached to \(agentName). Fae keeps watching over \(user)'s work locally, while workspace context, skills, and agent setup stay close at hand."
        }
        return "Fae is still starting. \(workspaceName) stays mounted so context and agent setup are ready when she is."
    }

    private var workspaceHeaderSummary: String {
        let agent = controller.remoteAgentBlockedByPolicy ? "Fae Local" : (controller.selectedAgent?.backendDisplayName ?? "Fae Local")
        if let path = controller.workspaceState.selectedDirectoryPath {
            return "\(agent) · \(path)"
        }
        return "\(agent) · no folder attached"
    }

    private var currentWorkspaceSubtitle: String {
        if let path = controller.workspaceState.selectedDirectoryPath {
            return path
        }
        if controller.selectedWorkspaceSetupState.isFreshWorkspace {
            return "Fresh workspace. Choose a folder or add a few files to make Fae's answers feel grounded right away."
        }
        if controller.remoteAgentBlockedByPolicy {
            return "Strict local only is active here. Remote agents stay attached but idle until you re-enable remote execution."
        }
        if let agent = controller.selectedAgent {
            return agent.isTrustedLocal ? "Trusted local agent with memory, tools, scheduler, and approvals." : "\(agent.backendDisplayName) · \(agent.notes ?? "Remote agent profile")"
        }
        return conversation.loadedModelLabel.isEmpty ? "Choose a folder or attach an agent to ground the workspace." : conversation.loadedModelLabel
    }

    private var latestAssistantExcerpt: String {
        if conversation.isStreaming, !conversation.streamingText.isEmpty {
            return conversation.streamingText
        }
        if let message = conversation.messages.last(where: { $0.role == .assistant }) {
            return message.content
        }
        return "No assistant reply yet."
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
