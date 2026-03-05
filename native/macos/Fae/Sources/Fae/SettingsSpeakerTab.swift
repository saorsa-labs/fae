import SwiftUI

/// Settings tab for managing voice identity and speaker profiles.
struct SettingsSpeakerTab: View {
    var commandSender: HostCommandSender?

    @State private var voiceIdentityEnabled: Bool = false
    @State private var voiceIdentityMode: String = "assist"
    @State private var approvalRequiresMatch: Bool = false
    @State private var ownerName: String = ""
    @State private var ownerEnrollmentCount: Int = 0
    @State private var ownerLastSeen: Date?
    @State private var hasOwner: Bool = false
    @State private var showTestResult: Bool = false
    @State private var testResultText: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        Form {
            ownerSection
            identitySection
            futureSection
        }
        .formStyle(.grouped)
        .onAppear { loadState() }
    }

    // MARK: - Owner Profile

    private var ownerSection: some View {
        Section("Owner Voice Profile") {
            if hasOwner {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if isEditing {
                            TextField("Display name", text: $ownerName, onCommit: {
                                renameOwner()
                                isEditing = false
                            })
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        } else {
                            Text(ownerName)
                                .font(.headline)
                        }

                        HStack(spacing: 12) {
                            Label("\(ownerEnrollmentCount) samples", systemImage: "waveform")
                            if let lastSeen = ownerLastSeen {
                                Label(lastSeen.formatted(.relative(presentation: .named)),
                                      systemImage: "clock")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(spacing: 8) {
                        Button(isEditing ? "Save" : "Rename") {
                            if isEditing {
                                renameOwner()
                            }
                            isEditing.toggle()
                        }
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Button("Test Voice Match") {
                        commandSender?.sendCommand(name: "speaker.test", payload: [:])
                    }
                    .controlSize(.small)

                    Button("Re-enroll") {
                        commandSender?.sendCommand(name: "speaker.start_enrollment", payload: [:])
                    }
                    .controlSize(.small)
                }

                if showTestResult {
                    Text(testResultText)
                        .font(.caption)
                        .foregroundStyle(testResultText.contains("Match") ? .green : .orange)
                        .transition(.opacity)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No owner voice enrolled")
                        .foregroundStyle(.secondary)
                    Button("Enroll Now") {
                        commandSender?.sendCommand(name: "speaker.start_enrollment", payload: [:])
                    }
                }
            }
        }
    }

    // MARK: - Voice Identity Settings

    private var identitySection: some View {
        Section("Voice Identity") {
            Toggle("Enabled", isOn: $voiceIdentityEnabled)
                .onChange(of: voiceIdentityEnabled) { _, newValue in
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "voice_identity.enabled", "value": newValue]
                    )
                }

            if voiceIdentityEnabled {
                Picker("Mode", selection: $voiceIdentityMode) {
                    Text("Assist").tag("assist")
                    Text("Enforce").tag("enforce")
                }
                .onChange(of: voiceIdentityMode) { _, newValue in
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "voice_identity.mode", "value": newValue]
                    )
                }

                Toggle("Tool approval requires voice match", isOn: $approvalRequiresMatch)
                    .onChange(of: approvalRequiresMatch) { _, newValue in
                        commandSender?.sendCommand(
                            name: "config.patch",
                            payload: ["key": "voice_identity.approval_requires_match", "value": newValue]
                        )
                    }

                if voiceIdentityMode == "assist" {
                    Text("Fae keeps normal conversation to the owner and trusted speakers. Assist mode mainly affects voice step-up checks for tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Fae keeps normal conversation to the owner and trusted speakers, and enforce mode adds stricter live-voice checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Future

    private var futureSection: some View {
        Section("Family & Friends") {
            Text("Ask Fae to meet someone to enroll them as a trusted speaker.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Actions

    private func loadState() {
        // Read voice identity config directly from FaeConfig.
        let config = FaeConfig.load()
        voiceIdentityEnabled = config.voiceIdentity.enabled
        voiceIdentityMode = config.voiceIdentity.mode
        approvalRequiresMatch = config.voiceIdentity.approvalRequiresMatch

        // Read speaker profiles from SpeakerProfileStore (local instance to same file).
        Task {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            let storePath = appSupport.appendingPathComponent("fae/speakers.json")
            let store = SpeakerProfileStore(storePath: storePath)
            let summaries = await store.profileSummaries()
            if let ownerSummary = summaries.first(where: { $0.role == .owner }) {
                hasOwner = true
                ownerName = ownerSummary.displayName
                ownerEnrollmentCount = ownerSummary.enrollmentCount
                ownerLastSeen = ownerSummary.lastSeen
            }
        }
    }

    private func renameOwner() {
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandSender?.sendCommand(
            name: "speaker.rename",
            payload: ["label": "owner", "displayName": trimmed]
        )
    }
}
