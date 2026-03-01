import SwiftUI

/// Two-step workflow for importing memories from another AI assistant.
///
/// Step 1: Copy the export prompt to paste into ChatGPT, Gemini, etc.
/// Step 2: Paste the response and send it to Fae for memory extraction.
struct MemoryImportWindowView: View {

    let conversation: ConversationController
    let auxiliaryWindows: AuxiliaryWindowManager
    let dismissAction: () -> Void

    @State private var pastedText: String = ""
    @State private var promptCopied: Bool = false

    /// Heather accent colour — matches InputBarView.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    // MARK: - Prompts

    private static let exportPrompt = """
        I'm moving to another service and need to export my data. List every memory you \
        have stored about me, as well as any context you've learned about me from past \
        conversations. Output everything in a single code block so I can easily copy it.

        Format each entry as: [date saved, if available] - memory content.

        Make sure to cover all of the following — preserve my words verbatim where possible:
        - Instructions I've given you about how to respond (tone, format, style, \
        'always do X', 'never do Y').
        - Personal details: name, location, job, family, interests.
        - Projects, goals, and recurring topics.
        - Tools, languages, and frameworks I use.
        - Preferences and corrections I've made to your behavior.
        - Any other stored context not covered above. Do not summarize, group, or omit \
        any entries.

        After the code block, confirm whether that is the complete set or if any remain.
        """

    private static let instructionPrefix = """
        I'm importing my memories from another AI assistant. Below is everything they had \
        stored about me. Please read through all of it carefully and remember every detail \
        — my name, preferences, interests, projects, relationships, instructions, and \
        anything else mentioned. Don't summarize or skip anything. After reading, confirm \
        what you've learned.

        ---

        """

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stepOneSection
                    Divider()
                    stepTwoSection
                }
                .padding(24)
            }

            Divider()
            actionBar
        }
        .frame(minWidth: 460, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Step 1

    private var stepOneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Copy the Export Prompt", systemImage: "1.circle.fill")
                .font(.system(size: 14, weight: .semibold))

            Text("Paste this into ChatGPT, Gemini, or any other AI assistant to export your memories.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text(Self.exportPrompt)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            Button(action: copyPrompt) {
                HStack(spacing: 5) {
                    Image(systemName: promptCopied ? "checkmark" : "doc.on.doc")
                    Text(promptCopied ? "Copied" : "Copy Prompt")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(promptCopied ? .green : Self.heather)
        }
    }

    // MARK: - Step 2

    private var stepTwoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Paste the Response", systemImage: "2.circle.fill")
                .font(.system(size: 14, weight: .semibold))

            Text("Paste the exported memories below, then send them to Fae.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            TextEditor(text: $pastedText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
                Button(action: pasteFromClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: "clipboard")
                        Text("Paste from Clipboard")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("\(pastedText.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if pastedText.count > 30_000 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Large import — Fae may need multiple conversations to absorb everything.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button("Cancel") {
                dismissAction()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: sendToFae) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text("Send to Fae")
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.heather)
            .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.exportPrompt, forType: .string)
        promptCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            promptCopied = false
        }
    }

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            pastedText = string
        }
    }

    private func sendToFae() {
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fullMessage = Self.instructionPrefix + trimmed
        conversation.handleUserSent(fullMessage)
        auxiliaryWindows.showConversation()
        dismissAction()
    }
}
