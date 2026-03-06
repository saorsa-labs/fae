import AppKit
import SwiftUI

private enum CoworkPalette {
    static let ink = Color(red: 0.05, green: 0.07, blue: 0.10)
    static let panel = Color.white.opacity(0.05)
    static let outline = Color.white.opacity(0.10)
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
        .preferredColorScheme(.dark)
        .onAppear {
            controller.scheduleRefresh(after: 0.05)
        }
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    CoworkPalette.ink,
                    Color(red: 0.08, green: 0.10, blue: 0.14),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.amber.opacity(0.30), .clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 460
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.cyan.opacity(0.22), .clear],
                center: .topTrailing,
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [CoworkPalette.rose.opacity(0.16), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cowork Desktop")
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
                                Text("Fae is live")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(conversation.loadedModelLabel.isEmpty ? "Loading model context..." : conversation.loadedModelLabel)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.62))
                                    .lineLimit(2)
                            }
                        }

                        HStack(spacing: 14) {
                            metricTile(title: "Messages", value: "\(conversation.messages.count)", accent: CoworkPalette.amber)
                            metricTile(title: "Tasks", value: "\(controller.schedulerTasks.filter(\.enabled).count)", accent: CoworkPalette.cyan)
                            metricTile(title: "Apple", value: "\(snapshot.appleTools.count)", accent: CoworkPalette.mint)
                        }
                    }
                }

                glassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Quick actions")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        quickPromptButton(
                            title: "Plan my day",
                            subtitle: "Use scheduler, memory, and Apple tools where helpful.",
                            action: {
                                controller.useQuickPrompt(
                                    "Please help me plan today using my memories, existing commitments, and any relevant scheduler tasks. Keep it concise and actionable."
                                )
                            }
                        )

                        quickPromptButton(
                            title: "Review skills",
                            subtitle: "Audit active skills and suggest anything stale or missing.",
                            action: {
                                controller.useQuickPrompt(
                                    "Audit your active skills, explain what they are doing for me now, and point out anything stale or worth improving."
                                )
                            }
                        )
                    }
                }
            }
            .frame(height: 220)

            workspaceConversationPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        Text("A native Swift workspace shaped after AionUi's left rail and conversation core, but bound directly to Fae's live runtime.")
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
                        TextField(
                            "Ask Fae to coordinate work, run a scheduler task, or use one of her skills...",
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
            Text("This workspace is ready for desktop coworking.")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Use it as a command center for conversations, scheduler runs, skills, and Apple integrations. Additional model bays are reserved for the next issue.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.68))

            HStack(spacing: 10) {
                quickSuggestionChip("Morning briefing") {
                    controller.useQuickPrompt("Give me a morning briefing using memory, current context, and any useful scheduler tasks.")
                }
                quickSuggestionChip("Inbox triage") {
                    controller.useQuickPrompt("Help me triage my inbox and summarize anything urgent.")
                }
                quickSuggestionChip("Skill review") {
                    controller.useQuickPrompt("Explain which skills are active and how I should use them in this session.")
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
                    Text("Apple lane")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("These tools stay visible here because the cowork desktop is meant to feel native on macOS, not like a generic web shell.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))

                    if snapshot.appleTools.isEmpty {
                        Text("Apple integrations are unavailable in the current tool mode.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.52))
                    } else {
                        ForEach(snapshot.appleTools) { tool in
                            capsule(text: tool.displayName, accent: CoworkPalette.cyan)
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
                        Text("Fae Cowork")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Native macOS desk")
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

                VStack(alignment: .leading, spacing: 12) {
                    Text("Model bays")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.86))

                    glassCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Fae Core")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                Spacer()
                                capsule(text: "Live", accent: CoworkPalette.mint)
                            }

                            Text("Additional model slots are intentionally held for phase two so this first pass stays tightly bound to Fae.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.58))
                        }
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick control")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.86))

                    quickActionPill(title: "Skill health", action: { controller.runTask(id: "skill_health_check") })
                    quickActionPill(title: "Open settings", action: controller.openSettings)
                }
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
        let user = snapshot.userName ?? "your day"
        if faeCore.pipelineState == .running {
            return "Fae is ready to cowork with \(user), using her live skills, tools, and scheduler."
        }
        return "Fae is still starting. The desktop stays mounted so the workspace can come online without shifting context."
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
