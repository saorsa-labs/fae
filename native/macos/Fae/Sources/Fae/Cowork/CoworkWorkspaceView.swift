import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum CoworkPalette {
    static let ink = Color.black.opacity(0.16)
    static let panel = Color.white.opacity(0.05)
    static let outline = Color.white.opacity(0.10)
    static let heather = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)
    static let amber = Color(red: 0.92, green: 0.72, blue: 0.28)
    static let cyan = Color(red: 0.42, green: 0.82, blue: 0.92)
    static let rose = Color(red: 0.86, green: 0.52, blue: 0.65)
    static let mint = Color(red: 0.52, green: 0.88, blue: 0.75)
}

private enum CoworkArtwork {
    static let orb = FaeApp.renderStaticOrb()
}

struct CoworkWorkspaceView: View {
    @ObservedObject var controller: CoworkWorkspaceController
    @ObservedObject var faeCore: FaeCore
    @ObservedObject var conversation: ConversationController

    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            backdrop

            HStack(spacing: 18) {
                sidebar
                    .frame(width: 236)

                VStack(spacing: 18) {
                    header
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                inspector
                    .frame(width: 320)
            }
            .padding(22)
        }
        .background(
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
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
    }

    private var backdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .padding(10)
                .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.heather.opacity(0.16), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 380
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.amber.opacity(0.12), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 320
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Work with Fae")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(headerSubtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.70))

                HStack(spacing: 10) {
                    statusChip(
                        icon: faeCore.pipelineState == .running ? "waveform.badge.mic" : "bolt.horizontal.circle",
                        title: snapshot.pipelineStateLabel,
                        accent: faeCore.pipelineState == .running ? CoworkPalette.mint : CoworkPalette.amber
                    )

                    statusChip(
                        icon: "slider.horizontal.3",
                        title: "Tools \(snapshot.toolMode.replacingOccurrences(of: "_", with: " "))",
                        accent: CoworkPalette.cyan
                    )

                    statusChip(
                        icon: snapshot.thinkingEnabled ? "brain.filled.head.profile" : "brain.head.profile",
                        title: snapshot.thinkingEnabled ? "Thinking on" : "Thinking off",
                        accent: CoworkPalette.rose
                    )

                    statusChip(
                        icon: "sparkles",
                        title: "\(snapshot.activeSkills.count) active skills",
                        accent: CoworkPalette.amber
                    )

                    statusChip(
                        icon: "network",
                        title: controller.providerKind == .faeLocalhost ? "Fae localhost" : "External provider",
                        accent: controller.providerStatus.contains("fallback") ? CoworkPalette.rose : CoworkPalette.heather
                    )
                }
            }

            Spacer()

            HStack(spacing: 10) {
                workspaceActionButton(
                    title: faeCore.thinkingEnabled ? "Thinking on" : "Thinking off",
                    systemImage: faeCore.thinkingEnabled ? "brain.filled.head.profile" : "brain.head.profile",
                    accent: CoworkPalette.rose,
                    action: controller.toggleThinking
                )

                workspaceActionButton(
                    title: controller.isRefreshing ? "Refreshing" : "Refresh",
                    systemImage: "arrow.clockwise",
                    accent: CoworkPalette.cyan,
                    action: { controller.refreshNow() }
                )

                workspaceActionButton(
                    title: "Settings",
                    systemImage: "gearshape.fill",
                    accent: CoworkPalette.amber,
                    action: controller.openSettings
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.selectedSection {
        case .workspace:
            workspaceSection
        case .scheduler:
            schedulerSection
        case .skills:
            skillsSection
        case .tools:
            toolsSection
        }
    }

    private var workspaceSection: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                glassCard {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            Image(nsImage: CoworkArtwork.orb)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Workspace context")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(currentWorkspaceSubtitle)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.62))
                                    .lineLimit(2)
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

                glassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Add context")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        quickPromptButton(
                            title: "Add files",
                            subtitle: "+ button behaviour — open Finder and attach docs, code, or images.",
                            action: controller.addAttachmentsViaPicker
                        )

                        quickPromptButton(
                            title: "Paste clipboard",
                            subtitle: "Paste text, copied files, or copied images into this workspace.",
                            action: controller.addPastedContent
                        )

                        quickPromptButton(
                            title: "Look at screen",
                            subtitle: "Tell Fae to inspect what is currently visible.",
                            action: controller.inspectScreen
                        )
                    }
                }
            }
            .frame(height: 260)

            HStack(alignment: .top, spacing: 18) {
                workspaceContextPanel
                    .frame(width: 360)

                workspaceConversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workspaceContextPanel: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Folder grounding, attached files, drag-and-drop, and pasted context all live here.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Current folder")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.60))

                    if let path = controller.workspaceState.selectedDirectoryPath {
                        Text(path)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    } else {
                        Text("No folder selected yet")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Attached items")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            controller.addAttachmentsViaPicker()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }

                    if controller.workspaceState.attachments.isEmpty {
                        Text("Drop files here, click + to add them, or paste from the clipboard.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(controller.workspaceState.attachments) { attachment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: attachment.kind == .image ? "photo" : (attachment.kind == .text ? "doc.text" : "paperclip"))
                                            .foregroundStyle(CoworkPalette.heather)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(attachment.displayName)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundStyle(.white)
                                                .lineLimit(2)
                                            if let path = attachment.path {
                                                Text(path)
                                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(Color.white.opacity(0.45))
                                                    .lineLimit(2)
                                            } else if let inlineText = attachment.inlineText {
                                                Text(String(inlineText.prefix(140)))
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(Color.white.opacity(0.55))
                                                    .lineLimit(3)
                                            }
                                        }
                                        Spacer()
                                        Button {
                                            controller.removeAttachment(id: attachment.id)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .bold))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.white.opacity(0.5))
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(controller.selectedAttachment?.id == attachment.id ? CoworkPalette.heather.opacity(0.18) : Color.white.opacity(0.04))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(controller.selectedAttachment?.id == attachment.id ? CoworkPalette.heather.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture {
                                        controller.selectAttachment(attachment)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Indexed files")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(controller.filteredWorkspaceFiles.count)/\(controller.workspaceState.indexedFiles.count)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }

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
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )

                    if controller.workspaceState.indexedFiles.isEmpty {
                        Text("Select a folder to let Fae ground her answers in code, docs, and local project files.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(controller.filteredWorkspaceFiles.prefix(80)) { file in
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
                                                    .foregroundStyle(Color.white.opacity(0.45))
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(controller.selectedWorkspaceFile?.id == file.id ? CoworkPalette.heather.opacity(0.18) : Color.clear)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }

                if let focusedPreview = controller.focusedPreview {
                    Divider().overlay(Color.white.opacity(0.08))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Focused preview")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(focusedPreview.subtitle ?? focusedPreview.kind.capitalized)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }

                        Text(focusedPreview.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)

                        if let path = focusedPreview.path {
                            Text(path)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.45))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }

                        if focusedPreview.kind == "image", let path = focusedPreview.path,
                           let image = NSImage(contentsOf: URL(fileURLWithPath: path))
                        {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else if let textPreview = focusedPreview.textPreview, !textPreview.isEmpty {
                            ScrollView {
                                Text(textPreview)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.78))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 180)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                        } else {
                            Text("Preview is not available for this file type yet, but Fae still knows it is part of the workspace.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                }
            }
        }
    }

    private var workspaceConversationPanel: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live conversation")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Use the folder, attachments, pasted items, and vision actions around this chat to ground Fae in the work you are doing.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer()
                    if conversation.isGenerating {
                        Label("Generating", systemImage: "ellipsis.message.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(CoworkPalette.cyan.opacity(0.18)))
                            .overlay(Capsule().stroke(CoworkPalette.cyan.opacity(0.40), lineWidth: 1))
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if conversation.messages.isEmpty && conversation.streamingText.isEmpty {
                                emptyConversationState
                            } else {
                                ForEach(Array(conversation.messages.suffix(40))) { message in
                                    conversationBubble(message)
                                }

                                if conversation.isStreaming, !conversation.streamingText.isEmpty {
                                    streamingBubble(conversation.streamingText)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("cowork-bottom")
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .onAppear {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                    .onChange(of: conversation.messages.count) {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                    .onChange(of: conversation.streamingText) {
                        proxy.scrollTo("cowork-bottom", anchor: .bottom)
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Ask Fae")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.80))

                        Spacer()

                        Button(action: controller.toggleThinking) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(faeCore.thinkingEnabled ? CoworkPalette.mint : CoworkPalette.rose)
                                    .frame(width: 8, height: 8)
                                Text("Thinking")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(faeCore.thinkingEnabled ? "On" : "Off")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.68))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(faeCore.thinkingEnabled ? "Turn thinking off for faster replies." : "Turn thinking on for deeper reasoning.")
                    }

                    HStack(alignment: .bottom, spacing: 12) {
                        HStack(spacing: 8) {
                            iconActionButton(symbol: "plus") {
                                controller.addAttachmentsViaPicker()
                            }
                            iconActionButton(symbol: "doc.on.clipboard") {
                                controller.addPastedContent()
                            }
                            iconActionButton(symbol: "camera") {
                                controller.inspectCamera()
                            }
                            iconActionButton(symbol: "rectangle.on.rectangle") {
                                controller.inspectScreen()
                            }
                        }

                        TextField(
                            "Ask Fae to work with this folder, these files, or what you want her to inspect…",
                            text: $controller.draft,
                            axis: .vertical
                        )
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )

                        Button(action: controller.submitDraft) {
                            Label("Send", systemImage: "paperplane.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [CoworkPalette.amber, CoworkPalette.rose],
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

    private var emptyConversationState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start by choosing a folder or adding a few files.")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Work with Fae is designed to keep local project context close at hand. Select a workspace, drop files or images, paste something in, or ask Fae to look at your screen.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.68))

            HStack(spacing: 10) {
                quickSuggestionChip("Summarize this workspace") {
                    controller.useQuickPrompt("Summarize this workspace and tell me where I should start.")
                }
                quickSuggestionChip("Find key files") {
                    controller.useQuickPrompt("Given this workspace context, identify the most important files for the task at hand.")
                }
                quickSuggestionChip("Look at my screen") {
                    controller.inspectScreen()
                }
            }
        }
        .padding(.vertical, 12)
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
        glassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: CoworkArtwork.orb)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Work with Fae")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Local workspace")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                }

                VStack(spacing: 10) {
                    ForEach(CoworkWorkspaceSection.allCases) { section in
                        sidebarButton(for: section)
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick controls")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.86))

                    quickActionPill(title: "Choose folder", action: controller.chooseWorkspaceDirectory)
                    quickActionPill(title: "Add files", action: controller.addAttachmentsViaPicker)
                    quickActionPill(title: "Look at screen", action: controller.inspectScreen)
                    quickActionPill(title: "Open settings", action: controller.openSettings)
                }

                Spacer()
            }
        }
    }

    private func sidebarButton(for section: CoworkWorkspaceSection) -> some View {
        let isSelected = controller.selectedSection == section
        let count = sidebarCount(for: section)

        return Button {
            controller.selectedSection = section
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
        }
        .buttonStyle(.plain)
    }

    private func glassCard<Content: View>(
        padding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(CoworkPalette.panel)
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(CoworkPalette.outline, lineWidth: 1)

            content()
                .padding(padding)
        }
        .shadow(color: .black.opacity(0.22), radius: 26, y: 16)
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

    private func iconActionButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
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

    private func conversationBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .assistant {
                bubble(message.content, accent: CoworkPalette.amber, isTrailing: false)
                Spacer(minLength: 50)
            } else {
                Spacer(minLength: 50)
                bubble(message.content, accent: CoworkPalette.cyan, isTrailing: true)
            }
        }
    }

    private func streamingBubble(_ text: String) -> some View {
        HStack {
            bubble(text, accent: CoworkPalette.mint, isTrailing: false)
            Spacer(minLength: 50)
        }
    }

    private func bubble(_ text: String, accent: Color, isTrailing: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(isTrailing ? .trailing : .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(accent.opacity(0.25), lineWidth: 1)
                    )
            )
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

    private func quickActionPill(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
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

    private var snapshot: CoworkWorkspaceSnapshot { controller.snapshot }

    private var headerSubtitle: String {
        let user = snapshot.userName ?? "you"
        if faeCore.pipelineState == .running {
            return "Fae is ready to work with \(user), grounded in your folder, files, pasted context, and live tools."
        }
        return "Fae is still starting. Your workspace can stay mounted so context is ready when she is."
    }

    private var currentWorkspaceSubtitle: String {
        if let path = controller.workspaceState.selectedDirectoryPath {
            return path
        }
        return conversation.loadedModelLabel.isEmpty ? "Choose a folder or add files to ground Fae in what you are working on." : conversation.loadedModelLabel
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
