import AVFoundation
import AppKit
import CryptoKit
import Foundation
import MLXLMCommon

/// Central voice pipeline: AudioCapture → VAD → STT → LLM → TTS → Playback.
///
/// Wires all pipeline stages together with echo suppression, barge-in,
/// gate/sleep system, inline tool execution, and text injection.
///
/// Replaces: `src/pipeline/coordinator.rs` (5,192 lines)
actor PipelineCoordinator {
    enum DeterministicEasyTurnAction: Equatable {
        case arithmetic(reply: String)
        case rememberUserName(name: String, reply: String)
        case recallUserName(reply: String)
    }

    // MARK: - Pipeline Mode

    enum PipelineMode: String, Sendable {
        case conversation     // Full pipeline
        case transcribeOnly   // Capture → VAD → STT → print
        case textOnly         // Text injection → LLM → TTS → playback
        case llmOnly          // Capture → VAD → STT → LLM (no TTS)
    }

    // MARK: - Degraded Mode

    enum PipelineDegradedMode: String, Sendable {
        case full
        case noSTT
        case noLLM
        case noTTS
        case unavailable
    }

    // MARK: - Gate State

    enum GateState: Sendable {
        case idle     // Discard all transcriptions
        case active   // Forward to LLM
    }

    // MARK: - Dependencies

    private let eventBus: FaeEventBus
    private let capture: AudioCaptureManager
    private let playback: AudioPlaybackManager
    private let sttEngine: MLXSTTEngine
    private let llmEngine: any LLMEngine
    private let conciergeEngine: (any LLMEngine)?
    private let ttsEngine: any TTSEngine
    private let config: FaeConfig
    private let conversationState: ConversationStateTracker
    private let memoryOrchestrator: MemoryOrchestrator?
    private let sessionStore: SessionStore?
    private let workflowTraceStore: WorkflowTraceStore?
    private let approvalManager: ApprovalManager?
    private let registry: ToolRegistry
    private let actionBroker: any TrustedActionBroker
    private let damageControlPolicy = DamageControlPolicy()
    private var modelLocality: ModelLocality = .local
    private let rateLimiter = ToolRateLimiter()
    private let securityLogger = SecurityEventLogger.shared
    private let outboundGuard = OutboundExfiltrationGuard.shared
    private let speakerEncoder: CoreMLSpeakerEncoder?
    private let speakerProfileStore: SpeakerProfileStore?
    private let wakeWordProfileStore: WakeWordProfileStore?
    private let skillManager: SkillManager?
    private let toolAnalytics: ToolAnalytics?
    private let modelManager: ModelManager?
    private let isRescueMode: Bool

    /// Counter for computer-use action steps per conversation turn (click/type/scroll).
    private var computerUseStepCount: Int = 0
    private static let maxComputerUseSteps = 10


    // MARK: - Debug Console

    /// Optional debug console for real-time pipeline visibility.
    /// Set after init via `setDebugConsole(_:)`.
    private var debugConsole: DebugConsoleController?

    /// Wire up the debug console after initialization.
    func setDebugConsole(_ console: DebugConsoleController?) {
        debugConsole = console
    }

    // MARK: - Live Config Overrides

    /// Live override for reasoning depth — set by FaeCore when the user changes the level.
    /// `nil` means fall back to `config.llm.resolvedThinkingLevel`.
    private var thinkingLevelLive: FaeThinkingLevel?

    /// Update the reasoning depth without restarting the pipeline.
    func setThinkingLevel(_ level: FaeThinkingLevel) {
        thinkingLevelLive = level
    }

    /// Legacy compatibility hook for older call sites.
    func setThinkingEnabled(_ enabled: Bool) {
        thinkingLevelLive = enabled ? .balanced : .fast
    }

    /// Live override for barge-in — set by FaeCore when the user toggles the setting.
    /// `nil` means fall back to `config.bargeIn.enabled`.
    private var bargeInEnabledLive: Bool?

    /// Update the barge-in flag without restarting the pipeline.
    func setBargeInEnabled(_ enabled: Bool) {
        bargeInEnabledLive = enabled
    }

    /// Mute or unmute the microphone capture in response to the UI mic button.
    ///
    /// Sets `AudioCaptureManager.isMuted` so incoming chunks are dropped before
    /// reaching the VAD/STT pipeline. This is a live toggle — no pipeline restart needed.
    func setMicMuted(_ muted: Bool) async {
        await capture.setMuted(muted)
        NSLog("PipelineCoordinator: mic %@", muted ? "muted" : "unmuted")
    }

    /// Live override for tool mode — set by FaeCore when the user changes tool settings.
    /// `nil` means fall back to `config.toolMode`.
    private var toolModeLive: String?

    /// Live override for privacy mode.
    private var privacyModeLive: String?

    /// Update the tool mode without restarting the pipeline.
    func setToolMode(_ mode: String) {
        if isRescueMode {
            toolModeLive = "read_only"
            return
        }
        toolModeLive = mode
        // Dismiss any pending tool-mode upgrade popup.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .faeToolModeUpgradeDismiss, object: nil)
        }
    }

    func setPrivacyMode(_ mode: String) {
        privacyModeLive = mode
    }

    static func shouldRecallMemoryForTurn(
        firstOwnerEnrollmentActive: Bool,
        userText: String,
        availableToolNames: [String]
    ) -> Bool {
        guard !firstOwnerEnrollmentActive else { return false }
        return !shouldSuppressEpisodeRecallForToolSensitiveTurn(
            userText: userText,
            availableToolNames: availableToolNames
        )
    }

    static func memoryTurnGuidance(for userText: String) -> String? {
        var normalizedUserText = userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = normalizedUserText.lowercased()

        for prefix in ["fae, ", "fae "] where lower.hasPrefix(prefix) {
            lower = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedUserText = String(normalizedUserText.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        let memoryCapturePrefixes = [
            "remember ",
            "please remember ",
            "my name is ",
            "call me ",
            "i'm called ",
            "i am called ",
            "i'm named ",
            "i am named ",
            "my sister ",
        ]
        let memoryCaptureContains = [
            "works at ",
            "i'm really interested in ",
            "i find ",
            "i love learning about ",
            "i need to ",
            "i have a deadline ",
            "remind me i have to ",
        ]

        if let interestTopic = explicitInterestTopic(in: normalizedUserText, lower: lower) {
            return "Memory capture guidance: The user is giving durable personal context about an interest in \(interestTopic). Acknowledge \(interestTopic) explicitly and briefly."
        }

        if memoryCapturePrefixes.contains(where: { lower.hasPrefix($0) })
            || memoryCaptureContains.contains(where: { lower.contains($0) })
        {
            return "Memory capture guidance: The user is giving durable personal context. Acknowledge the exact fact, person, or name briefly and plainly."
        }

        let personalRecallPhrases = [
            "what's my ",
            "what is my ",
            "do you know my ",
            "do you remember my ",
            "what color do i like",
            "what do you call me",
            "do you know who i am",
            "who works at ",
            "who do i know at ",
            "do you know anyone who works at ",
            "tell me about people who work at ",
            "what have you learned recently",
            "what stands out from memory lately",
            "imported notes",
        ]

        if personalRecallPhrases.contains(where: { lower.contains($0) })
            || PersonQueryDetector.detectPersonQuery(in: userText) != nil
        {
            return "Memory reply guidance: Answer directly from memory context. If the fact is missing, say that plainly. Do not improvise or switch topics."
        }

        return nil
    }

    private static func explicitInterestTopic(in userText: String, lower: String) -> String? {
        let anchoredPrefixes = [
            "i'm really interested in ",
            "i am really interested in ",
            "i'm interested in ",
            "i am interested in ",
            "i love learning about ",
        ]

        for prefix in anchoredPrefixes where lower.hasPrefix(prefix) {
            let topic = String(userText.dropFirst(prefix.count))
            return cleanInterestTopic(topic)
        }

        let fascinatingSuffix = " fascinating"
        if let start = lower.range(of: "i find "),
           let end = lower.range(of: fascinatingSuffix, range: start.upperBound..<lower.endIndex)
        {
            let lowerPrefixCount = lower.distance(from: lower.startIndex, to: start.upperBound)
            let lowerUpperCount = lower.distance(from: lower.startIndex, to: end.lowerBound)
            let topicStart = userText.index(userText.startIndex, offsetBy: lowerPrefixCount)
            let topicEnd = userText.index(userText.startIndex, offsetBy: lowerUpperCount)
            let topic = String(userText[topicStart..<topicEnd])
            return cleanInterestTopic(topic)
        }

        return nil
    }

    private static func cleanInterestTopic(_ topic: String) -> String? {
        let cleaned = topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func visibleToolNamesForTurn(
        firstOwnerEnrollmentActive: Bool,
        userText: String,
        availableToolNames: [String],
        proactiveAllowedTools: Set<String>?
    ) -> Set<String>? {
        if firstOwnerEnrollmentActive {
            return ["voice_identity"]
        }
        let explicitMentions = explicitlyMentionedToolNames(
            in: userText,
            availableToolNames: availableToolNames
        )
        let inferredMentions = explicitMentions.isEmpty
            ? inferredToolNamesForTurn(in: userText, availableToolNames: availableToolNames)
            : []
        let requestedTools = explicitMentions.isEmpty ? inferredMentions : explicitMentions
        switch (proactiveAllowedTools, requestedTools.isEmpty) {
        case let (allowed?, false):
            let narrowed = allowed.intersection(requestedTools)
            return narrowed.isEmpty ? allowed : narrowed
        case let (allowed?, true):
            return allowed
        case (nil, false):
            return requestedTools
        case (nil, true):
            return nil
        }
    }

    static func explicitlyMentionedToolNames(
        in userText: String,
        availableToolNames: [String]
    ) -> Set<String> {
        let normalized = " " + userText.lowercased() + " "
        var matches: Set<String> = []

        for toolName in availableToolNames {
            for alias in toolNameAliases(toolName) {
                guard !alias.isEmpty else { continue }
                if normalized.contains(" \(alias) ") {
                    matches.insert(toolName)
                    break
                }
            }
        }

        return matches
    }

    static func inferredToolNamesForTurn(
        in userText: String,
        availableToolNames: [String]
    ) -> Set<String> {
        let lower = userText.lowercased()
        let available = Set(availableToolNames)
        var matches: Set<String> = []

        func add(_ names: String...) {
            for name in names where available.contains(name) {
                matches.insert(name)
            }
        }

        func containsAny(_ terms: [String]) -> Bool {
            terms.contains { lower.contains($0) }
        }

        if containsAny([
            "what did we say about", "what did we decide about", "earlier conversation",
            "earlier chat", "previous conversation", "previous chat", "search our conversation",
            "search our conversations", "search the conversation", "search the transcript",
            "look through our chat", "find in our chat", "find in previous chats",
            "session search", "session_search",
        ]) {
            add("session_search")
        }

        if containsAny([
            "search the web", "search web", "look up", "look something up",
            "latest news", "news about", "headline", "search online", "find online"
        ]) || isToolBackedLookupRequest(userText) {
            add("web_search", "fetch_url", "read")
        }

        if containsAny([
            "read ", "open ", "summarize ", "this file", "that file",
            ".md", ".txt", ".json", ".swift", ".py", ".toml", "/users/", "~/", "/tmp/"
        ]) {
            add("read")
        }

        if containsAny([
            "write ", "create file", "save ", "edit ", "modify ", "rewrite ",
            "patch ", "update this file", "change this file"
        ]) {
            add("write", "edit", "read")
        }

        if containsAny([
            "terminal", "shell", "bash", "command line", "run command",
            "execute ", "git ", "npm ", "pnpm ", "cargo ", "swift build", "just "
        ]) {
            add("bash", "read", "write", "edit")
        }

        if containsAny([
            "calendar", "schedule", "meeting", "appointment", "today", "tomorrow",
            "free time", "availability", "busy"
        ]) {
            add("calendar")
        }

        if containsAny(["remind me", "reminder", "todo", "to-do", "task list", "tasks"]) {
            add("reminders")
        }

        if containsAny(["contact", "phone number", "email address"]) {
            add("contacts")
        }

        if containsAny(["send email", "draft email", "compose email", "mail "]) {
            add("mail", "contacts")
        }

        if containsAny(["note", "notes", "jot down"]) {
            add("notes")
        }

        if containsAny([
            "screen", "what's on my screen", "what is on my screen", "ui", "button",
            "click ", "type ", "scroll", "find element", "screenshot"
        ]) {
            add("screenshot", "read_screen", "click", "type_text", "scroll", "find_element")
        }

        if containsAny(["camera", "photo", "take a picture", "webcam"]) {
            add("camera")
        }

        if containsAny(["skill", "activate skill", "run skill", "manage skill"]) {
            add("activate_skill", "run_skill", "manage_skill")
        }

        if containsAny([
            "schedule job", "automation", "scheduled task", "scheduler",
            "every day", "every week", "cron"
        ]) {
            add(
                "scheduler_list", "scheduler_create", "scheduler_update",
                "scheduler_delete", "scheduler_trigger"
            )
        }

        if containsAny(["settings", "config", "preference", "tool mode", "permission"]) {
            add("self_config", "channel_setup")
        }

        if containsAny([
            "voice identity", "speaker profile", "recognize my voice", "wake word"
        ]) {
            add("voice_identity")
        }

        if matches.count == 1 {
            switch matches.first {
            case "calendar":
                add("reminders")
            case "reminders":
                add("calendar")
            case "mail":
                add("contacts")
            case "web_search":
                add("fetch_url", "read")
            default:
                break
            }
        }

        return matches
    }

    static func shouldSuppressEpisodeRecallForToolSensitiveTurn(
        userText: String,
        availableToolNames: [String]
    ) -> Bool {
        if isEphemeralArithmeticQuery(userText) {
            return true
        }

        if !explicitlyMentionedToolNames(in: userText, availableToolNames: availableToolNames).isEmpty {
            return true
        }

        if isToolBackedLookupRequest(userText) {
            return true
        }

        let lower = userText.lowercased()
        if lower.contains("http://") || lower.contains("https://") {
            return true
        }

        let pathHints = ["read", "write", "edit", "file", "folder", "path"]
        if userText.contains("/") && pathHints.contains(where: { lower.contains($0) }) {
            return true
        }

        let commandHints = ["bash", "terminal", "command line", "run the command", "execute this command"]
        if commandHints.contains(where: { lower.contains($0) }) {
            return true
        }

        return false
    }

    private static let arithmeticNumberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred",
    ]

    private static func isEphemeralArithmeticQuery(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        let operatorHints = [
            " plus ", " minus ", " times ", " multiplied by ", " divided by ",
            " over ", " x ", " * ", " / ", " + ", " - ",
        ]
        guard operatorHints.contains(where: { lower.contains($0) }) else { return false }

        let digitCount = text
            .replacingOccurrences(of: #"[^0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .count
        let wordCount = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { arithmeticNumberWords.contains($0) }
            .count

        return digitCount + wordCount >= 2
    }

    static func deterministicEasyTurnAction(
        for text: String,
        rememberedUserName: String?
    ) -> DeterministicEasyTurnAction? {
        let normalized = normalizeEasyTurnInput(text)

        if let reply = deterministicArithmeticReply(for: normalized) {
            return .arithmetic(reply: reply)
        }

        if let name = standaloneUserNameDeclaration(in: normalized) {
            return .rememberUserName(
                name: name,
                reply: "Got it. I'll remember that your name is \(name)."
            )
        }

        guard isSimpleUserNameRecallQuery(normalized) else { return nil }
        if let rememberedUserName, !rememberedUserName.isEmpty {
            return .recallUserName(reply: "Your name is \(rememberedUserName).")
        }
        return .recallUserName(reply: "I don't know your name yet. Tell me your name and I'll remember it.")
    }

    private static func normalizeEasyTurnInput(_ text: String) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.replacingOccurrences(
            of: #"^[\s,;:.-]*(hey|hi|hello)\s+fae[\s,;:.-]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(
            of: #"^fae[\s,;:.-]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deterministicArithmeticReply(for text: String) -> String? {
        guard let expression = parseArithmeticExpression(text) else { return nil }

        let result: Double
        switch expression.operatorSymbol {
        case "+":
            result = expression.lhs + expression.rhs
        case "-":
            result = expression.lhs - expression.rhs
        case "*":
            result = expression.lhs * expression.rhs
        case "/":
            guard expression.rhs != 0 else { return "Division by zero isn't defined." }
            result = expression.lhs / expression.rhs
        default:
            return nil
        }

        let formatted: String
        if result.rounded() == result {
            formatted = String(Int(result))
        } else {
            formatted = String(format: "%.2f", result)
                .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
        }

        return "\(formatted)."
    }

    private static func parseArithmeticExpression(_ text: String) -> (lhs: Double, operatorSymbol: String, rhs: Double)? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "what's", with: "what is")
            .replacingOccurrences(of: "calculate", with: "")
            .replacingOccurrences(of: "compute", with: "")
            .replacingOccurrences(of: "what is", with: "")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "multiplied by", with: " * ")
            .replacingOccurrences(of: "times", with: " * ")
            .replacingOccurrences(of: "divided by", with: " / ")
            .replacingOccurrences(of: "over", with: " / ")
            .replacingOccurrences(of: "plus", with: " + ")
            .replacingOccurrences(of: "minus", with: " - ")
            .replacingOccurrences(of: #"(?<=\s)x(?=\s)"#, with: " * ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for symbol in [" + ", " - ", " * ", " / "] {
            guard let range = normalized.range(of: symbol) else { continue }
            let lhsText = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsText = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let lhs = parseArithmeticOperand(lhsText),
                  let rhs = parseArithmeticOperand(rhsText)
            else {
                return nil
            }
            return (lhs, String(symbol.trimmingCharacters(in: .whitespaces)), rhs)
        }

        return nil
    }

    private static func parseArithmeticOperand(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let numeric = Double(trimmed) {
            return numeric
        }

        let sanitized = trimmed
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"[^a-z\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }

        let small: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ]
        let tens: [String: Int] = [
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]

        var total = 0
        var current = 0
        for token in sanitized.split(separator: " ").map(String.init) {
            if token == "and" {
                continue
            } else if let value = small[token] {
                current += value
            } else if let value = tens[token] {
                current += value
            } else if token == "hundred" {
                current = max(current, 1) * 100
            } else if token == "thousand" {
                total += max(current, 1) * 1_000
                current = 0
            } else {
                return nil
            }
        }

        return Double(total + current)
    }

    private static func standaloneUserNameDeclaration(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "my name is ", "my name's ", "call me ",
            "you can call me ", "people call me ",
        ]

        for pattern in patterns {
            guard trimmed.lowercased().hasPrefix(pattern) else { continue }
            let namePortion = String(trimmed.dropFirst(pattern.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?:;\""))
            guard isLikelyStandaloneHumanName(namePortion) else { return nil }
            return namePortion
        }

        return nil
    }

    private static func isLikelyStandaloneHumanName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }
        let blockedTokens: Set<String> = [
            "please", "thanks", "thank", "today", "tonight", "right", "now",
            "and", "then", "also", "help", "because",
        ]

        for word in words {
            let lowered = word.lowercased()
            if blockedTokens.contains(lowered) { return false }
            if word.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil { return false }
            if word.rangeOfCharacter(from: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "-'"))) != nil {
                return false
            }
            if word.count < 2 { return false }
        }

        return true
    }

    private static func isSimpleUserNameRecallQuery(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\?\.\!]"#, with: "", options: .regularExpression)
        let accepted: Set<String> = [
            "what is my name",
            "what's my name",
            "do you know my name",
            "tell me my name",
            "who am i",
        ]
        return accepted.contains(normalized)
    }

    static func batchedTTSSegments(
        from text: String,
        maxCharacters: Int = 420
    ) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > maxCharacters else { return [normalized] }

        var segments: [String] = []
        var remaining = normalized

        while remaining.count > maxCharacters {
            let candidate = String(remaining.prefix(maxCharacters))
            let boundary = TextProcessing.findSentenceBoundary(in: candidate)
                ?? TextProcessing.findClauseBoundary(in: candidate)

            let splitIndex = boundary ?? candidate.endIndex
            let segment = candidate[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(segment)
            }

            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if boundary == nil, remaining == normalized {
                break
            }
        }

        if !remaining.isEmpty {
            segments.append(remaining)
        }

        return segments
    }

    static func shouldAcceptVoiceApprovalResponse(
        awaitingApproval: Bool,
        manualOnlyApprovalPending: Bool,
        assistantSpeaking: Bool
    ) -> Bool {
        guard awaitingApproval else { return false }
        guard !manualOnlyApprovalPending else { return false }
        return !assistantSpeaking
    }

    private static func toolNameAliases(_ toolName: String) -> [String] {
        var aliases: Set<String> = [toolName.lowercased()]
        aliases.insert(toolName.lowercased().replacingOccurrences(of: "_", with: " "))
        aliases.insert(toolName.lowercased().replacingOccurrences(of: "_", with: ""))

        switch toolName {
        case "self_config":
            aliases.formUnion(["self config", "settings tool", "config tool"])
        case "session_search":
            aliases.formUnion([
                "session search", "session_search", "transcript search", "search our chat",
                "search our conversation", "search previous conversation",
            ])
        case "web_search":
            aliases.formUnion(["web search", "search tool"])
        case "fetch_url":
            aliases.formUnion(["fetch url", "url fetch", "fetch tool"])
        case "window_control":
            aliases.formUnion(["window control", "window tool"])
        case "read_screen":
            aliases.formUnion(["read screen", "screen reader tool"])
        case "type_text":
            aliases.formUnion(["type text", "typing tool"])
        case "find_element":
            aliases.formUnion(["find element", "find on screen"])
        case "voice_identity":
            aliases.formUnion(["voice identity", "voice profile", "speaker profile"])
        case "activate_skill":
            aliases.formUnion(["activate skill", "skill activation"])
        case "run_skill":
            aliases.formUnion(["run skill", "execute skill"])
        case "manage_skill":
            aliases.formUnion(["manage skill", "skill manager"])
        case "scheduler_list":
            aliases.formUnion(["scheduler list", "list schedules", "list schedule"])
        case "scheduler_create":
            aliases.formUnion(["scheduler create", "create schedule", "create a schedule"])
        case "scheduler_update":
            aliases.formUnion(["scheduler update", "update schedule"])
        case "scheduler_delete":
            aliases.formUnion(["scheduler delete", "delete schedule"])
        case "scheduler_trigger":
            aliases.formUnion(["scheduler trigger", "run schedule now", "trigger schedule"])
        default:
            break
        }

        return aliases.sorted()
    }

    static func llmFailureFallbackMessage(
        firstOwnerEnrollmentActive: Bool,
        proactiveContextPresent: Bool
    ) -> String? {
        guard !proactiveContextPresent else { return nil }
        if firstOwnerEnrollmentActive {
            return "I can hear you. Use Let me get to know you to record your voice, and then I'll recognize you properly."
        }
        return "I hit a local model problem just then. Please try that once more."
    }

    static func prefersLegacyInlineToolPrompt(modelId: String?) -> Bool {
        guard let modelId else { return false }
        let normalized = modelId.lowercased()
        return normalized.contains("claude-4.6-opus-distilled")
    }

    /// Update the model locality (local vs. non-local co-work) for damage-control policy.
    func setModelLocality(_ locality: ModelLocality) {
        modelLocality = locality
    }

    /// Live override for direct-address policy.
    private var requireDirectAddressLive: Bool?

    /// Live override for acoustic wake detector master switch.
    private var acousticWakeEnabledLive: Bool?

    /// Live override for acoustic wake detector similarity threshold.
    private var acousticWakeThresholdLive: Float?

    /// Live override for vision toggle.
    private var visionEnabledLive: Bool?

    /// Live override for voice identity lock status.
    private var voiceIdentityLockLive: Bool?

    func setRequireDirectAddress(_ enabled: Bool) {
        requireDirectAddressLive = enabled
    }

    func setAcousticWakeEnabled(_ enabled: Bool) {
        acousticWakeEnabledLive = enabled
    }

    func setAcousticWakeThreshold(_ threshold: Float) {
        acousticWakeThresholdLive = threshold
    }

    func setVisionEnabled(_ enabled: Bool) {
        visionEnabledLive = enabled
    }

    func setVoiceIdentityLock(_ enabled: Bool) {
        voiceIdentityLockLive = enabled
    }

    /// Switch the TTS voice live without restarting. No-op if TTS engine is not Kokoro.
    func setTTSVoice(_ voice: String) async {
        if let kokoro = ttsEngine as? KokoroMLXTTSEngine {
            await kokoro.switchVoice(to: voice)
        }
    }

    /// Preview a named voice by synthesizing a short phrase and playing it once.
    func previewTTSVoice(_ voice: String) async {
        guard let kokoro = ttsEngine as? KokoroMLXTTSEngine else { return }
        let phrase = "Hiya, I'm Fae. I've just fed the wee birdies, and I'm feeling quietly cheeky today."
        do {
            guard let buffer = try await kokoro.previewSynthesize(voice: voice, text: phrase),
                  let channelData = buffer.floatChannelData?[0]
            else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            markAssistantSpeechStarted()
            await playback.enqueue(samples: samples, sampleRate: 24_000, isFinal: true)
        } catch {
            NSLog("PipelineCoordinator: voice preview failed: %@", error.localizedDescription)
        }
    }

    /// Update playback speed live without restarting.
    func setPlaybackSpeed(_ speed: Float) async {
        await playback.setSpeed(speed)
    }

    // MARK: - Pipeline State

    private var mode: PipelineMode = .conversation
    private var degradedMode: PipelineDegradedMode?
    private var gateState: GateState = .idle
    private var vad = VoiceActivityDetector()
    private var echoSuppressor = EchoSuppressor()
    private var thinkTagStripper = TextProcessing.ThinkTagStripper()
    private var voiceTagStripper = VoiceTagStripper()

    // MARK: - Atomic-like Flags

    private struct PendingGovernanceAction: Sendable {
        let action: String
        let value: AnySendableValue
        let metadata: [String: String]
        let source: String
        let confirmationPrompt: String
        let successSpeech: String
        let cancelledSpeech: String
    }

    private enum AnySendableValue: Sendable {
        case string(String)
        case bool(Bool)
    }

    private var assistantSpeaking: Bool = false
    private var assistantGenerating: Bool = false
    /// Whether the current turn includes explicit user authorization language.
    private var explicitUserAuthorizationForTurn: Bool = false

    /// Whether the assistant is currently speaking (TTS playback in progress).
    /// Exposed for the test harness to wait until speech completes.
    var isSpeaking: Bool { assistantSpeaking }
    /// Active generation scope for streaming-token isolation across interrupted turns.
    private var activeGenerationID: UUID?
    private var interrupted: Bool = false
    private var interruptedGenerationID: UUID?
    private var awaitingApproval: Bool = false
    /// When true, the current pending approval requires a physical button press.
    /// Voice "yes/no" is rejected and Fae speaks an explanation instead.
    /// Set alongside `awaitingApproval` for damage-control disaster/confirmManual verdicts.
    private var manualOnlyApprovalPending: Bool = false
    private var pendingGovernanceAction: PendingGovernanceAction?

    // MARK: - Speaker Identity State

    private var currentSpeakerLabel: String?
    private var currentSpeakerDisplayName: String?
    private var currentSpeakerRole: SpeakerRole?
    private var currentSpeakerIsOwner: Bool = false
    private var wakeAliases: [String] = TextProcessing.nameVariants
    /// True when speaker verification ran and matched a non-owner profile.
    /// Distinguished from "not matched at all" (unknown/degraded) — only this
    /// flag should hard-block tools when `requireOwnerForTools` is enabled.
    private var currentSpeakerIsKnownNonOwner: Bool = false
    private var previousSpeakerLabel: String?
    private var utterancesSinceOwnerVerified: Int = 0
    /// Wall-clock time when the current utterance was captured by the VAD.
    private var currentUtteranceTimestamp: Date?

    private enum StreamingSpeakerGateVerdict: Equatable {
        case allow
        case rejectUnknown
    }

    private var streamingSpeakerSamples: [Float] = []
    private var streamingSpeakerLastEvaluatedSamples: Int = 0
    private var streamingSpeakerVerdict: StreamingSpeakerGateVerdict?
    private var streamingSpeakerVerificationAvailable: Bool = false

    // MARK: - Enrollment State

    /// True while first-owner enrollment is actively running.
    /// Set by FaeCore when enrollment starts, cleared on enrollment_complete.
    /// Bypasses direct-address gating and allows barge-in from anyone (no owner yet).
    private var firstOwnerEnrollmentActive: Bool = false

    /// One-shot system prompt addition for the LLM's first response after owner enrollment.
    /// Set by FaeCore during the voice enrollment flow; cleared after first use.
    private var firstOwnerEnrollmentContext: String?

    // MARK: - Timing & Echo Detection

    private var lastAssistantStart: Date?
    private var engagedUntil: Date?
    private var idleRearmTask: Task<Void, Never>?
    /// Throttle for “currently sleeping” hints so we do not spam spoken nudges.
    private var lastSleepHintAt: Date?
    /// Last assistant response text — used to detect echo (mic picking up speaker output).
    private var lastAssistantResponseText: String = ""

    // MARK: - Barge-In

    private var pendingBargeIn: PendingBargeIn?

    /// When true, barge-in is suppressed. Set during short non-interruptible
    /// utterances (speakDirect) to prevent background noise from interrupting
    /// command acknowledgments and approval responses.
    private var bargeInSuppressed: Bool = false

    // MARK: - Phase 1 Observability

    private var pipelineStartedAt: Date?
    private var firstAudioLatencyEmitted: Bool = false
    private let instrumentation = PipelineInstrumentation()

    struct PendingBargeIn {
        var capturedAt: Date
        var speechSamples: Int = 0
        var lastRms: Float = 0
        var audioSamples: [Float] = []
    }

    /// Cooldown after non-owner barge-in denial — prevents repeated embedding churn from TV/noise.
    private var bargeInDenyCooldownUntil: Date?
    private static let bargeInDenyCooldownSeconds: TimeInterval = 5.0

    // MARK: - Pipeline Tasks

    private var pipelineTask: Task<Void, Never>?
    private var captureStream: AsyncStream<AudioChunk>?

    /// Speech-segment processing runs on a dedicated bounded queue so capture/VAD
    /// stay responsive even while STT/LLM/TTS are busy.
    private var speechSegmentTask: Task<Void, Never>?
    private var speechSegmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private static let speechSegmentQueueDepth = 6
    private var speechSegmentsDroppedForBackpressure: Int = 0

    /// Chained TTS task — each sentence enqueues onto this so TTS runs in order
    /// without blocking the LLM token stream.
    private var pendingTTSTask: Task<Void, Never>?

    /// Timestamp captured when the user turn ended (post-VAD segment close).
    /// Used for TTFA (time-to-first-audio) telemetry.
    private var lastUserTurnEndedAt: Date?
    private var ttfaEmittedForCurrentTurn: Bool = false
    private var currentTurnID: String?
    private var activeConversationSessionID: String?

    private struct WorkflowTraceContext: Sendable {
        let turnID: String
        let source: String
        let userGoal: String
        var sessionID: String?
        var runID: String?
        var toolSequence: [String] = []
        var userApproved: Bool = false
        var damageControlIntervened: Bool = false
    }

    private var workflowTraceContexts: [String: WorkflowTraceContext] = [:]

    private struct PendingSemanticTurn: Sendable {
        let rawText: String
        let text: String
        let ownerProfileExists: Bool
        let speakerAllowsConversation: Bool
        let rms: Float
        let durationSecs: Float
        let acousticWakeDetection: WakeWordAcousticDetector.Detection?
    }

    private var pendingSemanticTurn: PendingSemanticTurn?
    private var pendingSemanticTurnTask: Task<Void, Never>?
    private static let semanticTurnHoldMs: Int = 1200
    private static let conversationalSilenceFloorMs: Int = 1400

    private var streamingWakeSamples: [Float] = []
    private var streamingWakeLastEvaluatedSamples: Int = 0
    private var streamingWakeDetection: WakeWordAcousticDetector.Detection?
    private static let acousticWakeEvalStrideSamples = 4_800

    // MARK: - Deferred Tool Jobs

    private struct DeferredToolJob: Sendable {
        let id: UUID
        let userText: String
        let toolCalls: [ToolCall]
        let assistantToolMessage: String
        let forceSuppressThinking: Bool
        let capabilityTicket: CapabilityTicket?
        let explicitUserAuthorization: Bool
        let generationContext: GenerationContext
        let originTurnID: String?
    }

    private struct GenerationContext: Sendable {
        let systemPrompt: String
        let turnContextPrefix: String?
        let nativeTools: [[String: any Sendable]]?
        let route: TurnLLMRoute
        let actionSource: ActionSource
        let playsThinkingTone: Bool
        let allowsAudibleOutput: Bool
    }

    /// In-flight deferred tool tasks keyed by job ID.
    private var deferredToolTasks: [UUID: Task<Void, Never>] = [:]

    /// Whether any deferred tool jobs are currently running (test harness use).
    var hasPendingDeferredTools: Bool { !deferredToolTasks.isEmpty }

    // MARK: - Capability Tickets

    /// Task-scoped capability grant consumed by the broker.
    private var activeCapabilityTicket: CapabilityTicket?
    private var sessionDeclaredUserName: String?

    /// Tracks tool call signatures (name + args) already executed this user turn.
    /// Prevents the LLM looping on identical web_search / calendar calls.
    /// Reset at the start of each new user turn (turnCount == 0, isToolFollowUp == false).
    private var seenToolCallSignatures: Set<String> = []

    // MARK: - Proactive Awareness

    /// Immutable per-turn context for scheduler-initiated proactive queries.
    /// Passed down the current generation call stack (never stored as shared state)
    /// to avoid source/allowlist leakage across concurrent turns.
    struct ProactiveRequestContext: Sendable {
        let source: ActionSource
        let taskId: String
        let allowedTools: Set<String>
        let consentGranted: Bool
        let conversationTag: String
    }

    struct DeferredProactiveRequest: Sendable {
        let prompt: String
        let silent: Bool
        let taskId: String
        let allowedTools: Set<String>
        let consentGranted: Bool
    }

    private var deferredProactiveRequests: [DeferredProactiveRequest] = []

    /// Called on user-initiated turns to let scheduler run morning fallback checks.
    private var userInteractionHandler: (@Sendable () async -> Void)?

    /// Called after proactive camera observations to update scheduler presence state.
    private var proactivePresenceHandler: (@Sendable (Bool) async -> Void)?

    /// Called after proactive screen observations to decide whether to persist context.
    private var proactiveScreenContextHandler: (@Sendable (String) async -> Bool)?

    // MARK: - Init

    init(
        eventBus: FaeEventBus,
        capture: AudioCaptureManager,
        playback: AudioPlaybackManager,
        sttEngine: MLXSTTEngine,
        llmEngine: any LLMEngine,
        conciergeEngine: (any LLMEngine)? = nil,
        ttsEngine: any TTSEngine,
        config: FaeConfig,
        conversationState: ConversationStateTracker,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        sessionStore: SessionStore? = nil,
        workflowTraceStore: WorkflowTraceStore? = nil,
        approvalManager: ApprovalManager? = nil,
        registry: ToolRegistry,
        speakerEncoder: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        wakeWordProfileStore: WakeWordProfileStore? = nil,
        skillManager: SkillManager? = nil,
        toolAnalytics: ToolAnalytics? = nil,
        modelManager: ModelManager? = nil,
        rescueMode: Bool = false
    ) {
        self.eventBus = eventBus
        self.capture = capture
        self.playback = playback
        self.sttEngine = sttEngine
        self.llmEngine = llmEngine
        self.conciergeEngine = conciergeEngine
        self.ttsEngine = ttsEngine
        self.config = config
        self.conversationState = conversationState
        self.memoryOrchestrator = memoryOrchestrator
        self.sessionStore = sessionStore
        self.workflowTraceStore = workflowTraceStore
        self.approvalManager = approvalManager
        self.registry = registry
        self.actionBroker = DefaultTrustedActionBroker(
            knownTools: Set(registry.toolNames),
            speakerConfig: config.speaker
        )
        self.speakerEncoder = speakerEncoder
        self.speakerProfileStore = speakerProfileStore
        self.wakeWordProfileStore = wakeWordProfileStore
        self.skillManager = skillManager
        self.toolAnalytics = toolAnalytics
        self.modelManager = modelManager
        self.isRescueMode = rescueMode

        // Configure VAD from config.
        vad.applyConfiguration(config.vad)
    }

    // MARK: - Lifecycle

    /// Start the voice pipeline.
    func start() async throws {
        guard pipelineTask == nil else { return }

        debugLog(debugConsole, .qa, "Pipeline start requested")
        eventBus.send(.pipelineStateChanged(.starting))

        // Set up playback event handler and voice speed.
        try await playback.setup()
        await playback.setSpeed(config.tts.speed)
        await setPlaybackEventHandler()

        if let wakeStore = wakeWordProfileStore {
            wakeAliases = await wakeStore.allAliases()
            debugLog(debugConsole, .command, "Wake aliases loaded: \(wakeAliases.joined(separator: ", "))")
        }

        startSpeechSegmentProcessingLoop()

        // Start audio capture.
        let stream = try await capture.startCapture()
        captureStream = stream

        eventBus.send(.pipelineStateChanged(.running))
        pipelineStartedAt = Date()
        await refreshDegradedModeIfNeeded(context: "startup")
        debugLog(debugConsole, .qa, "Pipeline running mode=\(mode.rawValue) toolMode=\(effectiveToolMode())")
        NSLog("PipelineCoordinator: pipeline started in %@ mode", mode.rawValue)

        // Main pipeline loop.
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipelineLoop(stream: stream)
        }
    }

    /// Stop the pipeline.
    func stop() async {
        debugLog(debugConsole, .qa, "Pipeline stop requested")
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        computerUseStepCount = 0

        // Ensure any in-flight TTS synthesis task fully exits before teardown.
        let activeTTSTask = pendingTTSTask
        pendingTTSTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        pipelineTask?.cancel()
        pipelineTask = nil
        cancelDeferredToolJobs()
        await stopSpeechSegmentProcessingLoop()
        await closeConversationSessionIfNeeded(reason: "pipeline_stop")
        await abandonAllWorkflowTraces(reason: "Pipeline stopped before workflow completion.")
        await capture.stopCapture()
        await playback.stop()
        await llmEngine.shutdown()
        await conciergeEngine?.shutdown()
        currentTurnID = nil
        eventBus.send(.pipelineStateChanged(.stopped))
        NSLog("PipelineCoordinator: pipeline stopped")
    }

    /// Cancel the current generation immediately.
    ///
    /// Sets `interrupted = true` and stops audio playback. The pipeline
    /// loop checks `interrupted` at each step and exits cleanly.
    func cancel() {
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        computerUseStepCount = 0

        let activeTTSTask = pendingTTSTask
        pendingTTSTask = nil
        activeTTSTask?.cancel()
        if let activeTTSTask {
            Task { await activeTTSTask.value }
        }

        Task { await playback.stop() }
        NSLog("PipelineCoordinator: cancelled by user")
    }

    /// Cancel and await full stop — including playback + deferred tools (test harness use).
    func cancelAndWait() async {
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        computerUseStepCount = 0

        let activeTTSTask = pendingTTSTask
        pendingTTSTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        cancelDeferredToolJobs()
        await playback.stop()
        assistantSpeaking = false
        lastAssistantStart = nil
        echoSuppressor.reset()
        // Ensure generation flag is cleared so the pipeline accepts new injections after reset.
        assistantGenerating = false
        awaitingApproval = false
        manualOnlyApprovalPending = false
        await abandonAllWorkflowTraces(reason: "Generation cancelled before workflow completion.")
        NSLog("PipelineCoordinator: cancelAndWait complete")
    }

    private func cancelDeferredToolJobs() {
        for (_, task) in deferredToolTasks {
            task.cancel()
        }
        deferredToolTasks.removeAll()
    }

    // MARK: - Input Request

    /// Request text input from the user asynchronously.
    ///
    /// Delegates to `InputRequestBridge.shared` which posts `.faeInputRequired`,
    /// shows the input card in the UI, and suspends until the user responds.
    /// The 120s timeout is managed by the bridge.
    ///
    /// - Parameters:
    ///   - prompt: Human-readable description of what input is needed.
    ///   - placeholder: Placeholder text for the input field.
    ///   - isSecure: Whether to obscure the input (for passwords/keys).
    /// - Returns: The user's text, or nil if cancelled or timed out.
    func inputRequired(
        prompt: String,
        placeholder: String = "",
        isSecure: Bool = false
    ) async -> String? {
        await InputRequestBridge.shared.request(
            prompt: prompt,
            placeholder: placeholder,
            isSecure: isSecure
        )
    }

    // MARK: - Text Injection

    /// Inject text directly into the LLM (bypasses STT).
    func injectText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isConversationStopTrigger(trimmed) {
            await resetConversationSession(trigger: trimmed, source: "text")
            return
        }

        // Text input is trusted (physically typed by the user at the device).
        currentSpeakerLabel = "owner"
        currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        currentSpeakerRole = .owner
        currentSpeakerIsOwner = true
        currentSpeakerIsKnownNonOwner = false

        if gateState == .idle {
            // When direct-address gating is off, any text wakes Fae (she should always respond).
            // When gating is on, require the name to avoid responding to ambient conversation.
            guard isAddressedToFae(trimmed) || !effectiveRequireDirectAddress() else {
                debugLog(debugConsole, .pipeline, "Text ignored while sleeping (not addressed)")
                return
            }
            wake()
        } else if effectiveRequireDirectAddress() {
            // Direct-address gating applies to typed text too: when enabled, non-addressed
            // input is dropped unless we're within the follow-up window.
            let inFollowup = engagedUntil.map { Date() < $0 } ?? false
            if !isAddressedToFae(trimmed) && !inFollowup {
                debugLog(debugConsole, .pipeline, "Text ignored (direct-address required, not addressed): \(trimmed)")
                return
            }
        }

        // If assistant is active, trigger barge-in.
        if assistantSpeaking || assistantGenerating {
            markGenerationInterrupted()
            await playback.stop()
        }

        // Handle governance voice commands from injected text (mirrors voice segment processing).
        // This allows test injection and typed input to trigger governance shortcuts (tool mode,
        // thinking toggle, barge-in toggle) without routing through the LLM, which would require
        // approval for self_config even in full_no_approval mode.
        let voiceCmd = VoiceCommandParser.parse(trimmed)
        if voiceCmd != .none {
            if await handleVoiceCommandIfNeeded(voiceCmd, originalText: trimmed) { return }
        }

        await processTranscription(
            text: trimmed,
            wakeMatch: wakeAddressMatch(in: trimmed),
            rms: nil,
            durationSecs: nil,
            turnSource: .text
        )
    }

    /// Inject text from the desktop cowork surface.
    ///
    /// This path is intentionally silent: it bypasses wake/direct-address gating,
    /// keeps the turn in text mode, and suppresses thinking tones and audio playback.
    func injectDesktopText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isConversationStopTrigger(trimmed) {
            await resetConversationSession(trigger: trimmed, source: "desktop_text")
            return
        }

        currentSpeakerLabel = "owner"
        currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        currentSpeakerRole = .owner
        currentSpeakerIsOwner = true
        currentSpeakerIsKnownNonOwner = false

        await processTranscription(
            text: trimmed,
            rms: nil,
            durationSecs: nil,
            turnSource: .text,
            playsThinkingTone: false,
            allowsAudibleOutput: false
        )
    }

    /// Speak text directly via TTS without going through the LLM.
    ///
    /// Used for system messages like the first-launch greeting, command
    /// acknowledgments, and approval responses. Non-interruptible — barge-in
    /// is suppressed for the duration to prevent background noise from cutting
    /// off short utterances.
    func speakDirect(_ text: String) async {
        bargeInSuppressed = true
        defer { bargeInSuppressed = false }
        await speakText(text, isFinal: true)
    }

    /// Speak text with a specific voice description, bypassing the LLM.
    ///
    /// Used for voice preview in roleplay and settings. Non-interruptible.
    func speakWithVoice(_ text: String, voiceInstruct: String) async {
        bargeInSuppressed = true
        defer { bargeInSuppressed = false }
        await speakText(text, isFinal: true, voiceInstruct: voiceInstruct)
    }

    /// Set/clear the first-owner enrollment active flag.
    func setFirstOwnerEnrollmentActive(_ active: Bool) {
        firstOwnerEnrollmentActive = active
        vad.reset()
        resetStreamingSpeakerGate()
        resetStreamingWakeDetector()
        clearPendingSemanticTurn()
    }

    /// Register a callback fired on each user-initiated turn.
    func setUserInteractionHandler(_ handler: @escaping @Sendable () async -> Void) {
        userInteractionHandler = handler
    }

    /// Register a callback fired after proactive camera observations.
    func setProactivePresenceHandler(_ handler: @escaping @Sendable (Bool) async -> Void) {
        proactivePresenceHandler = handler
    }

    /// Register a callback fired after proactive screen observations.
    func setProactiveScreenContextHandler(_ handler: @escaping @Sendable (String) async -> Bool) {
        proactiveScreenContextHandler = handler
    }

    // MARK: - Proactive Query Injection

    /// Inject a scheduler-initiated proactive query into the LLM pipeline.
    ///
    /// Modelled after `injectText()` but for scheduler-initiated observations.
    /// Uses a per-request `ProactiveRequestContext` (not a shared mutable field)
    /// so actor isolation guarantees no race with user-initiated actions.
    ///
    /// - Parameters:
    ///   - prompt: The proactive observation prompt (e.g. "[PROACTIVE CAMERA OBSERVATION]").
    ///   - silent: If true, appends instruction to only speak if meaningful.
    ///   - taskId: Scheduler task identifier for per-task tool allowlisting.
    ///   - allowedTools: Tools this task is permitted to use.
    ///   - consentGranted: Whether awareness consent is currently active.
    func injectProactiveQuery(
        prompt: String,
        silent: Bool = true,
        taskId: String,
        allowedTools: Set<String>,
        consentGranted: Bool
    ) async {
        let request = DeferredProactiveRequest(
            prompt: prompt,
            silent: silent,
            taskId: taskId,
            allowedTools: allowedTools,
            consentGranted: consentGranted
        )

        guard !assistantGenerating, !assistantSpeaking else {
            enqueueDeferredProactiveRequest(request)
            NSLog("PipelineCoordinator: proactive query deferred — assistant busy")
            return
        }

        await runProactiveQuery(request)
    }

    private func runProactiveQuery(_ request: DeferredProactiveRequest) async {
        let proactiveTag = "\(request.taskId)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let proactiveContext = ProactiveRequestContext(
            source: .scheduler,
            taskId: request.taskId,
            allowedTools: request.allowedTools,
            consentGranted: request.consentGranted,
            conversationTag: proactiveTag
        )

        // Scheduler acts on behalf of the consented owner.
        currentSpeakerLabel = "owner"
        currentSpeakerDisplayName = "Owner"
        currentSpeakerRole = .owner
        currentSpeakerIsOwner = true
        currentSpeakerIsKnownNonOwner = false

        var fullPrompt = request.prompt
        if request.silent {
            fullPrompt += "\n\n[Respond only if you have something meaningful to say. Otherwise stay silent.]"
        }

        debugLog(debugConsole, .pipeline, "Proactive query: taskId=\(request.taskId) silent=\(request.silent)")

        await processTranscription(
            text: fullPrompt,
            wakeMatch: nil,
            rms: nil,
            durationSecs: nil,
            proactiveContext: proactiveContext
        )

        await conversationState.removeMessages(taggedWith: proactiveTag)
    }

    private func enqueueDeferredProactiveRequest(_ request: DeferredProactiveRequest) {
        let taskIDs = Self.coalescedDeferredProactiveTaskIDs(
            existing: deferredProactiveRequests.map(\.taskId),
            incomingTaskID: request.taskId
        )
        deferredProactiveRequests.removeAll { $0.taskId == request.taskId }
        deferredProactiveRequests.append(request)
        debugLog(debugConsole, .pipeline, "Deferred proactive queue: \(taskIDs.joined(separator: ","))")
    }

    private func scheduleDeferredProactiveDrain() {
        guard !assistantGenerating, !assistantSpeaking, !deferredProactiveRequests.isEmpty else { return }
        Task { await drainDeferredProactiveIfIdle() }
    }

    private func drainDeferredProactiveIfIdle() async {
        guard !assistantGenerating, !assistantSpeaking,
              !deferredProactiveRequests.isEmpty
        else {
            return
        }

        let next = deferredProactiveRequests.removeFirst()
        await runProactiveQuery(next)
    }

    /// Test speaker match: record 2 seconds, embed, match against profiles.
    func testSpeakerMatch() async {
        guard let encoder = speakerEncoder, await encoder.isLoaded,
              let store = speakerProfileStore
        else {
            NSLog("PipelineCoordinator: testSpeakerMatch — speaker system not ready")
            return
        }
        do {
            let samples = try await capture.captureSegment(durationSeconds: 2.0)
            let embedding = try await encoder.embed(
                audio: samples,
                sampleRate: AudioCaptureManager.targetSampleRate
            )
            if let match = await store.match(
                embedding: embedding,
                threshold: config.speaker.threshold
            ) {
                NSLog("PipelineCoordinator: testSpeakerMatch — Match: %@ (%.2f)",
                      match.displayName, match.similarity)
            } else {
                NSLog("PipelineCoordinator: testSpeakerMatch — No match")
            }
        } catch {
            NSLog("PipelineCoordinator: testSpeakerMatch failed: %@", error.localizedDescription)
        }
    }

    /// Set one-shot context to be injected into the next LLM system prompt.
    /// Used by the voice enrollment flow to prime Fae's first response to a new owner.
    /// Cleared automatically after the first use.
    func setFirstOwnerEnrollmentContext(_ context: String) {
        firstOwnerEnrollmentContext = context
    }

    /// Inject remote PCM audio into the speech pipeline (e.g. companion handoff).
    func injectAudio(samples: [Float], sampleRate: Int = 16_000) async {
        guard !samples.isEmpty else { return }
        let sr = max(sampleRate, 1)
        let segment = SpeechSegment(
            samples: samples,
            sampleRate: sr,
            durationSeconds: Double(samples.count) / Double(sr),
            capturedAt: Date()
        )
        await handleSpeechSegment(segment)
    }

    /// Reset conversation history (for test harness use).
    func resetConversation() async {
        sleep()
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        activeCapabilityTicket = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        cancelDeferredToolJobs()
        resetStreamingSpeakerGate()
        resetStreamingWakeDetector()
        clearPendingSemanticTurn()
        await closeConversationSessionIfNeeded(reason: "conversation_reset")
        await abandonAllWorkflowTraces(reason: "Conversation reset before workflow completion.")
        await conversationState.clear()
        await llmEngine.resetSession()
        await conciergeEngine?.resetSession()
        _ = await RoleplaySessionStore.shared.stop()
        currentTurnGenerationContext = nil
        currentTurnID = nil
        sessionDeclaredUserName = nil
        assistantSpeaking = false
        lastAssistantStart = nil
        echoSuppressor.reset()
        NSLog("PipelineCoordinator: conversation fully reset (test harness)")
    }

    private func synchronizeLLMSession() async {
        let history = await conversationState.history
        await llmEngine.synchronizeSession(history: history)
        await conciergeEngine?.synchronizeSession(history: history)
    }

    private func currentDualModelPlan() -> FaeConfig.LocalModelStackPlan {
        FaeConfig.recommendedLocalModelStack(config: config)
    }

    private func selectedLocalModel(for route: TurnLLMRoute) -> FaeConfig.LocalLLMSelection {
        let plan = currentDualModelPlan()
        switch route {
        case .operatorModel:
            return plan.operatorModel
        case .conciergeModel:
            return plan.conciergeModel ?? plan.operatorModel
        }
    }

    private func ensureLLMReady(
        _ engine: any LLMEngine,
        route: TurnLLMRoute
    ) async -> Bool {
        if await engine.isLoaded {
            return true
        }

        let selection = selectedLocalModel(for: route)
        debugLog(
            debugConsole,
            .pipeline,
            "LLM reload requested for route=\(route.rawValue) model=\(selection.modelId)"
        )
        do {
            try await engine.load(modelID: selection.modelId)
            return true
        } catch {
            NSLog(
                "PipelineCoordinator: failed to reload %@ model %@: %@",
                route.rawValue,
                selection.modelId,
                error.localizedDescription
            )
            debugLog(
                debugConsole,
                .pipeline,
                "⚠️ LLM reload failed for route=\(route.rawValue): \(error.localizedDescription)"
            )
            return false
        }
    }

    private func selectLLMRoute(
        userText: String,
        isToolFollowUp: Bool,
        proactiveContext: ProactiveRequestContext?,
        allowsAudibleOutput: Bool,
        toolsAvailable: Bool
    ) async -> TurnLLMRoute {
        let conciergeLoaded = await conciergeEngine?.isLoaded ?? false
        let route = TurnRoutingPolicy.decide(
            userText: userText,
            dualModelEnabled: currentDualModelPlan().dualModelActive,
            conciergeLoaded: conciergeLoaded,
            allowConciergeDuringVoiceTurns: config.llm.allowConciergeDuringVoiceTurns,
            isToolFollowUp: isToolFollowUp,
            proactive: proactiveContext != nil,
            allowsAudibleOutput: allowsAudibleOutput,
            toolsAvailable: toolsAvailable
        )

        let fallbackReason: String = {
            if !currentDualModelPlan().dualModelActive { return "single_model_mode" }
            if !conciergeLoaded { return "concierge_unavailable" }
            if route == .operatorModel && toolsAvailable { return "operator_tool_priority" }
            return "none"
        }()
        publishRouteDiagnostics(route: route, fallbackReason: fallbackReason)
        return route
    }

    private func publishRouteDiagnostics(route: TurnLLMRoute, fallbackReason: String) {
        UserDefaults.standard.set(route.rawValue, forKey: "fae.runtime.current_route")
        UserDefaults.standard.set(fallbackReason, forKey: "fae.runtime.fallback_reason")
        Task {
            await modelManager?.publishLocalStackStatus(currentRoute: route.rawValue)
        }
    }

    private func engine(for route: TurnLLMRoute) -> any LLMEngine {
        switch route {
        case .operatorModel:
            return llmEngine
        case .conciergeModel:
            return conciergeEngine ?? llmEngine
        }
    }

    // MARK: - Gate Control

    func wake() {
        gateState = .active
        engagedUntil = Date().addingTimeInterval(Double(effectiveIdleRearmSeconds()))
        scheduleIdleRearm()
        NSLog("PipelineCoordinator: gate → active")
    }

    func sleep() {
        gateState = .idle
        idleRearmTask?.cancel()
        idleRearmTask = nil
        engagedUntil = nil
        if assistantSpeaking || assistantGenerating {
            markGenerationInterrupted()
            Task { await playback.stop() }
        }
        NSLog("PipelineCoordinator: gate → idle")
    }

    func engage() {
        gateState = .active
        engagedUntil = Date().addingTimeInterval(Double(effectiveIdleRearmSeconds()))
        scheduleIdleRearm()
    }

    private func effectiveToolMode() -> String {
        if isRescueMode {
            return "read_only"
        }
        return toolModeLive ?? config.toolMode
    }

    private func effectivePrivacyMode() -> String {
        if isRescueMode {
            return "strict_local"
        }
        return privacyModeLive ?? config.privacy.mode
    }

    private func selectedModelId(for route: TurnLLMRoute) -> String? {
        switch route {
        case .operatorModel:
            return FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset).modelId
        case .conciergeModel:
            return FaeConfig.recommendedConciergeModel(
                preset: config.llm.conciergeModelPreset
            )?.modelId
        }
    }

    private func effectiveRequireDirectAddress() -> Bool {
        requireDirectAddressLive ?? config.conversation.requireDirectAddress
    }

    private func effectiveAcousticWakeEnabled() -> Bool {
        acousticWakeEnabledLive ?? config.conversation.acousticWakeEnabled
    }

    private func effectiveAcousticWakeThreshold() -> Float {
        acousticWakeThresholdLive ?? config.conversation.acousticWakeThreshold
    }

    private func postVoiceAttentionEvent(_ payload: [String: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .faePipelineState,
                object: nil,
                userInfo: [
                    "event": "pipeline.voice_attention",
                    "payload": payload,
                ]
            )
        }
    }

    private func publishVoiceAttention(
        stage: String,
        decision: String,
        reason: String,
        transcript: String? = nil,
        wakeSource: String? = nil,
        wakeScore: Float? = nil,
        semanticState: String? = nil,
        rms: Float? = nil
    ) {
        var payload: [String: Any] = [
            "stage": stage,
            "decision": decision,
            "reason": reason,
            "speaker_role": currentSpeakerRole?.rawValue ?? "unknown",
            "gate_state": gateState == .active ? "active" : "idle",
            "require_direct_address": effectiveRequireDirectAddress(),
            "followup_active": engagedUntil.map { Date() < $0 } ?? false,
            "acoustic_wake_enabled": effectiveAcousticWakeEnabled(),
            "acoustic_wake_threshold": Double(effectiveAcousticWakeThreshold()),
        ]
        if let transcript, !transcript.isEmpty {
            payload["transcript"] = transcript
        }
        if let wakeSource {
            payload["wake_source"] = wakeSource
        }
        if let wakeScore {
            payload["wake_score"] = Double(wakeScore)
        }
        if let semanticState {
            payload["semantic_state"] = semanticState
        }
        if let rms {
            payload["rms"] = Double(rms)
        }
        postVoiceAttentionEvent(payload)
    }

    static func idleRearmSeconds(
        requireDirectAddress: Bool,
        idleTimeoutS: Int,
        directAddressFollowupS: Int
    ) -> Int {
        if requireDirectAddress {
            return max(max(directAddressFollowupS, idleTimeoutS), 5)
        }
        return max(idleTimeoutS, 0)
    }

    static func silenceThresholdMs(
        assistantSpeaking: Bool,
        gateState: GateState,
        inFollowup: Bool,
        hasPendingSemanticTurn: Bool,
        configMinSilenceMs: Int,
        bargeInSilenceMs: Int
    ) -> Int {
        if assistantSpeaking {
            return bargeInSilenceMs
        }

        let conversationalTurnActive = gateState == .active && (inFollowup || hasPendingSemanticTurn)
        if conversationalTurnActive {
            return max(configMinSilenceMs, Self.conversationalSilenceFloorMs)
        }

        return configMinSilenceMs
    }

    static func shouldSkipSTTAfterSpeakerVerification(
        ownerProfileExists: Bool,
        speakerVerificationCompleted: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?
    ) -> Bool {
        guard ownerProfileExists, speakerVerificationCompleted else {
            return false
        }
        return !VoiceConversationPolicy.allowsConversation(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: speakerRole
        )
    }

    static func streamingSpeakerSimilarityDecision(
        bestHumanSimilarity: Float?,
        acceptThreshold: Float,
        rejectThreshold: Float
    ) -> StreamingSpeakerSimilarityDecision {
        guard let bestHumanSimilarity else {
            return .reject
        }
        if bestHumanSimilarity >= acceptThreshold {
            return .allow
        }
        if bestHumanSimilarity <= rejectThreshold {
            return .reject
        }
        return .undecided
    }

    static func fusedVoiceAttentionDecision(
        gateState: GateState,
        requireDirectAddress: Bool,
        addressedToFae: Bool,
        inFollowup: Bool,
        awaitingApproval: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerAllowsConversation: Bool,
        wordCount: Int
    ) -> VoiceAttentionDecision {
        if firstOwnerEnrollmentActive {
            if !speakerAllowsConversation {
                return .dropSpeaker
            }
            if !awaitingApproval,
               !addressedToFae,
               wordCount <= 2
            {
                return .dropShortIdle
            }
            if gateState != .active {
                return .wakeAndContinue
            }
        }

        if gateState != .active {
            if addressedToFae {
                return .wakeAndContinue
            }
            if speakerAllowsConversation && wordCount >= 4 {
                return .wakeAndContinue
            }
            return .ignoreWhileSleeping
        }

        if requireDirectAddress,
           !addressedToFae,
           !inFollowup,
           !awaitingApproval,
           !firstOwnerEnrollmentActive
        {
            return .dropDirectAddress
        }

        if !awaitingApproval,
           !inFollowup,
           !addressedToFae,
           wordCount <= 2
        {
            return .dropShortIdle
        }

        if !speakerAllowsConversation {
            return .dropSpeaker
        }

        return .allow
    }

    static func shouldDeferSemanticTurn(
        text: String,
        addressedToFae: Bool,
        inFollowup: Bool,
        awaitingApproval: Bool,
        hasPendingGovernanceAction: Bool,
        firstOwnerEnrollmentActive: Bool
    ) -> Bool {
        guard !awaitingApproval,
              !hasPendingGovernanceAction,
              !firstOwnerEnrollmentActive
        else {
            return false
        }

        // Do not hold a bare wake phrase — wake promptly.
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if addressedToFae && wordCount <= 2 {
            return false
        }

        // Strongest value is in active/follow-up conversational turns.
        guard inFollowup || addressedToFae || wordCount >= 3 else {
            return false
        }

        return TextProcessing.isLikelyIncompleteTurn(text)
    }

    private enum PreviewSpeakerVerificationDecision {
        case useEmbedding([Float])
        case rejectUnknown
        case echoRejected(Float)
        case fallBackToFullSegment
    }

    enum StreamingSpeakerSimilarityDecision: Equatable {
        case allow
        case reject
        case undecided
    }

    enum VoiceAttentionDecision: Equatable {
        case ignoreWhileSleeping
        case wakeAndContinue
        case dropDirectAddress
        case dropShortIdle
        case dropSpeaker
        case allow
    }

    private static let previewSpeakerWindowMs: Int = 1200
    private static let previewSpeakerMinWindowMs: Int = 700
    private static let previewSpeakerThresholdRelaxation: Float = 0.08
    private static let previewSpeakerRejectMargin: Float = 0.14
    private static let streamingSpeakerWindowMs: Int = 1400
    private static let streamingSpeakerStepMs: Int = 240

    private func previewSpeakerVerification(
        segment: SpeechSegment,
        encoder: CoreMLSpeakerEncoder,
        store: SpeakerProfileStore,
        hasOwner: Bool
    ) async -> PreviewSpeakerVerificationDecision {
        guard hasOwner, !firstOwnerEnrollmentActive else {
            return .fallBackToFullSegment
        }

        let minSamples = (Self.previewSpeakerMinWindowMs * segment.sampleRate) / 1000
        guard segment.samples.count >= minSamples else {
            return .fallBackToFullSegment
        }

        let previewSamples = min(
            segment.samples.count,
            (Self.previewSpeakerWindowMs * segment.sampleRate) / 1000
        )

        do {
            let previewEmbedding = try await encoder.embed(
                audio: Array(segment.samples.prefix(previewSamples)),
                sampleRate: segment.sampleRate
            )
            let previewThreshold = max(
                config.speaker.threshold - Self.previewSpeakerThresholdRelaxation,
                0.55
            )
            let rejectThreshold = max(
                previewThreshold - Self.previewSpeakerRejectMargin,
                0.35
            )

            let bestHumanSimilarity = await store.bestMatch(
                embedding: previewEmbedding,
                excludingRoles: [.faeSelf]
            )?.similarity
            switch Self.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: bestHumanSimilarity,
                acceptThreshold: previewThreshold,
                rejectThreshold: rejectThreshold
            ) {
            case .allow:
                return .useEmbedding(previewEmbedding)
            case .reject:
                return .rejectUnknown
            case .undecided:
                break
            }

            if let faeSelfSim = await store.matchesFaeSelf(
                embedding: previewEmbedding,
                threshold: previewThreshold
            ) {
                if echoSuppressor.isInSuppression {
                    return .echoRejected(faeSelfSim)
                }
                return .fallBackToFullSegment
            }
        } catch {
            debugLog(debugConsole, .speaker, "Preview embed failed: \(error.localizedDescription)")
            return .fallBackToFullSegment
        }

        return .fallBackToFullSegment
    }

    private func resetStreamingSpeakerGate() {
        streamingSpeakerSamples.removeAll(keepingCapacity: true)
        streamingSpeakerLastEvaluatedSamples = 0
        streamingSpeakerVerdict = nil
        streamingSpeakerVerificationAvailable = false
    }

    private func resetStreamingWakeDetector() {
        streamingWakeSamples.removeAll(keepingCapacity: true)
        streamingWakeLastEvaluatedSamples = 0
        streamingWakeDetection = nil
    }

    private func acousticWakeDetectionForSegment(_ segment: SpeechSegment) async -> WakeWordAcousticDetector.Detection? {
        if let detection = streamingWakeDetection {
            return detection
        }

        guard effectiveAcousticWakeEnabled(),
              !firstOwnerEnrollmentActive,
              let wakeStore = wakeWordProfileStore
        else {
            return nil
        }

        let prefixMaxSamples = Int(Float(segment.sampleRate) * WakeWordAcousticDetector.maxDurationSeconds)
        let prefix = Array(segment.samples.prefix(prefixMaxSamples))
        let templates = await wakeStore.acousticTemplates()
        guard let detection = WakeWordAcousticDetector.bestDetection(
            samples: prefix,
            sampleRate: segment.sampleRate,
            templates: templates,
            threshold: effectiveAcousticWakeThreshold()
        ) else {
            return nil
        }

        debugLog(
            debugConsole,
            .command,
            "Acoustic wake detected on segment sim=\(String(format: "%.3f", detection.similarity))"
        )
        publishVoiceAttention(
            stage: "wake",
            decision: "detected",
            reason: "acoustic_segment_match_consensus",
            wakeSource: "acoustic",
            wakeScore: detection.consensusSimilarity,
            rms: VoiceActivityDetector.computeRMS(prefix)
        )
        return detection
    }

    private func updateStreamingWakeDetector(chunk: AudioChunk, vadOutput: VoiceActivityDetector.Output) async {
        if vadOutput.speechStarted {
            resetStreamingWakeDetector()
        }

        if vadOutput.segment != nil || streamingWakeDetection != nil {
            return
        }

        guard effectiveAcousticWakeEnabled(),
              !firstOwnerEnrollmentActive,
              vadOutput.isSpeech,
              !assistantSpeaking,
              !assistantGenerating,
              let wakeStore = wakeWordProfileStore
        else {
            return
        }

        streamingWakeSamples.append(contentsOf: chunk.samples)
        let maxPrefixSamples = Int(Float(AudioCaptureManager.targetSampleRate) * WakeWordAcousticDetector.maxDurationSeconds)
        if streamingWakeSamples.count > maxPrefixSamples {
            streamingWakeSamples = Array(streamingWakeSamples.prefix(maxPrefixSamples))
        }

        let minSamples = Int(Float(AudioCaptureManager.targetSampleRate) * WakeWordAcousticDetector.minDurationSeconds)
        guard streamingWakeSamples.count >= minSamples else { return }

        if streamingWakeSamples.count - streamingWakeLastEvaluatedSamples < Self.acousticWakeEvalStrideSamples {
            return
        }
        streamingWakeLastEvaluatedSamples = streamingWakeSamples.count

        let templates = await wakeStore.acousticTemplates()
        guard let detection = WakeWordAcousticDetector.bestDetection(
            samples: streamingWakeSamples,
            sampleRate: AudioCaptureManager.targetSampleRate,
            templates: templates,
            threshold: effectiveAcousticWakeThreshold()
        ) else {
            return
        }

        streamingWakeDetection = detection
        debugLog(
            debugConsole,
            .command,
            "Acoustic wake detected sim=\(String(format: "%.3f", detection.similarity)) consensus=\(String(format: "%.3f", detection.consensusSimilarity)) support=\(detection.supportCount)/\(detection.templateCount)"
        )
        publishVoiceAttention(
            stage: "wake",
            decision: "detected",
            reason: "acoustic_prefix_match_consensus",
            wakeSource: "acoustic",
            wakeScore: detection.consensusSimilarity,
            rms: vadOutput.rms
        )
    }

    private func updateStreamingSpeakerGate(chunk: AudioChunk, vadOutput: VoiceActivityDetector.Output) async {
        if vadOutput.speechStarted {
            resetStreamingSpeakerGate()
        }

        if vadOutput.segment != nil {
            return
        }

        guard vadOutput.isSpeech,
              !assistantSpeaking,
              !assistantGenerating,
              streamingSpeakerVerdict != .rejectUnknown,
              let encoder = speakerEncoder,
              await encoder.isLoaded,
              let store = speakerProfileStore
        else {
            return
        }

        let hasOwner = await store.hasOwnerProfile()
        guard hasOwner, !firstOwnerEnrollmentActive else { return }

        streamingSpeakerVerificationAvailable = true
        if streamingSpeakerVerdict == .allow {
            return
        }

        let maxSamples = (Self.streamingSpeakerWindowMs * chunk.sampleRate) / 1000
        let stepSamples = max((Self.streamingSpeakerStepMs * chunk.sampleRate) / 1000, chunk.samples.count)
        let minSamples = (Self.previewSpeakerMinWindowMs * chunk.sampleRate) / 1000

        if streamingSpeakerSamples.count < maxSamples {
            let remaining = maxSamples - streamingSpeakerSamples.count
            streamingSpeakerSamples.append(contentsOf: chunk.samples.prefix(remaining))
        }

        guard streamingSpeakerSamples.count >= minSamples else { return }
        guard streamingSpeakerSamples.count - streamingSpeakerLastEvaluatedSamples >= stepSamples
                || streamingSpeakerSamples.count == maxSamples
        else {
            return
        }

        streamingSpeakerLastEvaluatedSamples = streamingSpeakerSamples.count

        do {
            let embedding = try await encoder.embed(
                audio: streamingSpeakerSamples,
                sampleRate: chunk.sampleRate
            )
            let previewThreshold = max(
                config.speaker.threshold - Self.previewSpeakerThresholdRelaxation,
                0.55
            )
            let rejectThreshold = max(
                previewThreshold - Self.previewSpeakerRejectMargin,
                0.35
            )
            let bestHumanSimilarity = await store.bestMatch(
                embedding: embedding,
                excludingRoles: [.faeSelf]
            )?.similarity

            switch Self.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: bestHumanSimilarity,
                acceptThreshold: previewThreshold,
                rejectThreshold: rejectThreshold
            ) {
            case .allow:
                streamingSpeakerVerdict = .allow
                debugLog(debugConsole, .speaker, "Streaming gate allowed speaker before segment close")
            case .reject:
                if let faeSelfSim = await store.matchesFaeSelf(embedding: embedding, threshold: previewThreshold),
                   echoSuppressor.isInSuppression {
                    currentSpeakerRole = .faeSelf
                    debugLog(
                        debugConsole,
                        .pipeline,
                        "Streaming gate echo-rejected sim=\(String(format: "%.3f", faeSelfSim)) before segment close"
                    )
                } else {
                    currentSpeakerRole = nil
                    debugLog(debugConsole, .speaker, "Streaming gate rejected unknown speaker before segment close")
                }
                currentSpeakerLabel = nil
                currentSpeakerDisplayName = nil
                currentSpeakerIsOwner = false
                currentSpeakerIsKnownNonOwner = false
                streamingSpeakerVerdict = .rejectUnknown
            case .undecided:
                break
            }
        } catch {
            debugLog(debugConsole, .speaker, "Streaming gate embed failed: \(error.localizedDescription)")
        }
    }

    private func shouldDropSegmentFromStreamingSpeakerGate() -> Bool {
        streamingSpeakerVerificationAvailable && streamingSpeakerVerdict == .rejectUnknown
    }

    private func evaluateSpeakerEmbedding(
        _ embedding: [Float],
        hasOwner: Bool,
        store: SpeakerProfileStore,
        durationSecs: Float,
        threshold: Float,
        progressiveEnrollment: Bool,
        source: String
    ) async -> Bool {
        if hasOwner, let match = await store.match(
            embedding: embedding,
            threshold: threshold,
            excludingRoles: [.faeSelf]
        ) {
            currentSpeakerLabel = match.label
            currentSpeakerDisplayName = match.displayName
            currentSpeakerRole = match.role
            currentSpeakerIsOwner = match.role == .owner
            currentSpeakerIsKnownNonOwner = match.role != .owner

            if progressiveEnrollment && config.speaker.progressiveEnrollment {
                await store.enrollIfBelowMax(
                    label: match.label,
                    embedding: embedding,
                    max: config.speaker.maxEnrollments
                )
            }

            NSLog(
                "PipelineCoordinator: speaker matched (%@): %@ (%@), similarity: %.3f",
                source,
                match.displayName,
                match.label,
                match.similarity
            )
            debugLog(
                debugConsole,
                .speaker,
                "Matched [\(source)]: \(match.displayName) (\(match.label)) sim=\(String(format: "%.3f", match.similarity)) owner=\(currentSpeakerIsOwner)"
            )
            return true
        }

        if !hasOwner {
            NSLog("PipelineCoordinator: no owner voice enrolled yet — awaiting voice_identity enrollment")
            debugLog(debugConsole, .speaker, "Owner not enrolled yet; speaker left as unknown")
            return true
        }

        if let faeSelfSim = await store.matchesFaeSelf(embedding: embedding, threshold: threshold) {
            if echoSuppressor.isInSuppression {
                NSLog(
                    "PipelineCoordinator: dropping %.1fs segment (%@ fae_self sim=%.3f, echo suppressor active)",
                    durationSecs,
                    source,
                    faeSelfSim
                )
                debugLog(
                    debugConsole,
                    .pipeline,
                    "Echo rejected [\(source)] (voice match fae_self sim=\(String(format: "%.3f", faeSelfSim)), suppressor active)"
                )
                return false
            }
            NSLog("PipelineCoordinator: fae_self match sim=%.3f ignored (%@, echo suppressor expired)", faeSelfSim, source)
            debugLog(
                debugConsole,
                .speaker,
                "fae_self sim=\(String(format: "%.3f", faeSelfSim)) [\(source)] outside echo window — passing as unknown"
            )
        } else {
            NSLog("PipelineCoordinator: speaker not recognized (%@)", source)
            debugLog(
                debugConsole,
                .speaker,
                "Not recognized [\(source)] (no match above threshold \(String(format: "%.2f", threshold)))"
            )
        }

        return true
    }

    private func effectiveIdleRearmSeconds() -> Int {
        Self.idleRearmSeconds(
            requireDirectAddress: effectiveRequireDirectAddress(),
            idleTimeoutS: config.conversation.idleTimeoutS,
            directAddressFollowupS: config.conversation.directAddressFollowupS
        )
    }

    private func scheduleIdleRearm() {
        idleRearmTask?.cancel()
        let timeout = effectiveIdleRearmSeconds()
        guard timeout > 0 else { return }

        idleRearmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sleepAfterIdleTimeout(seconds: timeout)
        }
    }

    private func sleepAfterIdleTimeout(seconds: Int) async {
        guard gateState == .active else { return }
        let inFollowup = engagedUntil.map { Date() < $0 } ?? false
        guard !assistantSpeaking, !assistantGenerating, !awaitingApproval, !inFollowup, deferredToolTasks.isEmpty else {
            scheduleIdleRearm()
            return
        }

        gateState = .idle
        engagedUntil = nil
        idleRearmTask = nil
        NSLog("PipelineCoordinator: gate → idle (idle timeout %ds)", seconds)
        await closeConversationSessionIfNeeded(reason: "idle_timeout")
    }

    private func effectiveVisionEnabled() -> Bool {
        visionEnabledLive ?? config.vision.enabled
    }

    private func effectiveVoiceIdentityLock() -> Bool {
        voiceIdentityLockLive ?? config.tts.voiceIdentityLock
    }

    private static func normalizeForPhraseMatch(_ text: String) -> String {
        let lower = text.lowercased()
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber {
                return ch
            }
            return " "
        }
        return String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func isConversationStopTrigger(_ text: String) -> Bool {
        let normalizedText = Self.normalizeForPhraseMatch(text)
        var phrases = config.conversation.sleepPhrases
        // Common apostrophe-less variant missed by strict literal matching.
        phrases.append("thatll do fae")

        for phrase in phrases {
            let normalizedPhrase = Self.normalizeForPhraseMatch(phrase)
            if !normalizedPhrase.isEmpty, normalizedText.contains(normalizedPhrase) {
                return true
            }
        }
        return false
    }

    private func wakeAddressMatch(in text: String, logDecision: Bool = false) -> TextProcessing.WakeAddressMatch? {
        let match = TextProcessing.findWakeAddressMatch(
            in: text,
            aliases: wakeAliases,
            wakeWord: config.conversation.wakeWord
        )

        if logDecision {
            if let match {
                let confidence = String(format: "%.2f", match.confidence)
                debugLog(
                    debugConsole,
                    .command,
                    "Wake match kind=\(match.kind.rawValue) alias=\(match.matchedAlias) token=\(match.matchedToken) conf=\(confidence)"
                )
            } else if let candidate = TextProcessing.extractWakeAliasCandidate(from: text) {
                debugLog(debugConsole, .command, "Wake miss candidate=\(candidate)")
            }
        }

        return match
    }

    private func isAddressedToFae(_ text: String, logDecision: Bool = false) -> Bool {
        wakeAddressMatch(in: text, logDecision: logDecision) != nil
    }

    private func learnWakeAliasIfNeeded(rawText: String) async {
        guard currentSpeakerIsOwner,
              let wakeStore = wakeWordProfileStore,
              let alias = TextProcessing.extractWakeAliasCandidate(from: rawText)
        else {
            return
        }

        if WakeWordProfileStore.baselineAliases.contains(alias) {
            return
        }

        await wakeStore.recordAliasCandidate(alias, source: "owner_runtime")
        wakeAliases = await wakeStore.allAliases()
        debugLog(debugConsole, .command, "Wake alias learned: \(alias)")
    }

    private func resetConversationSession(trigger: String, source: String) async {
        sleep()
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        activeCapabilityTicket = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        cancelDeferredToolJobs()
        resetStreamingSpeakerGate()
        resetStreamingWakeDetector()
        clearPendingSemanticTurn()
        await closeConversationSessionIfNeeded(reason: "conversation_reset")
        await conversationState.clear()
        await llmEngine.resetSession()
        currentTurnID = nil
        NSLog("PipelineCoordinator: conversation reset via %@ trigger: %@", source, trigger)
        debugLog(debugConsole, .pipeline, "Conversation reset (\(source)): \(trigger)")
    }

    private func ensureConversationSessionIfNeeded(startedAt: Date) async -> String? {
        if let activeConversationSessionID {
            updateWorkflowTraceSessionID(activeConversationSessionID, turnID: currentTurnID)
            return activeConversationSessionID
        }
        guard let sessionStore else { return nil }
        do {
            let session = try await sessionStore.openSession(
                kind: .main,
                speakerId: currentSpeakerLabel,
                startedAt: startedAt
            )
            activeConversationSessionID = session.id
            updateWorkflowTraceSessionID(session.id, turnID: currentTurnID)
            return session.id
        } catch {
            NSLog("PipelineCoordinator: session open error: %@", error.localizedDescription)
            return nil
        }
    }

    private func persistAcceptedUserTurnIfNeeded(_ text: String) async {
        guard let sessionStore, let turnID = currentTurnID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let createdAt = currentUtteranceTimestamp ?? Date()
        guard let sessionID = await ensureConversationSessionIfNeeded(startedAt: createdAt) else { return }
        do {
            _ = try await sessionStore.appendMessage(
                sessionId: sessionID,
                turnId: turnID,
                role: .user,
                content: trimmed,
                speakerId: currentSpeakerLabel,
                createdAt: createdAt
            )
        } catch {
            NSLog("PipelineCoordinator: session user message persist error: %@", error.localizedDescription)
        }
    }

    private func persistFinalAssistantTurnIfNeeded(_ text: String, turnID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let sessionStore, let sessionID = activeConversationSessionID {
            do {
                _ = try await sessionStore.appendMessage(
                    sessionId: sessionID,
                    turnId: turnID ?? currentTurnID,
                    role: .assistant,
                    content: trimmed,
                    createdAt: Date()
                )
            } catch {
                NSLog("PipelineCoordinator: session assistant message persist error: %@", error.localizedDescription)
            }
        }
        await finalizeWorkflowTraceIfNeeded(turnID: turnID ?? currentTurnID, assistantOutcome: trimmed, success: true)
    }

    private func closeConversationSessionIfNeeded(reason: String) async {
        guard let sessionStore, let sessionID = activeConversationSessionID else { return }
        do {
            try await sessionStore.closeSession(id: sessionID, endedAt: Date())
            activeConversationSessionID = nil
            debugLog(debugConsole, .pipeline, "Closed conversation session \(sessionID.prefix(8)) reason=\(reason)")
        } catch {
            NSLog("PipelineCoordinator: session close error (%@): %@", reason, error.localizedDescription)
        }
    }

    private func workflowTraceSource(
        proactiveContext: ProactiveRequestContext?,
        turnSource: ActionSource
    ) -> String {
        if let proactiveContext {
            return "scheduler:\(proactiveContext.taskId)"
        }
        return turnSource.rawValue
    }

    private func prepareWorkflowTraceContextIfNeeded(
        turnID: String?,
        userGoal: String,
        proactiveContext: ProactiveRequestContext?,
        turnSource: ActionSource
    ) {
        guard let turnID else { return }
        workflowTraceContexts[turnID] = WorkflowTraceContext(
            turnID: turnID,
            source: workflowTraceSource(proactiveContext: proactiveContext, turnSource: turnSource),
            userGoal: userGoal,
            sessionID: activeConversationSessionID,
            runID: nil
        )
    }

    private func pruneUnusedWorkflowTraceContexts(keeping activeTurnID: String?) {
        workflowTraceContexts = workflowTraceContexts.filter { turnID, context in
            if turnID == activeTurnID { return true }
            return context.runID != nil
        }
    }

    private func updateWorkflowTraceSessionID(_ sessionID: String?, turnID: String?) {
        guard let turnID, var context = workflowTraceContexts[turnID] else { return }
        context.sessionID = sessionID
        workflowTraceContexts[turnID] = context
    }

    private func ensureWorkflowTraceRun(turnID: String?) async -> String? {
        guard let workflowTraceStore,
              let turnID,
              var context = workflowTraceContexts[turnID]
        else {
            return nil
        }

        if let runID = context.runID {
            return runID
        }

        do {
            let run = try await workflowTraceStore.createRun(
                sessionId: context.sessionID,
                turnId: context.turnID,
                source: context.source,
                userGoal: context.userGoal
            )
            context.runID = run.id
            workflowTraceContexts[turnID] = context
            return run.id
        } catch {
            NSLog("PipelineCoordinator: workflow trace run create error: %@", error.localizedDescription)
            return nil
        }
    }

    private func recordWorkflowPreflightDenied(
        turnID: String?,
        callId: String,
        call: ToolCall,
        reason: String
    ) async {
        guard let workflowTraceStore,
              let runID = await ensureWorkflowTraceRun(turnID: turnID)
        else { return }

        if var context = turnID.flatMap({ workflowTraceContexts[$0] }) {
            context.toolSequence.append(call.name)
            workflowTraceContexts[context.turnID] = context
        }

        do {
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolCall,
                toolName: call.name,
                sanitizedInputJSON: Self.serializeArguments(call.arguments),
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolResult,
                toolName: call.name,
                sanitizedInputJSON: nil,
                outputPreview: reason,
                success: false,
                approved: false,
                latencyMs: nil
            )
        } catch {
            NSLog("PipelineCoordinator: workflow preflight trace error: %@", error.localizedDescription)
        }
    }

    private func recordWorkflowToolCall(
        turnID: String?,
        callId: String?,
        call: ToolCall
    ) async {
        guard let workflowTraceStore,
              let runID = await ensureWorkflowTraceRun(turnID: turnID)
        else { return }

        if let turnID, var context = workflowTraceContexts[turnID] {
            context.toolSequence.append(call.name)
            workflowTraceContexts[turnID] = context
        }

        do {
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolCall,
                toolName: call.name,
                sanitizedInputJSON: Self.serializeArguments(call.arguments),
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
        } catch {
            NSLog("PipelineCoordinator: workflow tool-call trace error: %@", error.localizedDescription)
        }
    }

    private func recordWorkflowToolResult(
        turnID: String?,
        callId: String?,
        call: ToolCall,
        result: ToolResult,
        approved: Bool?,
        latencyMs: Int?,
        damageControlIntervened: Bool = false
    ) async {
        guard let workflowTraceStore,
              let runID = await ensureWorkflowTraceRun(turnID: turnID)
        else { return }

        if let turnID, var context = workflowTraceContexts[turnID] {
            if approved == true {
                context.userApproved = true
            }
            if damageControlIntervened {
                context.damageControlIntervened = true
            }
            workflowTraceContexts[turnID] = context
        }

        do {
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolResult,
                toolName: call.name,
                sanitizedInputJSON: nil,
                outputPreview: result.output,
                success: !result.isError,
                approved: approved,
                latencyMs: latencyMs
            )
        } catch {
            NSLog("PipelineCoordinator: workflow tool-result trace error: %@", error.localizedDescription)
        }
    }

    private func finalizeWorkflowTraceIfNeeded(
        turnID: String?,
        assistantOutcome: String,
        success: Bool,
        status: WorkflowRunStatus = .completed
    ) async {
        guard let turnID,
              let context = workflowTraceContexts[turnID],
              let runID = context.runID,
              let workflowTraceStore
        else {
            workflowTraceContexts.removeValue(forKey: turnID ?? "")
            return
        }

        do {
            _ = try await workflowTraceStore.finalizeRun(
                id: runID,
                assistantOutcome: assistantOutcome,
                success: success,
                userApproved: context.userApproved,
                toolSequenceSignature: Self.workflowTraceSignature(for: context.toolSequence),
                damageControlIntervened: context.damageControlIntervened,
                status: status
            )
        } catch {
            NSLog("PipelineCoordinator: workflow trace finalize error: %@", error.localizedDescription)
        }

        workflowTraceContexts.removeValue(forKey: turnID)
    }

    private func abandonWorkflowTraceIfNeeded(turnID: String?, reason: String) async {
        guard let turnID,
              let context = workflowTraceContexts[turnID],
              let runID = context.runID,
              let workflowTraceStore
        else {
            workflowTraceContexts.removeValue(forKey: turnID ?? "")
            return
        }

        do {
            _ = try await workflowTraceStore.finalizeRun(
                id: runID,
                assistantOutcome: reason,
                success: false,
                userApproved: context.userApproved,
                toolSequenceSignature: Self.workflowTraceSignature(for: context.toolSequence),
                damageControlIntervened: context.damageControlIntervened,
                status: .abandoned
            )
        } catch {
            NSLog("PipelineCoordinator: workflow trace abandon error: %@", error.localizedDescription)
        }

        workflowTraceContexts.removeValue(forKey: turnID)
    }

    private func abandonAllWorkflowTraces(reason: String) async {
        let turnIDs = Array(workflowTraceContexts.keys)
        for turnID in turnIDs {
            await abandonWorkflowTraceIfNeeded(turnID: turnID, reason: reason)
        }
    }

    private static func workflowTraceSignature(for toolSequence: [String]) -> String? {
        let normalized = toolSequence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }
        return normalized.joined(separator: " -> ")
    }

    // MARK: - Speech Segment Queue

    private func startSpeechSegmentProcessingLoop() {
        guard speechSegmentTask == nil else { return }

        NSLog("PipelineCoordinator: speech segment queue started (depth=%d)", Self.speechSegmentQueueDepth)

        let stream = AsyncStream<SpeechSegment>(bufferingPolicy: .bufferingNewest(Self.speechSegmentQueueDepth)) {
            continuation in
            self.speechSegmentContinuation = continuation
        }

        speechSegmentTask = Task { [weak self] in
            guard let self else { return }
            for await segment in stream {
                guard !Task.isCancelled else { break }
                await self.handleSpeechSegment(segment)
            }
        }
    }

    private func stopSpeechSegmentProcessingLoop() async {
        speechSegmentContinuation?.finish()
        speechSegmentContinuation = nil
        speechSegmentTask?.cancel()
        await speechSegmentTask?.value
        speechSegmentTask = nil
        NSLog("PipelineCoordinator: speech segment queue stopped")
    }

    private func enqueueSpeechSegment(_ segment: SpeechSegment) {
        guard let continuation = speechSegmentContinuation else {
            // Queue not initialized — process synchronously as a safe fallback.
            Task { await self.handleSpeechSegment(segment) }
            return
        }

        let result = continuation.yield(segment)
        switch result {
        case .enqueued:
            debugLog(debugConsole, .pipeline, "Speech segment enqueued dur=\(String(format: "%.2f", segment.durationSeconds))s")
        case .dropped:
            speechSegmentsDroppedForBackpressure += 1
            NSLog("PipelineCoordinator: dropped speech segment due to backpressure (count=%d)", speechSegmentsDroppedForBackpressure)
            NSLog("phase1.audio_backpressure_drop_count=%d", speechSegmentsDroppedForBackpressure)
            debugLog(debugConsole, .pipeline, "⚠️ Speech segment dropped (backpressure) count=\(speechSegmentsDroppedForBackpressure)")
        case .terminated:
            NSLog("PipelineCoordinator: speech segment queue terminated — processing synchronously")
            Task { await self.handleSpeechSegment(segment) }
        @unknown default:
            Task { await self.handleSpeechSegment(segment) }
        }
    }

    // MARK: - Main Pipeline Loop

    private func runPipelineLoop(stream: AsyncStream<AudioChunk>) async {
        for await chunk in stream {
            guard !Task.isCancelled else { break }

            // VAD stage.
            let vadOutput = vad.processChunk(chunk)

            // Emit audio level for orb animation.
            eventBus.send(.audioLevel(vadOutput.rms))

            await updateStreamingSpeakerGate(chunk: chunk, vadOutput: vadOutput)
            await updateStreamingWakeDetector(chunk: chunk, vadOutput: vadOutput)

            if !firstAudioLatencyEmitted,
               let startedAt = pipelineStartedAt,
               (vadOutput.isSpeech || vadOutput.speechStarted || vadOutput.segment != nil)
            {
                let latencyMs = Date().timeIntervalSince(startedAt) * 1000
                firstAudioLatencyEmitted = true
                NSLog("phase1.first_audio_latency_ms=%.2f", latencyMs)
            }

            // Track barge-in only while the assistant is audibly speaking.
            // This avoids false interruptions during long LLM decode gaps where
            // assistantGenerating may be true but no speech is playing.
            if Self.shouldTrackBargeIn(assistantSpeaking: assistantSpeaking) {
                // Check deny cooldown — skip creating new barge-in candidates during cooldown.
                let inDenyCooldown = bargeInDenyCooldownUntil.map { Date() < $0 } ?? false

                // Skip when echo suppressor is active or barge-in is suppressed
                // (non-interruptible speakDirect) to prevent false triggers.
                pendingBargeIn = Self.advancePendingBargeIn(
                    pending: pendingBargeIn,
                    speechStarted: vadOutput.speechStarted,
                    isSpeech: vadOutput.isSpeech,
                    chunkSamples: chunk.samples,
                    rms: vadOutput.rms,
                    echoSuppression: echoSuppressor.isInSuppression,
                    bargeInSuppressed: bargeInSuppressed,
                    inDenyCooldown: inDenyCooldown
                )
                if vadOutput.isSpeech {
                    // Check barge-in confirmation.
                    let bargeInEnabled = bargeInEnabledLive ?? config.bargeIn.enabled
                    let confirmSamples = (config.bargeIn.confirmMs * config.audio.inputSampleRate) / 1000
                    if let barge = pendingBargeIn,
                       barge.speechSamples >= confirmSamples,
                       bargeInEnabled
                    {
                        pendingBargeIn = nil
                        await handleBargeInWithVerification(barge: barge)
                    }
                }
            } else {
                pendingBargeIn = nil
            }

            // Be more patient during an active conversation so short hesitations
            // do not prematurely cut the user turn.
            let inFollowup = engagedUntil.map { Date() < $0 } ?? false
            let silenceThresholdMs = Self.silenceThresholdMs(
                assistantSpeaking: assistantSpeaking,
                gateState: gateState,
                inFollowup: inFollowup,
                hasPendingSemanticTurn: pendingSemanticTurn != nil,
                configMinSilenceMs: config.vad.minSilenceDurationMs,
                bargeInSilenceMs: config.bargeIn.bargeInSilenceMs
            )
            vad.setSilenceThresholdMs(silenceThresholdMs)
            if assistantSpeaking {

                // Watchdog: if assistantSpeaking has been true for an unreasonably
                // long time (>60s), the TTS pipeline is stuck. Force-clear so the
                // mic isn't permanently dead. No single TTS utterance should take
                // more than 60 seconds.
                if let start = lastAssistantStart,
                   Date().timeIntervalSince(start) > 60
                {
                    NSLog("PipelineCoordinator: assistantSpeaking watchdog — stuck for >60s, force-clearing")
                    debugLog(debugConsole, .pipeline, "⚠️ assistantSpeaking watchdog fired (>60s) — force-clearing")
                    pendingTTSTask?.cancel()
                    pendingTTSTask = nil
                    markAssistantSpeechEnded(reason: "watchdog_timeout")
                    await playback.stop()
                }
            }

            // Process completed speech segment via bounded queue.
            if let segment = vadOutput.segment {
                defer {
                    resetStreamingSpeakerGate()
                    resetStreamingWakeDetector()
                }

                // Avoid stale-segment backlog during assistant generation/speech.
                // Barge-in is already handled in-chunk before segment completion.
                if assistantGenerating || assistantSpeaking {
                    debugLog(debugConsole, .pipeline, "Discarded segment while assistant busy dur=\(String(format: "%.2f", segment.durationSeconds))s")
                    continue
                }
                if shouldDropSegmentFromStreamingSpeakerGate() {
                    debugLog(
                        debugConsole,
                        .speaker,
                        "Dropped segment from streaming speaker gate dur=\(String(format: "%.2f", segment.durationSeconds))s"
                    )
                    publishVoiceAttention(
                        stage: "speaker",
                        decision: "dropped",
                        reason: "streaming_speaker_gate_reject",
                        rms: VoiceActivityDetector.computeRMS(segment.samples)
                    )
                    continue
                }
                lastUserTurnEndedAt = Date()
                enqueueSpeechSegment(segment)
            }
        }
    }

    // MARK: - Speech Segment Processing

    private func clearPendingSemanticTurn() {
        pendingSemanticTurnTask?.cancel()
        pendingSemanticTurnTask = nil
        pendingSemanticTurn = nil
    }

    private func flushPendingSemanticTurnIfNeeded() async {
        guard let pending = pendingSemanticTurn else { return }
        pendingSemanticTurn = nil
        pendingSemanticTurnTask = nil
        publishVoiceAttention(
            stage: "semantic",
            decision: "flushed",
            reason: "hold_timeout_elapsed",
            transcript: pending.text,
            wakeSource: pending.acousticWakeDetection != nil ? "acoustic" : nil,
            wakeScore: pending.acousticWakeDetection?.similarity,
            semanticState: "flushed",
            rms: pending.rms
        )
        await processRecognizedVoiceText(
            rawText: pending.rawText,
            text: pending.text,
            ownerProfileExists: pending.ownerProfileExists,
            speakerAllowsConversation: pending.speakerAllowsConversation,
            rms: pending.rms,
            durationSecs: pending.durationSecs,
            acousticWakeDetection: pending.acousticWakeDetection,
            allowSemanticHold: false
        )
    }

    private func processRecognizedVoiceText(
        rawText: String,
        text: String,
        ownerProfileExists: Bool,
        speakerAllowsConversation: Bool,
        rms: Float,
        durationSecs: Float,
        acousticWakeDetection: WakeWordAcousticDetector.Detection?,
        allowSemanticHold: Bool
    ) async {
        var effectiveRawText = rawText
        var effectiveText = text
        var effectiveAcousticWakeDetection = acousticWakeDetection

        if let pending = pendingSemanticTurn {
            effectiveRawText = pending.rawText + " " + rawText
            effectiveText = TextProcessing.correctNameRecognition(effectiveRawText)
            if effectiveAcousticWakeDetection == nil {
                effectiveAcousticWakeDetection = pending.acousticWakeDetection
            }
            pendingSemanticTurn = nil
            pendingSemanticTurnTask?.cancel()
            pendingSemanticTurnTask = nil
            debugLog(debugConsole, .stt, "Semantic turn merged: \(effectiveText)")
            publishVoiceAttention(
                stage: "semantic",
                decision: "merged",
                reason: "continued_utterance",
                transcript: effectiveText,
                wakeSource: effectiveAcousticWakeDetection != nil ? "acoustic" : nil,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                semanticState: "merged",
                rms: rms
            )
        }

        if (awaitingApproval || pendingGovernanceAction != nil) && !speakerAllowsConversation {
            debugLog(
                debugConsole,
                .speaker,
                "Ignoring approval/governance reply from non-conversational speaker role=\(currentSpeakerRole?.rawValue ?? "unknown")"
            )
            return
        }

        // Approval gate — while a tool approval is pending, only approval responses
        // are accepted. This prevents unrelated chatter/noise from being routed to the LLM.
        if awaitingApproval {
            if manualOnlyApprovalPending {
                // Damage-control manual-only approval: voice is never accepted.
                // Only a physical button press on the overlay can proceed.
                debugLog(debugConsole, .approval, "Voice rejected for manual-only approval: \(effectiveText)")
                await speakDirect("This operation requires a deliberate button press to confirm. Voice approval is not accepted — please use the overlay.")
            } else if !Self.shouldAcceptVoiceApprovalResponse(
                awaitingApproval: awaitingApproval,
                manualOnlyApprovalPending: manualOnlyApprovalPending,
                assistantSpeaking: assistantSpeaking
            ) {
                debugLog(debugConsole, .approval, "Ignoring voice approval while assistant is still speaking the approval prompt")
            } else if let decision = VoiceCommandParser.parseApprovalResponse(effectiveText),
               let manager = approvalManager,
               await manager.resolveMostRecent(decision: decision, source: "voice")
            {
                debugLog(debugConsole, .approval, "Tool approval decision via voice: \(decision.rawValue)")
                awaitingApproval = false
                manualOnlyApprovalPending = false
                let ack: String
                switch decision {
                case .yes:
                    ack = PersonalityManager.nextApprovalGranted()
                case .no:
                    ack = PersonalityManager.nextApprovalDenied()
                case .always:
                    ack = "Got it, I'll always allow that tool."
                case .approveAllReadOnly:
                    ack = "Okay, all read-only tools are now approved."
                case .approveAll:
                    ack = "Understood, all tools are now approved."
                }
                await speakDirect(ack)
            } else {
                let words = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
                if words > 2 {
                    debugLog(debugConsole, .approval, "Ambiguous tool approval response: \(effectiveText)")
                    await speakDirect(PersonalityManager.nextApprovalAmbiguous())
                }
            }
            return
        }

        if let pendingAction = pendingGovernanceAction {
            if let decision = VoiceCommandParser.parseApprovalResponse(effectiveText) {
                pendingGovernanceAction = nil
                debugLog(debugConsole, .approval, "Governance confirmation decision=\(decision.rawValue) action=\(pendingAction.action)")
                if decision != .no {
                    applyGovernanceAction(
                        action: pendingAction.action,
                        value: pendingAction.value,
                        source: "\(pendingAction.source)_confirm",
                        metadata: pendingAction.metadata
                    )
                    await speakDirect(pendingAction.successSpeech)
                } else {
                    await speakDirect(pendingAction.cancelledSpeech)
                }
            } else {
                let words = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
                if words > 2 {
                    debugLog(debugConsole, .approval, "Ambiguous governance confirmation response: \(effectiveText)")
                    await speakDirect(pendingAction.confirmationPrompt)
                }
            }
            return
        }

        // Echo detection — if the transcribed text is a fragment of the last
        // assistant response, the mic picked up speaker output. Drop it.
        if !lastAssistantResponseText.isEmpty {
            let sttLower = effectiveText.lowercased()
            let assistLower = lastAssistantResponseText.lowercased()
            if assistLower.contains(sttLower) || sttLower.contains(assistLower) {
                NSLog("PipelineCoordinator: dropping echo (STT matched last assistant response)")
                debugLog(debugConsole, .pipeline, "Echo dropped (text match): \"\(effectiveText.prefix(60))\"")
                return
            }
            let sttWords = Set(sttLower.split(separator: " ").filter { $0.count > 2 })
            let assistWords = Set(assistLower.split(separator: " ").filter { $0.count > 2 })
            if sttWords.count >= 3, !assistWords.isEmpty {
                let overlap = sttWords.intersection(assistWords)
                if Double(overlap.count) / Double(sttWords.count) >= 0.6 {
                    NSLog("PipelineCoordinator: dropping echo (%.0f%% word overlap with last response)",
                          Double(overlap.count) / Double(sttWords.count) * 100)
                    debugLog(debugConsole, .pipeline, "Echo dropped (\(Int(Double(overlap.count) / Double(sttWords.count) * 100))%% overlap): \"\(effectiveText.prefix(60))\"")
                    return
                }
            }
        }

        let ghostWords = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
        let ghostInFollowup = engagedUntil.map { Date() < $0 } ?? false
        if ghostWords <= 2,
           let lastStart = lastAssistantStart,
           Date().timeIntervalSince(lastStart) < 8.0,
           !effectiveText.lowercased().contains("fae"),
           !ghostInFollowup
        {
            NSLog("PipelineCoordinator: dropping post-speech ghost \"%@\" (%d words, %.1fs after speech start)",
                  effectiveText, ghostWords, Date().timeIntervalSince(lastStart))
            debugLog(debugConsole, .pipeline, "Ghost filtered: \"\(effectiveText)\" (\(ghostWords) words, recent speech)")
            return
        }

        if let wakeStore = wakeWordProfileStore {
            wakeAliases = await wakeStore.allAliases()
        }
        var wakeMatch = wakeAddressMatch(in: effectiveText, logDecision: true)
        var wakeSource: String?
        if wakeMatch != nil {
            wakeSource = "text"
        } else if effectiveAcousticWakeDetection != nil {
            wakeSource = "acoustic"
        }
        let wakeStrength: VoiceConversationWakeStrength? = {
            if effectiveAcousticWakeDetection != nil {
                return .exact
            }
            return wakeMatch.map { match in
                match.kind == .exact ? VoiceConversationWakeStrength.exact : .fuzzy
            }
        }()
        if !VoiceConversationPolicy.shouldHonorWakeMatch(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: currentSpeakerRole,
            wakeStrength: wakeStrength
        ) {
            if (wakeMatch != nil || effectiveAcousticWakeDetection != nil), ownerProfileExists, !firstOwnerEnrollmentActive {
                debugLog(
                    debugConsole,
                    .speaker,
                    "Ignoring wake match from non-conversational speaker role=\(currentSpeakerRole?.rawValue ?? "unknown")"
                )
            }
            wakeMatch = nil
            effectiveAcousticWakeDetection = nil
            wakeSource = nil
        }
        let addressedToFae = wakeMatch != nil || effectiveAcousticWakeDetection != nil
        if addressedToFae {
            await learnWakeAliasIfNeeded(rawText: effectiveRawText)
        }

        let inFollowup = engagedUntil.map { Date() < $0 } ?? false
        let shouldHoldShortFollowupFragment = allowSemanticHold
            && !addressedToFae
            && inFollowup
            && TextProcessing.isLikelyContinuationCue(effectiveText)
        if allowSemanticHold,
           Self.shouldDeferSemanticTurn(
                text: effectiveText,
                addressedToFae: addressedToFae,
                inFollowup: inFollowup,
                awaitingApproval: awaitingApproval,
                hasPendingGovernanceAction: pendingGovernanceAction != nil,
                firstOwnerEnrollmentActive: firstOwnerEnrollmentActive
           )
            || shouldHoldShortFollowupFragment
        {
            let pending = PendingSemanticTurn(
                rawText: effectiveRawText,
                text: effectiveText,
                ownerProfileExists: ownerProfileExists,
                speakerAllowsConversation: speakerAllowsConversation,
                rms: rms,
                durationSecs: durationSecs,
                acousticWakeDetection: effectiveAcousticWakeDetection
            )
            pendingSemanticTurn = pending
            pendingSemanticTurnTask?.cancel()
            pendingSemanticTurnTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.semanticTurnHoldMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                await self?.flushPendingSemanticTurnIfNeeded()
            }
            debugLog(debugConsole, .pipeline, "Semantic turn hold: \"\(effectiveText)\"")
            publishVoiceAttention(
                stage: "semantic",
                decision: "held",
                reason: shouldHoldShortFollowupFragment ? "short_followup_fragment" : "likely_incomplete_turn",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                semanticState: "held",
                rms: rms
            )
            return
        }

        let wordCount = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
        let attentionDecision = Self.fusedVoiceAttentionDecision(
            gateState: gateState,
            requireDirectAddress: effectiveRequireDirectAddress(),
            addressedToFae: addressedToFae,
            inFollowup: inFollowup,
            awaitingApproval: awaitingApproval,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerAllowsConversation: speakerAllowsConversation,
            wordCount: wordCount
        )

        switch attentionDecision {
        case .ignoreWhileSleeping:
            debugLog(debugConsole, .command, "Ignored while sleeping (not addressed): \(effectiveText)")
            publishVoiceAttention(
                stage: "attention",
                decision: "ignored_sleeping",
                reason: "sleeping_without_address",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            if wordCount >= 4,
               VoiceConversationPolicy.shouldOfferSleepHint(
                   ownerProfileExists: ownerProfileExists,
                   firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
                   speakerRole: currentSpeakerRole
               ),
               (lastSleepHintAt == nil || Date().timeIntervalSince(lastSleepHintAt!) > 20)
            {
                lastSleepHintAt = Date()
                await speakDirect("I’m resting right now—say hey Fae to wake me.")
            }
            return

        case .wakeAndContinue:
            publishVoiceAttention(
                stage: "attention",
                decision: "wake",
                reason: wakeSource == "acoustic" ? "acoustic_wake" : "text_wake",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            wake()

        case .dropDirectAddress:
            debugLog(debugConsole, .command, "Dropped (direct-address required): \(effectiveText)")
            publishVoiceAttention(
                stage: "attention",
                decision: "dropped_direct_address",
                reason: "direct_address_required",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            return

        case .dropShortIdle:
            debugLog(debugConsole, .pipeline, "Dropped short idle utterance: \"\(effectiveText)\"")
            publishVoiceAttention(
                stage: "attention",
                decision: "dropped_short_idle",
                reason: "idle_fragment_filter",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            return

        case .dropSpeaker:
            debugLog(
                debugConsole,
                .speaker,
                "Ignored speech from non-conversational speaker role=\(currentSpeakerRole?.rawValue ?? "unknown")"
            )
            publishVoiceAttention(
                stage: "attention",
                decision: "dropped_speaker",
                reason: "speaker_not_allowed",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            return

        case .allow:
            publishVoiceAttention(
                stage: "attention",
                decision: "accepted",
                reason: inFollowup ? "followup_window" : (wakeSource == nil ? "open_gate" : "addressed_to_fae"),
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            break
        }

        eventBus.send(.transcription(text: effectiveText, isFinal: true))

        if isConversationStopTrigger(effectiveText) {
            await resetConversationSession(trigger: effectiveText, source: "voice")
            return
        }

        let voiceCommand = VoiceCommandParser.parse(effectiveText)
        debugLog(debugConsole, .command, "Parsed voice command: \(String(describing: voiceCommand))")
        let voiceCommandStarted = Date()
        let handledVoiceCommand = await handleVoiceCommandIfNeeded(voiceCommand, originalText: effectiveText)
        let voiceCommandLatencyMs = Int(Date().timeIntervalSince(voiceCommandStarted) * 1000)
        recordVoiceCommandMetrics(
            command: String(describing: voiceCommand),
            handled: handledVoiceCommand,
            latencyMs: voiceCommandLatencyMs
        )
        if handledVoiceCommand {
            debugLog(debugConsole, .command, "Handled voice command in \(voiceCommandLatencyMs)ms")
            return
        }

        await processTranscription(
            text: effectiveText,
            wakeMatch: wakeMatch,
            rms: rms,
            durationSecs: durationSecs
        )
    }

    private func handleSpeechSegment(_ segment: SpeechSegment) async {
        let rms = VoiceActivityDetector.computeRMS(segment.samples)
        let durationSecs = Float(segment.samples.count) / Float(segment.sampleRate)

        // Capture wall-clock time from VAD onset for memory timestamps.
        currentUtteranceTimestamp = segment.capturedAt

        // Echo suppression check — pass segment onset time so the echo tail is
        // checked against when the speech STARTED, not when it finished processing.
        guard echoSuppressor.shouldAccept(
            durationSecs: durationSecs,
            rms: rms,
            awaitingApproval: awaitingApproval,
            segmentOnset: segment.capturedAt
        ) else {
            NSLog("PipelineCoordinator: dropping %.1fs speech segment (echo suppression, onset=%.1fs ago)",
                  durationSecs, Date().timeIntervalSince(segment.capturedAt))
            debugLog(debugConsole, .pipeline, "Echo suppressed: \(String(format: "%.1f", durationSecs))s segment (rms=\(String(format: "%.3f", rms)), onset=\(String(format: "%.1f", Date().timeIntervalSince(segment.capturedAt)))s ago)")
            return
        }

        // LLM quality gate — drop ambient noise.
        if rms < 0.008 && durationSecs > 3.0 {
            NSLog("PipelineCoordinator: dropping ambient segment (rms=%.4f, dur=%.1fs)", rms, durationSecs)
            return
        }

        // Speaker identification (best-effort, non-blocking).
        currentSpeakerLabel = nil
        currentSpeakerDisplayName = nil
        currentSpeakerRole = nil
        currentSpeakerIsOwner = false
        currentSpeakerIsKnownNonOwner = false
        var speakerVerificationCompleted = false
        // Speaker recognition is always on — no config gate.
        if let encoder = speakerEncoder, await encoder.isLoaded,
           let store = speakerProfileStore
        {
            do {
                let hasOwner = await store.hasOwnerProfile()
                let previewDecision = await previewSpeakerVerification(
                    segment: segment,
                    encoder: encoder,
                    store: store,
                    hasOwner: hasOwner
                )

                switch previewDecision {
                case .echoRejected(let faeSelfSim):
                    NSLog(
                        "PipelineCoordinator: dropping %.1fs segment (preview fae_self sim=%.3f, echo suppressor active)",
                        durationSecs,
                        faeSelfSim
                    )
                    debugLog(
                        debugConsole,
                        .pipeline,
                        "Echo rejected [preview] (voice match fae_self sim=\(String(format: "%.3f", faeSelfSim)), suppressor active)"
                    )
                    return

                case .rejectUnknown:
                    speakerVerificationCompleted = true
                    NSLog("PipelineCoordinator: preview speaker verification rejected unknown speaker")
                    debugLog(debugConsole, .speaker, "Preview rejected unknown speaker before full embed/STT")

                case .useEmbedding(let embedding):
                    speakerVerificationCompleted = true
                    guard await evaluateSpeakerEmbedding(
                        embedding,
                        hasOwner: hasOwner,
                        store: store,
                        durationSecs: durationSecs,
                        threshold: max(config.speaker.threshold - Self.previewSpeakerThresholdRelaxation, 0.55),
                        progressiveEnrollment: true,
                        source: "preview"
                    ) else {
                        return
                    }

                case .fallBackToFullSegment:
                    let embedding = try await encoder.embed(
                        audio: segment.samples,
                        sampleRate: segment.sampleRate
                    )
                    speakerVerificationCompleted = true

                    guard await evaluateSpeakerEmbedding(
                        embedding,
                        hasOwner: hasOwner,
                        store: store,
                        durationSecs: durationSecs,
                        threshold: config.speaker.threshold,
                        progressiveEnrollment: true,
                        source: "full"
                    ) else {
                        return
                    }
                }
            } catch {
                NSLog("PipelineCoordinator: speaker embed failed: %@", error.localizedDescription)
                debugLog(debugConsole, .speaker, "Embed failed: \(error.localizedDescription)")
            }
        } else {
            debugLog(debugConsole, .speaker, "Speaker encoder not loaded — owner verification skipped")
        }

        // Liveness enforcement: reject speech with low liveness score in enforce mode.
        let ownerProfileExistsForLiveness = await speakerProfileStore?.hasOwnerProfile() ?? false
        if config.voiceIdentity.enabled,
           config.voiceIdentity.mode == "enforce",
           config.speaker.livenessThreshold > 0,
           let encoder = speakerEncoder,
           let liveness = await encoder.lastLivenessResult,
           liveness.score < config.speaker.livenessThreshold
        {
            NSLog("PipelineCoordinator: rejecting speech — liveness score %.3f below threshold %.2f",
                  liveness.score, config.speaker.livenessThreshold)
            if VoiceConversationPolicy.shouldOfferSleepHint(
                ownerProfileExists: ownerProfileExistsForLiveness,
                firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
                speakerRole: currentSpeakerRole
            ) {
                await speakDirect("I'm not sure that's a live voice. Could you speak directly to me?")
            } else {
                debugLog(debugConsole, .speaker, "Dropping low-liveness speech from non-conversational speaker")
            }
            return
        }

        let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
        let speakerAllowsConversation = VoiceConversationPolicy.allowsConversation(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: currentSpeakerRole
        )

        if Self.shouldSkipSTTAfterSpeakerVerification(
            ownerProfileExists: ownerProfileExists,
            speakerVerificationCompleted: speakerVerificationCompleted,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: currentSpeakerRole
        ) {
            debugLog(
                debugConsole,
                .speaker,
                "Skipped STT for non-conversational speaker role=\(currentSpeakerRole?.rawValue ?? "unknown")"
            )
            return
        }

        // Speaker change detection.
        if let prevLabel = previousSpeakerLabel,
           let currLabel = currentSpeakerLabel,
           prevLabel != currLabel
        {
            NSLog("PipelineCoordinator: speaker change detected: %@ → %@", prevLabel, currLabel)
        }
        previousSpeakerLabel = currentSpeakerLabel
        utterancesSinceOwnerVerified = currentSpeakerIsOwner ? 0 : utterancesSinceOwnerVerified + 1

        await refreshDegradedModeIfNeeded(context: "before_stt")

        // STT stage.
        guard await sttEngine.isLoaded else {
            NSLog("PipelineCoordinator: STT not loaded, dropping segment")
            return
        }

        do {
            let sttStartedAt = Date()
            let result = try await sttEngine.transcribe(
                samples: segment.samples,
                sampleRate: segment.sampleRate
            )
            let sttLatencyMs = Date().timeIntervalSince(sttStartedAt) * 1000
            NSLog("phase1.stt_latency_ms=%.2f", sttLatencyMs)

            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { return }

            // Correct common ASR misrecognitions of "Fae".
            let text = TextProcessing.correctNameRecognition(rawText)

            NSLog("PipelineCoordinator: STT → \"%@\"", text)
            debugLog(debugConsole, .stt, text)

            let acousticWakeDetection = await acousticWakeDetectionForSegment(segment)

            await processRecognizedVoiceText(
                rawText: rawText,
                text: text,
                ownerProfileExists: ownerProfileExists,
                speakerAllowsConversation: speakerAllowsConversation,
                rms: rms,
                durationSecs: durationSecs,
                acousticWakeDetection: acousticWakeDetection,
                allowSemanticHold: true
            )

        } catch {
            NSLog("PipelineCoordinator: STT error: %@", error.localizedDescription)
        }
    }

    // MARK: - LLM Processing

    private func processTranscription(
        text: String,
        wakeMatch: TextProcessing.WakeAddressMatch? = nil,
        rms: Float?,
        durationSecs: Float?,
        proactiveContext: ProactiveRequestContext? = nil,
        turnSource: ActionSource = .voice,
        playsThinkingTone: Bool = true,
        allowsAudibleOutput: Bool = true
    ) async {
        currentTurnID = UUID().uuidString
        ttfaEmittedForCurrentTurn = false
        if proactiveContext != nil {
            lastUserTurnEndedAt = nil
        } else if lastUserTurnEndedAt == nil {
            // Text injection path has no VAD segment-close marker.
            lastUserTurnEndedAt = Date()
        }

        debugLog(debugConsole, .qa, "Process transcription [turn=\(currentTurnID?.prefix(8) ?? "none")]: \(text)")

        // Extract query if name-addressed.
        var queryText = text
        if let match = wakeMatch ?? wakeAddressMatch(in: text) {
            queryText = TextProcessing.extractQueryAroundName(in: text, nameRange: match.range)
            debugLog(debugConsole, .command, "Direct-address extraction: \(queryText)")
            // Refresh follow-up window.
            engage()
            if queryText.isEmpty {
                debugLog(debugConsole, .command, "Wake-only utterance ignored after direct-address extraction")
                return
            }
        }

        // If assistant is still active, handle based on barge-in setting.
        if assistantSpeaking || assistantGenerating {
            let bargeInEnabled = bargeInEnabledLive ?? config.bargeIn.enabled
            if bargeInEnabled {
                // Barge-in: interrupt speech and process the new transcription.
                markGenerationInterrupted()
                pendingTTSTask?.cancel()
                pendingTTSTask = nil
                await playback.stop()
            } else {
                // Barge-in disabled: drop the transcription entirely — do NOT
                // interrupt active speech. Stray noise / echo that slipped through
                // the echo suppressor should never cut off the assistant mid-sentence.
                NSLog("PipelineCoordinator: dropping transcription while assistant active (barge-in disabled): \"%@\"", text)
                debugLog(debugConsole, .pipeline, "Dropped transcription (barge-in off, assistant active): \"\(text.prefix(60))\"")
                return
            }
        }

        let forceFastCommandPath = shouldForceThinkingSuppression(for: queryText)
        if forceFastCommandPath {
            debugLog(debugConsole, .command, "Force thinking suppression for short control-style utterance: \(queryText)")
        }

        explicitUserAuthorizationForTurn = Self.detectExplicitUserAuthorization(in: queryText)
        if explicitUserAuthorizationForTurn {
            debugLog(debugConsole, .approval, "Explicit user authorization detected for turn")
        }

        if proactiveContext == nil {
            await userInteractionHandler?()
        }

        if proactiveContext == nil,
           await handleDeterministicEasyTurnIfNeeded(
                originalUserText: text,
                queryText: queryText,
                allowsAudibleOutput: allowsAudibleOutput,
                tag: proactiveContext?.conversationTag
           )
        {
            return
        }

        // Unified pipeline: LLM decides when to use tools via <tool_call> markup.
        await generateWithTools(
            userText: queryText,
            isToolFollowUp: false,
            turnCount: 0,
            forceSuppressThinking: forceFastCommandPath,
            proactiveContext: proactiveContext,
            turnSource: turnSource,
            playsThinkingTone: playsThinkingTone,
            allowsAudibleOutput: allowsAudibleOutput
        )
    }

    private func handleDeterministicEasyTurnIfNeeded(
        originalUserText: String,
        queryText: String,
        allowsAudibleOutput: Bool,
        tag: String?
    ) async -> Bool {
        let rememberedName = await resolvedRememberedUserName()
        guard let action = Self.deterministicEasyTurnAction(
            for: queryText,
            rememberedUserName: rememberedName
        ) else {
            return false
        }

        let responseText: String
        switch action {
        case .arithmetic(let reply):
            responseText = reply
        case .rememberUserName(let name, let reply):
            sessionDeclaredUserName = name
            responseText = reply
        case .recallUserName(let reply):
            responseText = reply
        }

        assistantGenerating = true
        eventBus.send(.assistantGenerating(true))
        await conversationState.addUserMessage(
            queryText,
            speakerDisplayName: currentSpeakerDisplayName,
            speakerId: currentSpeakerLabel,
            tag: tag
        )
        await persistAcceptedUserTurnIfNeeded(queryText)
        lastAssistantResponseText = responseText
        if allowsAudibleOutput {
            await speakText(responseText, isFinal: true)
        } else {
            eventBus.send(.assistantText(text: responseText, isFinal: true))
        }
        await conversationState.addAssistantMessage(responseText, tag: tag)
        await synchronizeLLMSession()
        await persistFinalAssistantTurnIfNeeded(responseText)

        let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
        if VoiceConversationPolicy.shouldPersistSpeechMemory(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: currentSpeakerRole
        ) {
            let turnId = newMemoryId(prefix: "turn")
            _ = await memoryOrchestrator?.capture(
                turnId: turnId,
                userText: originalUserText,
                assistantText: responseText,
                speakerId: currentSpeakerLabel,
                utteranceTimestamp: currentUtteranceTimestamp
            )
        }

        endAssistantGeneration()
        engage()
        return true
    }

    private func resolvedRememberedUserName() async -> String? {
        if let sessionDeclaredUserName,
           !sessionDeclaredUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sessionDeclaredUserName
        }

        if let displayName = currentSpeakerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty,
           displayName.caseInsensitiveCompare("Owner") != .orderedSame
        {
            return displayName
        }

        if let storedName = await memoryOrchestrator?.rememberedUserName()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedName.isEmpty
        {
            return storedName
        }

        if let ownerName = await speakerProfileStore?.ownerDisplayName()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ownerName.isEmpty,
           ownerName.caseInsensitiveCompare("Owner") != .orderedSame
        {
            return ownerName
        }

        return nil
    }

    private func shouldForceThinkingSuppression(for text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let words = lower.split(whereSeparator: { $0.isWhitespace }).count
        if words <= 4 && lower.contains("settings") {
            return true
        }
        guard words <= 10 else { return false }

        let controlTargets = [
            "settings", "preferences", "canvas", "conversation", "discussions",
            "permissions", "tool mode", "tools", "vision", "thinking", "barge", "direct address",
        ]
        guard controlTargets.contains(where: { lower.contains($0) }) else {
            return false
        }

        let controlVerbs = [
            "open", "close", "hide", "show", "enable", "disable", "turn on", "turn off",
            "set", "switch", "bring up", "pull up", "dismiss",
        ]
        return controlVerbs.contains(where: { lower.contains($0) })
            || lower.hasPrefix("can you")
            || lower.hasPrefix("could you")
            || lower.hasPrefix("please")
    }

    private static func detectExplicitUserAuthorization(in text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let directPhrases = [
            "go ahead", "do it", "please do", "please run", "run it", "yes do", "you can",
            "i approve", "approved", "confirm this", "proceed", "that is fine",
            "run the command", "execute this bash command", "in the terminal, run",
        ]
        if directPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        // Compact imperative requests are usually explicit enough.
        let tokens = lower.split(whereSeparator: { $0.isWhitespace })
        if tokens.count <= 4 {
            let starts = ["read", "write", "edit", "search", "fetch", "open", "close", "list", "show", "run"]
            if let first = tokens.first, starts.contains(String(first)) {
                return true
            }
        }

        return false
    }

    // MARK: - Voice Commands

    private func handleVoiceCommandIfNeeded(
        _ command: VoiceCommandParser.VoiceCommand,
        originalText: String
    ) async -> Bool {
        debugLog(debugConsole, .command, "Evaluate command: \(String(describing: command))")
        switch command {
        case .showCanvas:
            eventBus.send(.voiceCommandRecognized("show_canvas"))
            eventBus.send(.canvasVisibility(true))
            await speakDirect("Opening the canvas.")
            return true

        case .hideCanvas:
            eventBus.send(.voiceCommandRecognized("hide_canvas"))
            eventBus.send(.canvasVisibility(false))
            await speakDirect("Hiding the canvas.")
            return true

        case .showConversation:
            eventBus.send(.voiceCommandRecognized("show_conversation"))
            eventBus.send(.conversationVisibility(true))
            await speakDirect("Opening the conversation.")
            return true

        case .hideConversation:
            eventBus.send(.voiceCommandRecognized("hide_conversation"))
            eventBus.send(.conversationVisibility(false))
            await speakDirect("Hiding the conversation.")
            return true

        case .showSettings:
            eventBus.send(.voiceCommandRecognized("show_settings"))
            let openResult: (primary: Bool, fallback: Bool) = await MainActor.run {
                let primary = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                let fallback = !primary
                    ? NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    : false
                NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
                return (primary: primary, fallback: fallback)
            }
            debugLog(
                debugConsole,
                .command,
                "Show settings direct open primary=\(openResult.primary) fallback=\(openResult.fallback)"
            )
            await speakDirect("Opening settings.")
            return true

        case .hideSettings:
            eventBus.send(.voiceCommandRecognized("hide_settings"))
            await MainActor.run {
                NotificationCenter.default.post(name: .faeCloseSettingsRequested, object: nil)
            }
            await speakDirect("Closing settings.")
            return true

        case .showPermissionsCanvas:
            eventBus.send(.voiceCommandRecognized("show_permissions_canvas"))
            let html = await buildToolsAndPermissionsCanvasHTML(triggerText: originalText)
            eventBus.send(.canvasContent(html: html, append: false))
            eventBus.send(.canvasVisibility(true))
            await speakDirect("Here are your current tools and permission levels.")
            return true

        case .setToolMode(let requestedMode):
            eventBus.send(.voiceCommandRecognized("set_tool_mode:\(requestedMode)"))
            guard await canRunGovernanceVoiceTransaction(originalText) else { return true }

            let normalized = requestedMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let currentMode = effectiveToolMode()
            if currentMode == normalized {
                await speakDirect("Tool mode is already \(displayToolMode(normalized)).")
                return true
            }

            if normalized == "full_no_approval" {
                pendingGovernanceAction = PendingGovernanceAction(
                    action: "set_tool_mode",
                    value: .string(normalized),
                    metadata: [:],
                    source: "voice",
                    confirmationPrompt: "Please say yes or no to confirm the tool mode change.",
                    successSpeech: "Done. Tool mode is now \(displayToolMode(normalized)).",
                    cancelledSpeech: "Okay, I won't change tool mode."
                )
                await speakDirect("This removes confirmation prompts for risky actions. Are you sure? Say yes or no.")
                return true
            }

            applyGovernanceAction(action: "set_tool_mode", value: .string(normalized), source: "voice")
            await speakDirect("Done. Tool mode is now \(displayToolMode(normalized)).")
            return true

        case .setThinking(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "llm.thinking_enabled",
                enabled: enabled,
                currentValue: (thinkingLevelLive ?? config.llm.resolvedThinkingLevel).enablesThinking,
                voiceTag: "set_thinking",
                highRiskWhenEnabled: false,
                onApplied: "Done. Thinking mode is now \(enabled ? "on" : "off")."
            )

        case .setBargeIn(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "barge_in.enabled",
                enabled: enabled,
                currentValue: bargeInEnabledLive ?? config.bargeIn.enabled,
                voiceTag: "set_barge_in",
                highRiskWhenEnabled: false,
                onApplied: "Done. Barge-in is now \(enabled ? "enabled" : "disabled")."
            )

        case .setDirectAddress(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "conversation.require_direct_address",
                enabled: enabled,
                currentValue: effectiveRequireDirectAddress(),
                voiceTag: "set_direct_address",
                highRiskWhenEnabled: false,
                onApplied: "Done. Direct-address requirement is now \(enabled ? "on" : "off")."
            )

        case .setVision(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "vision.enabled",
                enabled: enabled,
                currentValue: effectiveVisionEnabled(),
                voiceTag: "set_vision",
                highRiskWhenEnabled: enabled,
                onApplied: "Done. Vision is now \(enabled ? "enabled" : "disabled")."
            )

        case .setVoiceIdentityLock(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "tts.voice_identity_lock",
                enabled: enabled,
                currentValue: effectiveVoiceIdentityLock(),
                voiceTag: "set_voice_identity_lock",
                highRiskWhenEnabled: !enabled,
                onApplied: enabled
                    ? "Done. Voice identity lock is now on."
                    : "Done. Voice identity lock is now off."
            )

        case .requestPermission(let capability):
            eventBus.send(.voiceCommandRecognized("request_permission:\(capability)"))
            guard await canRunGovernanceVoiceTransaction(originalText) else { return true }
            await requestPermissionFlow(capability: capability, source: "voice")
            return true

        case .switchModel, .approvalResponse, .none:
            return false
        }
    }

    private func canRunGovernanceVoiceTransaction(_ originalText: String) async -> Bool {
        let inFollowup = engagedUntil.map { Date() < $0 } ?? false
        let addressed = isAddressedToFae(originalText)
        if !addressed && !inFollowup {
            debugLog(debugConsole, .governance, "Rejected governance command (not addressed): \(originalText)")
            await speakDirect("Please say my name when changing governance or permission settings.")
            return false
        }
        debugLog(debugConsole, .governance, "Accepted governance command (addressed=\(addressed), followup=\(inFollowup))")
        return true
    }

    private func handleBooleanGovernanceCommand(
        originalText: String,
        key: String,
        enabled: Bool,
        currentValue: Bool,
        voiceTag: String,
        highRiskWhenEnabled: Bool,
        onApplied: String
    ) async -> Bool {
        eventBus.send(.voiceCommandRecognized("\(voiceTag):\(enabled ? "on" : "off")"))
        guard await canRunGovernanceVoiceTransaction(originalText) else { return true }

        if currentValue == enabled {
            debugLog(debugConsole, .governance, "No-op setting change: \(key)=\(enabled)")
            await speakDirect("\(displaySettingName(key)) is already \(enabled ? "on" : "off").")
            return true
        }

        if highRiskWhenEnabled {
            debugLog(debugConsole, .approval, "Queued confirmation for high-risk setting: \(key)=\(enabled)")
            pendingGovernanceAction = PendingGovernanceAction(
                action: "set_setting",
                value: .bool(enabled),
                metadata: ["key": key],
                source: "voice",
                confirmationPrompt: "Please say yes or no to confirm the setting change.",
                successSpeech: onApplied,
                cancelledSpeech: "Okay, I won't change that setting."
            )
            await speakDirect("This setting can reduce safeguards. Are you sure? Say yes or no.")
            return true
        }

        debugLog(debugConsole, .governance, "Apply setting via voice: \(key)=\(enabled)")
        applyGovernanceAction(
            action: "set_setting",
            value: .bool(enabled),
            source: "voice",
            metadata: ["key": key]
        )
        await speakDirect(onApplied)
        return true
    }

    private func requestPermissionFlow(capability: String, source: String) async {
        let label = capability.replacingOccurrences(of: "_", with: " ")
        debugLog(debugConsole, .governance, "Permission request via \(source): \(capability)")
        applyGovernanceAction(
            action: "request_permission",
            value: .string(capability),
            source: source,
            metadata: ["capability": capability]
        )
        await speakDirect("Okay. Requesting \(label) permission now.")

        let trigger = "permission refresh: \(capability)"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            await self.logGovernanceDebug("Refreshing permissions snapshot after request: \(capability)")
            let html = await self.buildToolsAndPermissionsCanvasHTML(triggerText: trigger)
            self.eventBus.send(.canvasContent(html: html, append: false))
            self.eventBus.send(.canvasVisibility(true))
        }
    }

    private func buildToolsAndPermissionsCanvasHTML(triggerText: String) async -> String {
        let snapshot = await buildToolsAndPermissionsSnapshot(triggerText: triggerText)
        return snapshot.toCanvasHTML()
    }

    private func buildToolsAndPermissionsSnapshot(triggerText: String) async -> ToolPermissionSnapshot {
        let mode = effectiveToolMode()
        let permissions = await MainActor.run { PermissionStatusProvider.current() }
        let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
        let approvalSnapshot = await ApprovedToolsStore.shared.approvalSnapshot()

        let speakerState: String = {
            if currentSpeakerIsOwner { return "Owner verified" }
            if currentSpeakerIsKnownNonOwner { return "Known non-owner speaker" }
            if currentSpeakerLabel != nil { return "Recognized speaker" }
            return "Speaker unknown"
        }()

        return CapabilitySnapshotService.buildSnapshot(
            triggerText: triggerText,
            toolMode: mode,
            privacyMode: effectivePrivacyMode(),
            speakerState: speakerState,
            ownerGateEnabled: config.speaker.requireOwnerForTools,
            ownerProfileExists: ownerProfileExists,
            permissions: permissions,
            thinkingEnabled: (thinkingLevelLive ?? config.llm.resolvedThinkingLevel).enablesThinking,
            bargeInEnabled: bargeInEnabledLive ?? config.bargeIn.enabled,
            requireDirectAddress: effectiveRequireDirectAddress(),
            visionEnabled: effectiveVisionEnabled(),
            voiceIdentityLock: effectiveVoiceIdentityLock(),
            approvalSnapshot: approvalSnapshot,
            registry: registry
        )
    }

    private func applyGovernanceAction(
        action: String,
        value: AnySendableValue,
        source: String,
        metadata: [String: String] = [:]
    ) {
        var userInfo: [String: Any] = [
            "action": action,
            "source": source,
        ]

        switch value {
        case .string(let text):
            userInfo["value"] = text
        case .bool(let bool):
            userInfo["value"] = bool
        }

        for (key, val) in metadata {
            userInfo[key] = val
        }

        let metadataSummary = metadata.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        debugLog(debugConsole, .governance, "Apply governance action=\(action) source=\(source) value=\(String(describing: userInfo["value"])) meta=[\(metadataSummary)]")

        eventBus.send(.voiceCommandRecognized("governance_applied:\(action):\(source)"))

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .faeGovernanceActionRequested,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func displaySettingName(_ key: String) -> String {
        switch key {
        case "llm.thinking_enabled":
            return "Thinking mode"
        case "barge_in.enabled":
            return "Barge-in"
        case "conversation.require_direct_address":
            return "Direct-address requirement"
        case "vision.enabled":
            return "Vision"
        case "tts.voice_identity_lock":
            return "Voice identity lock"
        default:
            return key
        }
    }

    private func recordVoiceCommandMetrics(command: String, handled: Bool, latencyMs: Int) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "fae.voice.commands.total") + 1, forKey: "fae.voice.commands.total")
        if handled {
            defaults.set(defaults.integer(forKey: "fae.voice.commands.handled") + 1, forKey: "fae.voice.commands.handled")
        }
        defaults.set(latencyMs, forKey: "fae.voice.commands.last_latency_ms")
        defaults.set(Date().timeIntervalSince1970, forKey: "fae.voice.commands.last_ts")
        NSLog("phase1.voice_command trace command=%@ handled=%d latency_ms=%d", command, handled ? 1 : 0, latencyMs)
    }

    private func logGovernanceDebug(_ text: String) {
        debugLog(debugConsole, .governance, text)
    }

    private func displayToolMode(_ mode: String) -> String {
        switch mode {
        case "off":
            return "off"
        case "read_only":
            return "read only"
        case "read_write":
            return "read write"
        case "full":
            return "full"
        case "full_no_approval":
            return "full no approval"
        default:
            return mode
        }
    }

    private static func shouldShowCapabilitiesCanvas(triggerText: String, modelResponse: String) -> Bool {
        let lowerTrigger = triggerText.lowercased()
        let lowerResponse = stripThinkContent(modelResponse).lowercased()

        if lowerResponse.contains("<show_capabilities/>") || lowerResponse.contains("<show_capabilities>") {
            return true
        }

        let queryPhrases = [
            "what can you do",
            "what are your capabilities",
            "what are your skills",
            "show me your skills",
            "show your skills",
            "show capabilities",
            "help me understand what you can do",
        ]
        return queryPhrases.contains { lowerTrigger.contains($0) }
    }

    private func trustedCapabilitiesCanvasHTML() -> String {
        let toolCount = registry.toolNames.count
        return """
        <html>
        <head>
          <meta name='viewport' content='width=device-width, initial-scale=1' />
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1015; color: #e9e9ef; padding: 18px; line-height: 1.45; }
            .panel { border: 1px solid #2a2d38; border-radius: 10px; padding: 12px; margin-bottom: 10px; background: #171a23; }
            .chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
            .chip { font-size: 11px; text-decoration: none; color: #e9e9ef; border: 1px solid #3d4354; padding: 5px 9px; border-radius: 999px; background: #202533; }
            ul { margin: 8px 0 0 18px; padding: 0; }
            li { margin: 4px 0; }
            .hint { color: #99a0b6; font-size: 12px; }
          </style>
        </head>
        <body>
          <div class='panel'>
            <p><strong>What I can do for you</strong></p>
            <ul>
              <li>Voice identity + owner-aware safety</li>
              <li>Persistent memory and relationship context</li>
              <li>\(toolCount) built-in tools (read/write/edit/bash, web, calendar, reminders, contacts, mail, notes)</li>
              <li>Vision tools (camera, screenshot, read_screen)</li>
              <li>Scheduler + proactive morning/overnight workflows</li>
              <li>Skill system (activate, run, create, update)</li>
              <li>Self-configuration of behavior and preferences</li>
            </ul>
            <div class='chips'>
              <a class='chip' href='fae-action://open_settings?source=canvas'>Open settings</a>
              <a class='chip' href='fae-action://start_owner_enrollment?source=canvas'>Voice enrollment</a>
            </div>
            <p class='hint'>Tip: ask “show tools and permissions” for a live policy snapshot.</p>
          </div>
        </body>
        </html>
        """
    }

    private func maybeShowCapabilitiesCanvas(triggerText: String, modelResponse: String) {
        guard Self.shouldShowCapabilitiesCanvas(triggerText: triggerText, modelResponse: modelResponse) else {
            return
        }
        let html = trustedCapabilitiesCanvasHTML()
        eventBus.send(.canvasContent(html: html, append: false))
        eventBus.send(.canvasVisibility(true))
        debugLog(debugConsole, .qa, "Capabilities canvas opened from trusted template")
    }

    /// Unified LLM generation with inline tool execution.
    ///
    /// Streams tokens to TTS. If the model outputs `<tool_call>` markup, executes the
    /// tools and re-generates with the results. Recurses up to `maxToolTurns` times.
    private func generateWithTools(
        userText: String,
        isToolFollowUp: Bool,
        turnCount: Int,
        forceSuppressThinking: Bool = false,
        generationContext providedGenerationContext: GenerationContext? = nil,
        generationID providedGenerationID: UUID? = nil,
        proactiveContext: ProactiveRequestContext? = nil,
        turnSource: ActionSource = .voice,
        playsThinkingTone: Bool = true,
        allowsAudibleOutput: Bool = true
    ) async {
        let maxToolTurns = 5

        let generationID: UUID
        if let providedGenerationID {
            generationID = providedGenerationID
            // If this recursion belongs to an old turn, drop it immediately.
            if activeGenerationID != generationID {
                debugLog(debugConsole, .pipeline, "Drop stale generation recursion id=\(generationID.uuidString.prefix(8))")
                return
            }
        } else {
            generationID = UUID()
            activeGenerationID = generationID
            debugLog(debugConsole, .pipeline, "Generation started id=\(generationID.uuidString.prefix(8))")
        }

        // Reset computer-use step counter and duplicate-tool guard at the start of each user turn.
        if !isToolFollowUp {
            computerUseStepCount = 0
            seenToolCallSignatures = []
            pruneUnusedWorkflowTraceContexts(keeping: currentTurnID)
            prepareWorkflowTraceContextIfNeeded(
                turnID: currentTurnID,
                userGoal: userText,
                proactiveContext: proactiveContext,
                turnSource: turnSource
            )
        }

        await refreshDegradedModeIfNeeded(context: "before_generation")

        let generationContext: GenerationContext
        if !isToolFollowUp {
            debugLog(debugConsole, .qa, "=== TURN START user=\(userText.prefix(160)) ===")
            interrupted = false
            interruptedGenerationID = nil
            // Ensure no stale TTS tasks from a previous turn can block this one.
            pendingTTSTask?.cancel()
            pendingTTSTask = nil
            lastAssistantResponseText = ""
            assistantGenerating = true
            eventBus.send(.assistantGenerating(true))

            // Play thinking tone.
            if playsThinkingTone {
                await playback.playThinkingTone()
            }

            // Add user message to history.
            await conversationState.addUserMessage(
                userText,
                speakerDisplayName: currentSpeakerDisplayName,
                speakerId: currentSpeakerLabel,
                tag: proactiveContext?.conversationTag
            )
            if proactiveContext == nil {
                await persistAcceptedUserTurnIfNeeded(userText)
            }

            if proactiveContext == nil,
               let forgetReply = await memoryOrchestrator?.handleForgetCommandIfNeeded(userText: userText)
            {
                eventBus.send(.assistantText(text: forgetReply, isFinal: true))
                if allowsAudibleOutput {
                    await speakText(forgetReply, isFinal: true)
                }
                await conversationState.addAssistantMessage(
                    forgetReply,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(forgetReply)
                endAssistantGeneration()
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END deterministic_forget ===")
                return
            }

            if proactiveContext == nil,
               let directRecallReply = await memoryOrchestrator?.handleDirectPersonalRecallIfNeeded(userText: userText)
            {
                eventBus.send(.assistantText(text: directRecallReply, isFinal: true))
                if allowsAudibleOutput {
                    await speakText(directRecallReply, isFinal: true)
                }
                await conversationState.addAssistantMessage(
                    directRecallReply,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(directRecallReply)
                endAssistantGeneration()
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END deterministic_personal_recall ===")
                return
            }

            // Issue a short-lived capability ticket for this turn.
            let toolMode = effectiveToolMode()
            let privacyMode = effectivePrivacyMode()
            activeCapabilityTicket = CapabilityTicketIssuer.issue(
                mode: toolMode,
                privacyMode: privacyMode,
                registry: registry
            )

            if proactiveContext == nil,
               let inferredToolCall = Self.repairedToolCallForSkippedTurn(userText),
               let preflightDenial = Self.preflightToolDenial(
                    for: [inferredToolCall],
                    registry: registry,
                    toolMode: toolMode,
                    privacyMode: privacyMode
               )
            {
                debugLog(
                    debugConsole,
                    .approval,
                    "Blocked requested tool before generation: \(inferredToolCall.name) — \(preflightDenial)"
                )
                let msg = "I can't do that in the current mode: \(preflightDenial)"
                eventBus.send(.assistantText(text: msg, isFinal: true))
                if allowsAudibleOutput {
                    await speakText(msg, isFinal: true)
                }
                await conversationState.addAssistantMessage(
                    msg,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(msg)
                endAssistantGeneration()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END blocked_before_generation tool=\(inferredToolCall.name) ===")
                return
            }

            // Memory recall — inject context before generation.
            let memoryContext: String?
            if Self.shouldRecallMemoryForTurn(
                firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
                userText: userText,
                availableToolNames: registry.toolNames
            ) {
                memoryContext = await memoryOrchestrator?.recall(
                    query: userText,
                    proactiveTaskId: proactiveContext?.taskId
                )
            } else {
                memoryContext = nil
            }
            if let ctx = memoryContext, !ctx.isEmpty {
                let preview = String(ctx.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                debugLog(debugConsole, .memory, "Recalled: \(preview)…")
            }

            // Build system prompt with tool schemas.
            let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
            let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                && !ownerProfileExists
            let preferToolFreeFastPath = TurnRoutingPolicy.shouldPreferToolFreeFastPath(
                userText: userText,
                allowsAudibleOutput: allowsAudibleOutput,
                toolsAvailable: toolMode != "off" && !ownerEnrollmentRequired
            )
            let visibleToolNames = Self.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
                userText: userText,
                availableToolNames: registry.toolNames,
                proactiveAllowedTools: proactiveContext?.allowedTools
            )
            if let visibleToolNames {
                debugLog(
                    debugConsole,
                    .pipeline,
                    "Visible tools for turn: \(visibleToolNames.sorted().joined(separator: ", "))"
                )
            }
            let toolsAvailableForTurn = toolMode != "off"
                && !ownerEnrollmentRequired
                && !preferToolFreeFastPath
            let selectedRoute = await selectLLMRoute(
                userText: userText,
                isToolFollowUp: isToolFollowUp,
                proactiveContext: proactiveContext,
                allowsAudibleOutput: allowsAudibleOutput,
                toolsAvailable: toolsAvailableForTurn
            )
            let includeTools = toolsAvailableForTurn && selectedRoute == .operatorModel
            let selectedModelId = selectedModelId(for: selectedRoute)
            let preferLegacyInlineToolPrompt = Self.prefersLegacyInlineToolPrompt(
                modelId: selectedModelId
            )

            let hiddenToolsReason: String? = {
                guard !includeTools else { return nil }
                if toolMode == "off" {
                    return "toolMode=off"
                }
                if ownerEnrollmentRequired {
                    return "owner_enrollment_required"
                }
                if preferToolFreeFastPath {
                    return "quick_voice_fast_path"
                }
                if selectedRoute == .conciergeModel {
                    return "concierge_route"
                }
                return "unknown"
            }()

            // Diagnostic logging — critical for debugging tool use failures.
            if let hiddenToolsReason {
                debugLog(debugConsole, .pipeline, "⚠️ Tools HIDDEN from LLM: \(hiddenToolsReason)")
                NSLog("PipelineCoordinator: tools hidden — %@", hiddenToolsReason)
                if !isToolFollowUp && Self.shouldShowToolModeUpgradePopup(reasonCode: hiddenToolsReason) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .faeToolModeUpgradeRequested,
                            object: nil,
                            userInfo: ["reason": hiddenToolsReason]
                        )
                    }
                }
            } else {
                let ownerDetail: String
                if currentSpeakerIsOwner {
                    ownerDetail = "ownerVerified=true"
                } else if currentSpeakerIsKnownNonOwner {
                    ownerDetail = "speakerNonOwner=\(currentSpeakerLabel ?? "?")"
                } else if currentSpeakerLabel == nil {
                    ownerDetail = "speakerUnknown"
                } else {
                    ownerDetail = "speaker=\(currentSpeakerLabel ?? "?")"
                }
                debugLog(debugConsole, .pipeline, "Tools enabled (mode=\(toolMode), \(ownerDetail))")
            }

            let skillDescs: [(name: String, description: String, type: SkillType)]
            let legacySkills: [String]
            if includeTools, let sm = skillManager {
                skillDescs = await sm.promptMetadata()
                legacySkills = []
            } else if includeTools {
                skillDescs = []
                legacySkills = SkillManager.installedSkillNames()
            } else {
                skillDescs = []
                legacySkills = []
            }
            // Build native tool specs for MLX tool calling.
            let nativeTools = includeTools && !preferLegacyInlineToolPrompt
                ? registry.nativeToolSpecs(
                    for: toolMode,
                    privacyMode: privacyMode,
                    limitedTo: visibleToolNames
                )
                : nil

            let toolSchemas: String? = {
                guard includeTools else { return nil }
                if nativeTools != nil {
                    let compact = registry.compactToolSummary(
                        for: toolMode,
                        privacyMode: privacyMode,
                        limitedTo: visibleToolNames
                    )
                    return compact.isEmpty ? nil : compact
                }
                let full = registry.toolSchemas(
                    for: toolMode,
                    privacyMode: privacyMode,
                    limitedTo: visibleToolNames
                )
                return full.isEmpty ? nil : full
            }()

            if let specs = nativeTools {
                debugLog(debugConsole, .pipeline, "Native tool specs: \(specs.count) tools")
            } else if includeTools, preferLegacyInlineToolPrompt {
                debugLog(
                    debugConsole,
                    .pipeline,
                    "Using legacy inline tool prompt for model=\(selectedModelId ?? "unknown")"
                )
            }

            if let schemas = toolSchemas {
                let lineCount = schemas.split(separator: "\n").count
                debugLog(debugConsole, .pipeline, "Tool prompt summary: lines=\(lineCount) chars=\(schemas.count)")
            }

            let soul = isRescueMode ? SoulManager.defaultSoul() : SoulManager.loadSoul()
            let heartbeat = isRescueMode
                ? HeartbeatManager.defaultHeartbeat()
                : HeartbeatManager.loadHeartbeat()
            let nativeToolsAvailable = nativeTools != nil
            var systemPrompt = PersonalityManager.assemblePrompt(
                voiceOptimized: true,
                visionCapable: effectiveVisionEnabled(),
                userName: config.userName,
                speakerDisplayName: currentSpeakerDisplayName,
                speakerRole: currentSpeakerRole,
                soulContract: soul,
                heartbeatContract: heartbeat,
                directiveOverride: isRescueMode ? "" : nil,
                nativeToolsAvailable: nativeToolsAvailable,
                toolSchemas: toolSchemas,
                installedSkills: legacySkills,
                skillDescriptions: skillDescs,
                includeEphemeralContext: false,
                lightweight: config.isLightweightContext
            )
            // Inject activated skill instructions into the stable prompt.
            if let activatedCtx = await skillManager?.activatedContext() {
                systemPrompt += "\n\n" + activatedCtx
            }

            var turnContextExtras: [String] = []
            if let enrollCtx = firstOwnerEnrollmentContext {
                turnContextExtras.append(enrollCtx)
                firstOwnerEnrollmentContext = nil
            }
            if let memoryTurnGuidance = Self.memoryTurnGuidance(for: userText) {
                turnContextExtras.append(memoryTurnGuidance)
            }
            let turnContextPrefix = PersonalityManager.assembleEphemeralTurnContext(
                speakerDisplayName: currentSpeakerDisplayName,
                speakerRole: currentSpeakerRole,
                memoryContext: memoryContext,
                extraSections: turnContextExtras
            )

            generationContext = GenerationContext(
                systemPrompt: systemPrompt,
                turnContextPrefix: turnContextPrefix,
                nativeTools: nativeTools,
                route: selectedRoute,
                actionSource: proactiveContext?.source ?? turnSource,
                playsThinkingTone: playsThinkingTone,
                allowsAudibleOutput: allowsAudibleOutput
            )
            currentTurnGenerationContext = generationContext
        } else if let providedGenerationContext {
            generationContext = providedGenerationContext
        } else if let currentTurnGenerationContext {
            generationContext = currentTurnGenerationContext
        } else {
            return
        }

        let systemPrompt = generationContext.systemPrompt
        let baseTurnContextPrefix = generationContext.turnContextPrefix ?? ""
        let history = await conversationState.history

        // Fast mode disables explicit reasoning on all turns, including tool
        // follow-ups. This keeps "thinking off" behavior consistent and avoids
        // silent/suppressed follow-up answers when a model emits plain text
        // instead of well-formed think tags.
        let effectiveThinkingLevel = thinkingLevelLive ?? config.llm.resolvedThinkingLevel
        let suppressThinking = Self.shouldSuppressThinking(
            forceSuppressThinking: forceSuppressThinking,
            thinkingLevel: effectiveThinkingLevel,
            isToolFollowUp: isToolFollowUp
        )

        // Auto-tune prefill step size based on loaded model if not explicitly configured.
        var prefillStep = config.llm.prefillStepSize ?? 512
        if prefillStep == 512, let mm = modelManager, let modelId = await mm.loadedModelId {
            prefillStep = FaeConfig.recommendedPrefillStepSize(modelId: modelId)
        }

        let contextLimitTokens = await conversationState.currentContextBudget()
        let effectiveTurnContextPrefix: String? = {
            guard let directive = effectiveThinkingLevel.localReasoningDirective,
                  !suppressThinking
            else {
                return generationContext.turnContextPrefix
            }
            if let existing = generationContext.turnContextPrefix,
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return directive + "\n\n" + existing
            }
            return directive
        }()
        let localMaxTokens = min(config.llm.maxTokens + effectiveThinkingLevel.additionalLocalMaxTokens, 8_192)
        let dynamicReservedTokens = max(
            1024,
            Self.estimateTokenCount(for: systemPrompt)
                + Self.estimateTokenCount(for: effectiveTurnContextPrefix ?? baseTurnContextPrefix)
                + localMaxTokens
        )
        await conversationState.setReservedTokens(dynamicReservedTokens)
        let options = GenerationOptions(
            temperature: config.llm.temperature,
            topP: config.llm.topP,
            maxTokens: localMaxTokens,
            repetitionPenalty: config.llm.repeatPenalty,
            suppressThinking: suppressThinking,
            tools: generationContext.nativeTools,
            turnContextPrefix: effectiveTurnContextPrefix,
            contextLimitTokens: contextLimitTokens,
            // KV Cache Optimization (Phase 1) - based on Ollama/mistral.rs/LM Studio research
            maxKVSize: config.llm.maxKVCacheSize,
            kvBits: config.llm.kvQuantBits,
            kvGroupSize: config.llm.kvGroupSize,
            quantizedKVStart: config.llm.kvQuantStartTokens,
            repetitionContextSize: config.llm.repetitionContextSize,
            prefillStepSize: prefillStep
        )

        // Stream tokens.
        thinkTagStripper = TextProcessing.ThinkTagStripper()
        voiceTagStripper = VoiceTagStripper()
        let roleplayActive = await RoleplaySessionStore.shared.isActive
        var roleplayChunker = RoleplaySpeechChunker()
        var fullResponse = ""
        var sentenceBuffer = ""
        var detectedToolCall = false
        // Qwen3 emits <think> as a special token (decoded to empty string by mlx-swift-lm)
        // but </think> as regular literal text. Suppress all TTS until </think> is seen.
        // When thinking is disabled, mark think as already seen so tokens route to TTS.
        // NOTE: tool follow-up turns DO produce think blocks (model reasons about tool
        // results before responding), so we must NOT skip the buffer for them.
        var thinkEndSeen = options.suppressThinking
        var thinkAccum = ""
        // Clear any previous thinking bubble when a new generation starts.
        if !thinkEndSeen {
            eventBus.send(.thinkingText(text: "", isActive: true))
        }
        var firstTtsSent = false
        let suppressProvisionalOutputForLikelyToolTurn = !isToolFollowUp && (
            Self.isToolBackedLookupRequest(userText)
                || Self.isScreenIntentRequest(userText)
                || Self.isCameraIntentRequest(userText)
                || Self.repairedToolCallForSkippedTurn(userText) != nil
        )
        let llmStartedAt = Date()
        var llmTokenCount = 0
        var firstTokenAt: Date?
        var spokenTextThisTurn = ""
        var visibleTextThisTurn = ""
        // Stability-first speech mode: keep live text streaming, but defer TTS
        // until the turn completes. KokoroMLXTTSEngine produces a single-pass
        // synthesis (non-streaming), so deferring lets it see complete sentence
        // spans and produce better prosody than synthesising mid-stream fragments.
        // The sentence queue below then synthesises sentence-by-sentence so
        // time-to-first-audio scales with sentence length, not full response length.
        let preferFinalOnlySpeech = true
        var deferredSentenceQueue: [String] = []
        var streamedToolCalls: [ToolCall] = []
        var completionInfo: GenerateCompletionInfo?
        var llmFailureDescription: String?

        if turnCount == 0 {
            // Keep echo matching aligned with what we actually speak this turn.
            lastAssistantResponseText = ""
        }

        func recordSpokenText(_ text: String) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            if spokenTextThisTurn.isEmpty {
                spokenTextThisTurn = cleaned
            } else {
                spokenTextThisTurn += " " + cleaned
            }
            if lastAssistantResponseText.isEmpty {
                lastAssistantResponseText = cleaned
            } else {
                lastAssistantResponseText += " " + cleaned
            }
        }

        func recordVisibleText(_ text: String) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            if visibleTextThisTurn.isEmpty {
                visibleTextThisTurn = cleaned
            } else {
                visibleTextThisTurn += " " + cleaned
            }
        }

        // Streaming chunk smoothing: prioritize sentence-sized chunks, and only use
        // clause fallback when enough text has accumulated and cadence allows it.
        let minSentenceChunkChars = 28
        let minSentenceFlushIntervalSec: TimeInterval = 0.24
        let minClauseChunkChars = 55
        let minClauseFlushIntervalSec: TimeInterval = 0.55
        let maxCharsBeforeClauseFlush = 280
        var lastStreamingFlushAt: Date?
        var streamingChunkCount = 0
        var streamingChunkCharsTotal = 0
        var streamingShortChunkCount = 0

        func emitStreamingChunk(_ cleaned: String) {
            guard !cleaned.isEmpty else { return }
            // Safety gate: suppress content that looks like code/JSON/tool output.
            if TextProcessing.looksLikeNonProse(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed non-prose TTS] \(String(cleaned.prefix(80)))")
                // Still show in conversation UI, just don't speak it.
                recordVisibleText(cleaned)
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                return
            }
            // Suppress UI self-narration at any position (model describing its own interface).
            if TextProcessing.isUISelfNarration(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed UI self-narration] \(String(cleaned.prefix(80)))")
                recordVisibleText(cleaned)
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                return
            }

            // Explicit tool-backed turns often emit provisional prose before the
            // actual repair/approval path runs. Hide those chunks entirely so the
            // user sees the real tool/approval state rather than a fake success.
            if suppressProvisionalOutputForLikelyToolTurn {
                debugLog(debugConsole, .pipeline, "[suppressed provisional tool-turn text] \(String(cleaned.prefix(80)))")
                return
            }

            // Conservative mode: keep text streaming to UI, but defer audio until
            // turn completion so TTS receives larger coherent text context.
            if preferFinalOnlySpeech {
                recordVisibleText(cleaned)
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                deferredSentenceQueue.append(cleaned)
                return
            }

            let now = Date()
            let intervalMs = Int((lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? 0) * 1000)
            firstTtsSent = true
            lastStreamingFlushAt = now
            streamingChunkCount += 1
            streamingChunkCharsTotal += cleaned.count
            if cleaned.count < 30 {
                streamingShortChunkCount += 1
            }
            debugLog(debugConsole, .pipeline, "Stream chunk #\(streamingChunkCount) chars=\(cleaned.count) interval_ms=\(intervalMs)")
            NSLog("PipelineCoordinator: TTS chunk → \"%@\"", String(cleaned.prefix(120)))
            recordVisibleText(cleaned)
            eventBus.send(.assistantText(text: cleaned, isFinal: false))
            if generationContext.allowsAudibleOutput {
                recordSpokenText(cleaned)
                enqueueTTS(cleaned, isFinal: false, generationID: generationID)
            }
        }

        func voiceInstruct(for character: String?) async -> String? {
            guard let character else { return nil }

            var matched = await RoleplaySessionStore.shared.voiceForCharacter(character)
            if matched == nil {
                let globalEntry = await CharacterVoiceLibrary.shared.find(name: character)
                matched = globalEntry?.voiceInstruct
            }
            if matched == nil {
                NSLog("PipelineCoordinator: unassigned character '%@' — using narrator voice", character)
            }
            return matched
        }

        func emitRoleplayChunk(_ chunk: RoleplaySpeechChunk, isFinal: Bool) async {
            let cleaned = TextProcessing.stripNonSpeechChars(chunk.text)
            guard !cleaned.isEmpty else { return }

            if TextProcessing.looksLikeNonProse(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed non-prose roleplay TTS] \(String(cleaned.prefix(80)))")
                recordVisibleText(cleaned)
                eventBus.send(.assistantText(text: cleaned, isFinal: isFinal))
                return
            }

            if suppressProvisionalOutputForLikelyToolTurn {
                debugLog(debugConsole, .pipeline, "[suppressed provisional roleplay tool-turn text] \(String(cleaned.prefix(80)))")
                return
            }

            let voice = await voiceInstruct(for: chunk.character)
            recordVisibleText(cleaned)
            eventBus.send(.assistantText(text: cleaned, isFinal: isFinal))
            if generationContext.allowsAudibleOutput {
                recordSpokenText(cleaned)
                enqueueTTS(cleaned, isFinal: isFinal, voiceInstruct: voice, generationID: generationID)
            }
        }

        let systemPromptTokens = Self.estimateTokenCount(for: systemPrompt)
        if forceSuppressThinking {
            debugLog(debugConsole, .pipeline, "Retrying turn with thinking suppression forced")
        }
        debugLog(debugConsole, .pipeline, "LLM generating route=\(generationContext.route.rawValue) (maxTokens=\(options.maxTokens), history=\(history.count) msgs, turn=\(turnCount), sysPrompt≈\(systemPromptTokens) tok, ctx=\(config.llm.contextSizeTokens), suppressThinking=\(options.suppressThinking))")
        if options.maxTokens < 1024 {
            debugLog(debugConsole, .pipeline, "⚠️ maxTokens=\(options.maxTokens) is very low — tool call JSON needs ~200-500 tokens")
        }

        let activeLLMEngine = engine(for: generationContext.route)
        guard await ensureLLMReady(activeLLMEngine, route: generationContext.route) else {
            NSLog("PipelineCoordinator: LLM not loaded for route %@", generationContext.route.rawValue)
            debugLog(
                debugConsole,
                .pipeline,
                "⚠️ LLM not loaded for route=\(generationContext.route.rawValue) — cannot generate"
            )
            return
        }
        let inferenceClass: InferenceWorkClass = generationContext.route == .operatorModel
            ? .operatorLLM
            : .conciergeLLM
        await InferencePriorityController.shared.begin(inferenceClass)
        var inferencePriorityReleased = false
        let releaseInferencePriority = {
            guard !inferencePriorityReleased else { return }
            inferencePriorityReleased = true
            Task {
                await InferencePriorityController.shared.end(inferenceClass)
            }
        }
        defer {
            releaseInferencePriority()
        }

        let tokenStream = await activeLLMEngine.generate(
            messages: history,
            systemPrompt: systemPrompt,
            options: options
        )

        var staleGenerationDetected = false
        await instrumentation.markLLMStart()

        do {
            for try await event in tokenStream {
                if activeGenerationID != generationID {
                    staleGenerationDetected = true
                    debugLog(debugConsole, .pipeline, "Drop stale token stream id=\(generationID.uuidString.prefix(8))")
                    break
                }

                guard !isGenerationInterrupted(generationID) else {
                    NSLog("PipelineCoordinator: generation interrupted")
                    break
                }

                switch event {
                case .info(let info):
                    completionInfo = info
                    continue

                case .toolCall(let nativeCall):
                    detectedToolCall = true
                    streamedToolCalls.append(
                        ToolCall(
                            name: nativeCall.function.name,
                            arguments: nativeCall.function.arguments.mapValues { $0.anyValue }
                        )
                    )
                    deferredSentenceQueue = []
                    sentenceBuffer = ""
                    continue

                case .text(let token):
                    llmTokenCount += 1
                    if firstTokenAt == nil {
                        firstTokenAt = Date()
                        await instrumentation.markLLMFirstToken(
                            latencyMs: Date().timeIntervalSince(llmStartedAt) * 1000
                        )
                    }

                    let visible = thinkTagStripper.process(token)
                    // For Qwen3.5-35B-A3B: <think> is literal text, so ThinkTagStripper
                    // consumes it natively. When it exits the think block, signal thinkEndSeen
                    // so the pipeline doesn't wait for </think> in thinkAccum (which never arrives
                    // because ThinkTagStripper already consumed it).
                    // Emit live think chunks from ThinkTagStripper (Qwen3.5 path).
                    if !thinkTagStripper.thinkChunk.isEmpty {
                        eventBus.send(.thinkingText(text: thinkTagStripper.thinkChunk, isActive: true))
                        debugLog(debugConsole, .llmThink, thinkTagStripper.thinkChunk)
                    }
                    if thinkTagStripper.hasExitedThinkBlock && !thinkEndSeen {
                        thinkEndSeen = true
                        eventBus.send(.thinkingText(text: "", isActive: false))
                    }
                    guard !visible.isEmpty else {
                        continue
                    }

                    fullResponse += visible

                    if detectedToolCall {
                        continue
                    }

                    // Think block suppression: Qwen3's <think> is a special token decoded to ""
                    // so ThinkTagStripper never sees it. </think> IS emitted as literal text.
                    // Buffer everything until </think>, then discard the think block.
                    if !thinkEndSeen {
                        debugLog(debugConsole, .llmThink, visible)
                        thinkAccum += visible
                        eventBus.send(.thinkingText(text: visible, isActive: true))
                        if let endRange = thinkAccum.range(of: "</think>") {
                            let afterThink = String(thinkAccum[endRange.upperBound...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            thinkAccum = ""
                            thinkEndSeen = true
                            eventBus.send(.thinkingText(text: "", isActive: false))
                            if !afterThink.isEmpty && !roleplayActive {
                                sentenceBuffer = afterThink
                            }
                            continue
                        }
                        if thinkAccum.count > 80_000 {
                            thinkAccum = ""
                            thinkEndSeen = true
                            eventBus.send(.thinkingText(text: "", isActive: false))
                        } else {
                            continue
                        }
                    }
                    debugLog(debugConsole, .llmToken, visible)

                    // Roleplay mode: route through voice tag parser for per-character TTS.
                    if roleplayActive {
                        let segments = voiceTagStripper.process(visible)
                        let readyChunks = roleplayChunker.process(segments)
                        for chunk in readyChunks {
                            await emitRoleplayChunk(chunk, isFinal: false)
                        }
                    } else {
                    // Standard sentence-boundary streaming flow.
                    sentenceBuffer += visible

                    if let boundary = TextProcessing.findSentenceBoundary(in: sentenceBuffer) {
                        let sentence = String(sentenceBuffer[..<boundary])
                        let stripped = TextProcessing.stripNonSpeechChars(sentence)
                        let cleaned = TextProcessing.stripReasoningPreface(stripped)
                        // Safety filter: if this is the very first TTS sentence and it looks
                        // like the model is narrating/describing what the user said (leaked
                        // reasoning), discard it and log to debug console instead.
                        let isMetaCommentary = !firstTtsSent && !stripped.isEmpty && cleaned.isEmpty
                        if !cleaned.isEmpty && !isMetaCommentary {
                            let now = Date()
                            let interval = lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                            let shouldHoldForCoalesce = cleaned.count < minSentenceChunkChars
                                && (interval < minSentenceFlushIntervalSec || !firstTtsSent)

                            if shouldHoldForCoalesce {
                                // Keep buffering until we have a bigger chunk or enough cadence spacing.
                            } else {
                                emitStreamingChunk(cleaned)
                                sentenceBuffer = String(sentenceBuffer[boundary...])
                            }
                        } else {
                            if isMetaCommentary {
                                debugLog(debugConsole, .llmThink, "[suppressed meta-commentary] \(cleaned)")
                            }
                            sentenceBuffer = String(sentenceBuffer[boundary...])
                        }
                    } else if sentenceBuffer.count >= maxCharsBeforeClauseFlush {
                        if let clause = TextProcessing.findClauseBoundary(in: sentenceBuffer) {
                            let text = String(sentenceBuffer[..<clause])
                            let stripped = TextProcessing.stripNonSpeechChars(text)
                            let cleaned = TextProcessing.stripReasoningPreface(stripped)
                            if !cleaned.isEmpty {
                                let now = Date()
                                let interval = lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                                let canFlushClause = cleaned.count >= minClauseChunkChars
                                    && interval >= minClauseFlushIntervalSec
                                if canFlushClause {
                                    emitStreamingChunk(cleaned)
                                    sentenceBuffer = String(sentenceBuffer[clause...])
                                }
                            }
                        }
                    }
                }
            }
        }
        } catch {
            llmFailureDescription = error.localizedDescription
            NSLog("PipelineCoordinator: LLM error: %@", error.localizedDescription)
            debugLog(debugConsole, .pipeline, "⚠️ LLM error: \(error.localizedDescription)")
        }

        if staleGenerationDetected {
            return
        }

        let llmEndedAt = Date()
        let llmElapsed = llmEndedAt.timeIntervalSince(llmStartedAt)
        if let completionInfo {
            debugLog(
                debugConsole,
                .pipeline,
                "LLM metrics prompt=\(completionInfo.promptTokenCount)tok prompt_tps=\(String(format: "%.1f", completionInfo.promptTokensPerSecond)) decode_tps=\(String(format: "%.1f", completionInfo.tokensPerSecond)) stop=\(completionInfo.stopReason)"
            )
            await instrumentation.markLLMEnd(
                durationMs: (completionInfo.promptTime + completionInfo.generateTime) * 1000,
                tokenCount: completionInfo.generationTokenCount
            )
        } else {
            await instrumentation.markLLMEnd(durationMs: llmElapsed * 1000, tokenCount: llmTokenCount)
        }
        if llmElapsed > 0 {
            let throughput = Double(llmTokenCount) / llmElapsed
            NSLog("phase1.llm_token_throughput_tps=%.2f", throughput)

            if let firstTokenAt {
                let firstTokenLatency = firstTokenAt.timeIntervalSince(llmStartedAt)
                let decodeElapsed = max(llmEndedAt.timeIntervalSince(firstTokenAt), 0.001)
                let decodeTps = Double(llmTokenCount) / decodeElapsed
                debugLog(
                    debugConsole,
                    .pipeline,
                    "LLM done: \(llmTokenCount) tokens total=\(String(format: "%.1f", llmElapsed))s first_token=\(String(format: "%.1f", firstTokenLatency))s decode=\(String(format: "%.1f", decodeElapsed))s decode_tps=\(String(format: "%.1f", decodeTps))"
                )

                if llmTokenCount == 0 {
                    debugLog(debugConsole, .pipeline, "⚠️ 0 tokens generated — possible model stall or context overflow")
                } else if llmTokenCount >= 128 && decodeTps < 2.0 {
                    debugLog(debugConsole, .pipeline, "⚠️ Low decode throughput (\(String(format: "%.1f", decodeTps)) t/s) during long generation")
                } else if llmTokenCount < 128 && firstTokenLatency > 8.0 {
                    debugLog(debugConsole, .pipeline, "ℹ️ Turn was prefill-heavy (long first-token latency) — decode speed itself was normal")
                }
            } else {
                debugLog(debugConsole, .pipeline, "LLM done: \(llmTokenCount) tokens in \(String(format: "%.1f", llmElapsed))s (\(String(format: "%.1f", throughput)) t/s)")
                if llmTokenCount == 0 {
                    debugLog(debugConsole, .pipeline, "⚠️ 0 tokens generated — possible model stall or context overflow")
                }
            }
        }

        if streamingChunkCount > 0 {
            let avgChunk = Double(streamingChunkCharsTotal) / Double(streamingChunkCount)
            let shortRatio = Double(streamingShortChunkCount) / Double(streamingChunkCount)
            debugLog(
                debugConsole,
                .pipeline,
                "TTS stream chunks: count=\(streamingChunkCount) avg_chars=\(String(format: "%.1f", avgChunk)) short_ratio=\(String(format: "%.2f", shortRatio))"
            )
        }

        // Flush remaining text.
        let remaining = thinkTagStripper.flush()
        fullResponse += remaining
        let responsePreview = fullResponse
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(180)
        debugLog(debugConsole, .qa, "Model raw response preview: \(responsePreview)")

        // Prefer structured MLX tool calls; fall back to legacy text parsing.
        let toolCalls: [ToolCall] = {
            guard generationContext.route == .operatorModel else { return [] }
            return streamedToolCalls.isEmpty
                ? Self.parseToolCalls(from: fullResponse)
                : streamedToolCalls
        }()
        if !toolCalls.isEmpty {
            debugLog(debugConsole, .pipeline, "Found \(toolCalls.count) tool call(s): \(toolCalls.map(\.name).joined(separator: ", "))")
        } else if fullResponse.contains("<tool_call>") {
            debugLog(debugConsole, .qa, "⚠️ Model emitted tool_call markup but no valid calls parsed")
        }

        // Release the LLM slot before any final TTS flush or tool follow-up work.
        releaseInferencePriority()

        if turnCount == 0,
           toolCalls.isEmpty,
           proactiveContext == nil,
           let repairCall = Self.repairedToolCallForSkippedTurn(userText),
           effectiveToolMode() != "off",
           Self.shouldAttemptRepairToolCall(
                repairCall,
                registry: registry,
                toolMode: effectiveToolMode(),
                privacyMode: effectivePrivacyMode()
           )
        {
            debugLog(debugConsole, .qa, "Tool repair fallback: forcing \(repairCall.name) tool call")
            if Self.canRunDeferredToolCalls([repairCall], registry: registry),
               !Self.shouldPreferInlineToolExecution(userText: userText, toolCalls: [repairCall])
            {
                let ack = "I’ll check that in the background and report back as soon as it’s ready."
                eventBus.send(.assistantText(text: ack, isFinal: true))
                if generationContext.allowsAudibleOutput {
                    enqueueTTS(ack, isFinal: true, generationID: generationID)
                }

                await awaitPendingTTS()
                if generationContext.allowsAudibleOutput {
                    await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_repaired_deferred_tools")
                }

                await startDeferredToolJob(
                    userText: userText,
                    toolCalls: [repairCall],
                    assistantToolMessage: "I'll check that with the \(repairCall.name) tool.",
                    forceSuppressThinking: forceSuppressThinking,
                    capabilityTicket: activeCapabilityTicket,
                    explicitUserAuthorization: explicitUserAuthorizationForTurn,
                    generationContext: generationContext,
                    originTurnID: currentTurnID
                )

                endAssistantGeneration()
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END repaired_deferred_tools count=1 ===")
                return
            }

            let repairCallID = UUID().uuidString
            let inputJSON = Self.serializeArguments(repairCall.arguments)
            eventBus.send(.toolCall(id: repairCallID, name: repairCall.name, inputJSON: inputJSON))

            let repairResult = await executeTool(
                repairCall,
                proactiveContext: proactiveContext,
                generationContextOverride: generationContext,
                traceTurnID: currentTurnID,
                traceToolCallID: repairCallID
            )

            eventBus.send(.toolResult(
                id: repairCallID,
                name: repairCall.name,
                success: !repairResult.isError,
                output: String(repairResult.output.prefix(200))
            ))

            if !repairResult.isError {
                if let directReply = Self.directToolReplyText(for: repairCall, result: repairResult)
                {
                    eventBus.send(.assistantText(text: directReply, isFinal: true))
                    if generationContext.allowsAudibleOutput {
                        await speakText(directReply, isFinal: true, emitAssistantText: false)
                    }
                    await conversationState.addAssistantMessage(
                        directReply,
                        tag: proactiveContext?.conversationTag
                    )
                    await synchronizeLLMSession()
                    await persistFinalAssistantTurnIfNeeded(directReply)
                    endAssistantGeneration()
                    engage()
                    activeCapabilityTicket = nil
                    debugLog(debugConsole, .qa, "=== TURN END repaired_direct_tool_reply name=\(repairCall.name) ===")
                    return
                }

                await conversationState.addAssistantMessage(
                    "I checked that with the \(repairCall.name) tool.",
                    tag: proactiveContext?.conversationTag
                )
                await conversationState.addToolResult(
                    id: repairCallID,
                    name: repairCall.name,
                    content: repairResult.output
                )

                await generateWithTools(
                    userText: userText,
                    isToolFollowUp: true,
                    turnCount: turnCount + 1,
                    forceSuppressThinking: true,
                    generationContext: generationContext,
                    generationID: generationID,
                    proactiveContext: proactiveContext
                )
                return
            }

            debugLog(debugConsole, .qa, "Tool repair fallback failed: \(repairResult.output)")
        }

        if toolCalls.isEmpty {
            // No tool calls — flush remaining speech and finish.
            if roleplayActive {
                // Flush voice tag stripper with remaining think-tag text.
                let roleplaySegments = voiceTagStripper.process(remaining) + voiceTagStripper.flush()
                let voiceRemaining = roleplayChunker.process(roleplaySegments, isFinal: true)
                var spokeSomething = false
                for (index, chunk) in voiceRemaining.enumerated() {
                    await emitRoleplayChunk(chunk, isFinal: index == voiceRemaining.count - 1)
                    let cleaned = TextProcessing.stripNonSpeechChars(chunk.text)
                    if generationContext.allowsAudibleOutput, !cleaned.isEmpty {
                        spokeSomething = true
                    }
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if !spokeSomething && assistantSpeaking {
                    await playback.markEnd()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if assistantSpeaking {
                        debugLog(debugConsole, .pipeline, "No roleplay TTS produced this turn — force-clearing speech state")
                        markAssistantSpeechEnded(reason: "no_tts_this_turn")
                    }
                }
            } else {
                sentenceBuffer += remaining
                let finalText = TextProcessing.stripReasoningPreface(
                    TextProcessing.stripNonSpeechChars(sentenceBuffer)
                )
                var sentences = deferredSentenceQueue
                if !finalText.isEmpty, !suppressProvisionalOutputForLikelyToolTurn {
                    sentences.append(finalText)
                }
                let filteredSentences = sentences.filter {
                    !$0.isEmpty && !TextProcessing.looksLikeNonProse($0)
                }
                let shouldSpeak = generationContext.allowsAudibleOutput && !filteredSentences.isEmpty
                if !finalText.isEmpty {
                    if suppressProvisionalOutputForLikelyToolTurn {
                        debugLog(
                            debugConsole,
                            .pipeline,
                            "[suppressed provisional tool-turn final text] \(String(finalText.prefix(80)))"
                        )
                    } else {
                        recordVisibleText(finalText)
                        eventBus.send(.assistantText(text: finalText, isFinal: true))
                    }
                }
                if shouldSpeak {
                    let fullText = filteredSentences.joined(separator: " ")
                    let segments = Self.batchedTTSSegments(from: fullText)
                    NSLog(
                        "PipelineCoordinator: TTS full response → \"%@\" (from %d parts, batched=%d)",
                        String(fullText.prefix(120)),
                        filteredSentences.count,
                        segments.count
                    )
                    for (index, segment) in segments.enumerated() {
                        recordSpokenText(segment)
                        enqueueTTS(
                            segment,
                            isFinal: index == segments.count - 1,
                            generationID: generationID
                        )
                    }
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if !shouldSpeak && assistantSpeaking {
                    // No TTS was enqueued for the final chunk (empty or non-prose).
                    // Mark playback end first, then force-clear only if speaking remains stuck.
                    await playback.markEnd()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if assistantSpeaking,
                       spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        debugLog(debugConsole, .pipeline, "No TTS this turn — force-clearing assistantSpeaking")
                        markAssistantSpeechEnded(reason: "no_tts_this_turn")
                    }
                }
            }

            let spokenText = spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleText = visibleTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantTextForStorage = generationContext.allowsAudibleOutput ? spokenText : visibleText
            let visibleResponse = Self.stripThinkContent(fullResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if assistantTextForStorage.isEmpty,
               visibleResponse.isEmpty,
               let llmFailureDescription,
               let fallback = Self.llmFailureFallbackMessage(
                    firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
                    proactiveContextPresent: proactiveContext != nil
               )
            {
                debugLog(debugConsole, .pipeline, "Deterministic LLM failure fallback: \(llmFailureDescription)")
                eventBus.send(.assistantText(text: fallback, isFinal: true))
                if generationContext.allowsAudibleOutput {
                    recordSpokenText(fallback)
                    enqueueTTS(fallback, isFinal: true, generationID: generationID)
                }
                await awaitPendingTTS()
                await conversationState.addAssistantMessage(fallback, tag: proactiveContext?.conversationTag)
                await synchronizeLLMSession()
                await persistFinalAssistantTurnIfNeeded(fallback)
                endAssistantGeneration()
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END fallback reason=llm_error ===")
                return
            }
            if assistantTextForStorage.isEmpty,
               !forceSuppressThinking,
               !options.suppressThinking,
               proactiveContext == nil
            {
                let retryReason = visibleResponse.isEmpty
                    ? "No visible response after thinking block"
                    : "Only suppressed non-spoken output after thinking block"
                debugLog(debugConsole, .pipeline, "\(retryReason) — retrying with thinking disabled")
                await generateWithTools(
                    userText: userText,
                    isToolFollowUp: true,
                    turnCount: turnCount,
                    forceSuppressThinking: true,
                    generationContext: generationContext,
                    generationID: generationID,
                    proactiveContext: proactiveContext
                )
                return
            }

            if turnCount == 0,
               toolCalls.isEmpty,
               proactiveContext == nil,
               Self.isCameraIntentRequest(userText)
            {
                if effectiveToolMode() == "off" {
                    debugLog(debugConsole, .qa, "Camera intent fallback skipped — tools are off")
                } else {
                    debugLog(debugConsole, .qa, "Camera intent fallback: forcing camera tool call")
                    let repairCall = ToolCall(name: "camera", arguments: ["prompt": userText])
                    let repairCallID = UUID().uuidString
                    let inputJSON = Self.serializeArguments(repairCall.arguments)
                    eventBus.send(.toolCall(id: repairCallID, name: repairCall.name, inputJSON: inputJSON))

                    let repairResult = await executeTool(
                        repairCall,
                        proactiveContext: proactiveContext,
                        generationContextOverride: generationContext,
                        traceTurnID: currentTurnID,
                        traceToolCallID: repairCallID
                    )

                    eventBus.send(.toolResult(
                        id: repairCallID,
                        name: repairCall.name,
                        success: !repairResult.isError,
                        output: String(repairResult.output.prefix(200))
                    ))

                    if !repairResult.isError {
                        await conversationState.addAssistantMessage(
                            "I checked the camera.",
                            tag: proactiveContext?.conversationTag
                        )
                        await conversationState.addToolResult(
                            id: repairCallID,
                            name: repairCall.name,
                            content: repairResult.output
                        )

                        await generateWithTools(
                            userText: userText,
                            isToolFollowUp: true,
                            turnCount: turnCount + 1,
                            forceSuppressThinking: true,
                            generationContext: generationContext,
                            generationID: generationID,
                            proactiveContext: proactiveContext
                        )
                        return
                    }

                    debugLog(debugConsole, .qa, "Camera intent fallback failed: \(repairResult.output)")
                }
            }

            if turnCount == 0,
               toolCalls.isEmpty,
               proactiveContext == nil,
               Self.isScreenIntentRequest(userText)
            {
                if effectiveToolMode() == "off" {
                    debugLog(debugConsole, .qa, "Screen intent fallback skipped — tools are off")
                } else {
                    let repairCall = Self.screenRepairToolCall(for: userText)
                    debugLog(debugConsole, .qa, "Screen intent fallback: forcing \(repairCall.name) tool call")
                    let repairCallID = UUID().uuidString
                    let inputJSON = Self.serializeArguments(repairCall.arguments)
                    eventBus.send(.toolCall(id: repairCallID, name: repairCall.name, inputJSON: inputJSON))

                    let repairResult = await executeTool(
                        repairCall,
                        proactiveContext: proactiveContext,
                        generationContextOverride: generationContext,
                        traceTurnID: currentTurnID,
                        traceToolCallID: repairCallID
                    )

                    eventBus.send(.toolResult(
                        id: repairCallID,
                        name: repairCall.name,
                        success: !repairResult.isError,
                        output: String(repairResult.output.prefix(200))
                    ))

                    if !repairResult.isError {
                        await conversationState.addAssistantMessage(
                            "I checked the screen.",
                            tag: proactiveContext?.conversationTag
                        )
                        await conversationState.addToolResult(
                            id: repairCallID,
                            name: repairCall.name,
                            content: repairResult.output
                        )

                        await generateWithTools(
                            userText: userText,
                            isToolFollowUp: true,
                            turnCount: turnCount + 1,
                            forceSuppressThinking: true,
                            generationContext: generationContext,
                            generationID: generationID,
                            proactiveContext: proactiveContext
                        )
                        return
                    }

                    debugLog(debugConsole, .qa, "Screen intent fallback failed: \(repairResult.output)")
                }
            }

            if turnCount == 0,
               toolCalls.isEmpty,
               Self.isToolBackedLookupRequest(userText)
            {
                let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
                let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                    && !ownerProfileExists

                let fallback: String
                let reasonCode: String
                if effectiveToolMode() == "off" {
                    reasonCode = "toolMode=off"
                    fallback = "I can’t check that right now because tools are off. If you enable tools, I can fetch the real result."
                } else if ownerEnrollmentRequired {
                    reasonCode = "owner_enrollment_required"
                    fallback = "I need to enroll your primary voice before I can run tools for that. Please complete voice enrollment, then ask me again."
                } else {
                    reasonCode = "tool_not_called"
                    fallback = "I need to check that with a tool before I answer, and I couldn’t run one this turn. Please ask me to try again."
                }

                debugLog(debugConsole, .qa, "Tool-backed lookup fallback reason=\(reasonCode)")
                if Self.shouldShowToolModeUpgradePopup(reasonCode: reasonCode) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .faeToolModeUpgradeRequested,
                            object: nil,
                            userInfo: ["reason": reasonCode]
                        )
                    }
                }

                eventBus.send(.assistantText(text: fallback, isFinal: true))
                if generationContext.allowsAudibleOutput {
                    enqueueTTS(fallback, isFinal: true, generationID: generationID)
                }
                await awaitPendingTTS()
                endAssistantGeneration()
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: fallback, success: false)
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END fallback reason=\(reasonCode) ===")
                return
            }

            if !assistantTextForStorage.isEmpty {
                await conversationState.addAssistantMessage(assistantTextForStorage, tag: proactiveContext?.conversationTag)
                await synchronizeLLMSession()
                if proactiveContext == nil {
                    await persistFinalAssistantTurnIfNeeded(assistantTextForStorage)
                } else {
                    await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: assistantTextForStorage, success: true)
                }

                let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
                if VoiceConversationPolicy.shouldPersistSpeechMemory(
                    ownerProfileExists: ownerProfileExists,
                    firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
                    speakerRole: currentSpeakerRole
                ) {
                    let turnId = newMemoryId(prefix: "turn")
                    _ = await memoryOrchestrator?.capture(
                        turnId: turnId,
                        userText: userText,
                        assistantText: assistantTextForStorage,
                        speakerId: currentSpeakerLabel,
                        utteranceTimestamp: currentUtteranceTimestamp
                    )
                } else {
                    debugLog(
                        debugConsole,
                        .memory,
                        "Skipped speech memory capture for non-conversational speaker role=\(currentSpeakerRole?.rawValue ?? "unknown")"
                    )
                }

                // Sentiment → orb feeling.
                if let feeling = SentimentClassifier.classify(assistantTextForStorage) {
                    eventBus.send(.orbStateChanged(mode: "idle", feeling: feeling.rawValue, palette: nil))
                }
            } else if let proactiveContext,
                      !visibleResponse.isEmpty
            {
                let turnId = newMemoryId(prefix: "proactive")
                _ = await memoryOrchestrator?.captureProactiveRecord(
                    turnId: turnId,
                    taskId: proactiveContext.taskId,
                    prompt: userText,
                    responseText: visibleResponse,
                    speakerId: currentSpeakerLabel
                )
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: visibleResponse, success: true)
                debugLog(debugConsole, .memory, "Captured silent proactive memory for task \(proactiveContext.taskId)")
            } else if !visibleResponse.isEmpty {
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: visibleResponse, success: true)
                debugLog(debugConsole, .llmThink, "[suppressed non-spoken output] \(String(fullResponse.prefix(160)))")
            }

            maybeShowCapabilitiesCanvas(triggerText: userText, modelResponse: fullResponse)

            endAssistantGeneration()

            // Refresh follow-up window.
            engage()
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END spoken_chars=\(assistantTextForStorage.count) tool_calls=0 ===")
            return
        }

        // Tool calls found — execute them.
        if turnCount == 0,
           !isToolFollowUp,
           proactiveContext == nil,
           Self.canRunDeferredToolCalls(toolCalls, registry: registry),
           !Self.shouldPreferInlineToolExecution(userText: userText, toolCalls: toolCalls)
        {
            let assistantToolMessage = Self.stripThinkContent(fullResponse)

            let ack = "I’ll check that in the background and report back as soon as it’s ready."
            eventBus.send(.assistantText(text: ack, isFinal: true))
            if generationContext.allowsAudibleOutput {
                enqueueTTS(ack, isFinal: true, generationID: generationID)
            }

            // Prevent audio stutter: do not launch background tool execution while
            // the acknowledgement is still being spoken.
            await awaitPendingTTS()
            if generationContext.allowsAudibleOutput {
                await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_deferred_tools")
            }

            await startDeferredToolJob(
                userText: userText,
                toolCalls: Array(toolCalls.prefix(5)),
                assistantToolMessage: assistantToolMessage,
                forceSuppressThinking: forceSuppressThinking,
                capabilityTicket: activeCapabilityTicket,
                explicitUserAuthorization: explicitUserAuthorizationForTurn,
                generationContext: generationContext,
                originTurnID: currentTurnID
            )

            endAssistantGeneration()
            engage()
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END deferred_tools count=\(toolCalls.count) ===")
            return
        }

        guard turnCount < maxToolTurns else {
            debugLog(debugConsole, .qa, "Exceeded max tool turns (\(maxToolTurns))")
            let msg = "I've used several tools but couldn't complete that. Could you try rephrasing?"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            if generationContext.allowsAudibleOutput {
                await speakText(msg, isFinal: true)
            }
            endAssistantGeneration()
            await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: msg, success: false)
            activeCapabilityTicket = nil
            return
        }

        // Fallback filler: if the model emitted a bare tool call with no natural
        // preamble, speak a short acknowledgement so users don't hear dead air
        // while tools execute.
        var didEnqueueToolFiller = false
        let preflightToolDenial = Self.preflightToolDenial(
            for: Array(toolCalls.prefix(5)),
            registry: registry,
            toolMode: effectiveToolMode(),
            privacyMode: effectivePrivacyMode()
        )
        if turnCount == 0,
           !isToolFollowUp,
           spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           preflightToolDenial == nil
        {
            let filler = Self.toolCallAcknowledgement(for: toolCalls)
            if !filler.isEmpty {
                eventBus.send(.assistantText(text: filler, isFinal: false))
                if generationContext.allowsAudibleOutput {
                    recordSpokenText(filler)
                    enqueueTTS(filler, isFinal: false, generationID: generationID)
                    didEnqueueToolFiller = true
                }
            }
        }

        // Add the assistant's tool-calling message to history (strip think content).
        await conversationState.addAssistantMessage(Self.stripThinkContent(fullResponse), tag: proactiveContext?.conversationTag)
        await synchronizeLLMSession()

        let capabilityTicketForToolTurn = activeCapabilityTicket
        let explicitAuthorizationForToolTurn = explicitUserAuthorizationForTurn

        // Prevent synthesis/playback jitter: avoid starting tool execution while
        // filler/pre-tool speech is still active.
        if didEnqueueToolFiller || assistantSpeaking || pendingTTSTask != nil {
            debugLog(debugConsole, .pipeline, "Delaying tool execution until speech drains")
            await awaitPendingTTS()
            await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_tool_execution")
        }

        var toolSuccessCount = 0
        var toolFailureCount = 0
        var firstToolError: String?
        var directToolReply: String?

        for call in toolCalls.prefix(5) {
            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)
            let preflightDenial = Self.preflightToolDenial(
                for: [call],
                registry: registry,
                toolMode: effectiveToolMode(),
                privacyMode: effectivePrivacyMode()
            )

            if let preflightDenial {
                debugLog(debugConsole, .approval, "Blocked tool call before execution: \(call.name) — \(preflightDenial)")
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = preflightDenial
                }
                await recordWorkflowPreflightDenied(
                    turnID: currentTurnID,
                    callId: callId,
                    call: call,
                    reason: preflightDenial
                )
                await conversationState.addToolResult(
                    id: callId,
                    name: call.name,
                    content: preflightDenial,
                    tag: proactiveContext?.conversationTag
                )
                continue
            }

            if assistantSpeaking {
                debugLog(debugConsole, .pipeline, "⚠️ Tool start while assistantSpeaking=true (\(call.name))")
            }
            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))
            NSLog("PipelineCoordinator: executing tool '%@'", call.name)
            let inputPreview = String(inputJSON.prefix(220))
            debugLog(debugConsole, .toolCall, "id=\(callId.prefix(8)) name=\(call.name) args=\(inputPreview)")

            let callSignature = "\(call.name)|\(inputJSON)"
            var result: ToolResult
            if seenToolCallSignatures.contains(callSignature) {
                debugLog(debugConsole, .toolCall, "⚠️ Duplicate tool call blocked: \(call.name) — returning cached notice")
                result = .success("You already retrieved these results earlier in this conversation. Please synthesize your response using the data already provided rather than repeating the same search.")
                await recordWorkflowPreflightDenied(
                    turnID: currentTurnID,
                    callId: callId,
                    call: call,
                    reason: result.output
                )
            } else {
                seenToolCallSignatures.insert(callSignature)
                result = await executeTool(
                    call,
                    capabilityTicketOverride: capabilityTicketForToolTurn,
                    explicitUserAuthorizationOverride: explicitAuthorizationForToolTurn,
                    proactiveContext: proactiveContext,
                    generationContextOverride: generationContext,
                    traceTurnID: currentTurnID,
                    traceToolCallID: callId
                )
            }
            if call.name == "camera", proactiveContext?.taskId == "camera_presence_check", !result.isError {
                let userPresent = Self.inferUserPresentFromCameraOutput(result.output)
                await proactivePresenceHandler?(userPresent)
            }
            if call.name == "screenshot", proactiveContext?.taskId == "screen_activity_check", !result.isError {
                let hash = Self.contentHash(result.output)
                if let shouldPersist = await proactiveScreenContextHandler?(hash), !shouldPersist {
                    result = .success("Screen context unchanged recently. Do not store a new screen context memory record; keep the existing context.")
                }
            }
            let outputPreview = result.output.replacingOccurrences(of: "\n", with: " ").prefix(220)
            debugLog(debugConsole, .toolResult, "id=\(callId.prefix(8)) name=\(call.name) status=\(result.isError ? "error" : "ok") output=\(outputPreview)")
            if result.isError {
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = result.output
                }
            } else {
                toolSuccessCount += 1
                if toolCalls.count == 1,
                   let reply = Self.directToolReplyText(for: call, result: result)
                {
                    directToolReply = reply
                }
            }

            eventBus.send(.toolResult(
                id: callId,
                name: call.name,
                success: !result.isError,
                output: String(result.output.prefix(200))
            ))

            // Check for audio file output from skills — play WAV files automatically.
            if call.name == "run_skill", !result.isError,
               let audioPath = Self.extractAudioFilePath(from: result.output)
            {
                let audioURL = URL(fileURLWithPath: audioPath)
                if generationContext.allowsAudibleOutput,
                   FileManager.default.fileExists(atPath: audioPath)
                {
                    NSLog("PipelineCoordinator: playing skill audio output: %@", audioURL.lastPathComponent)
                    await playback.playFile(url: audioURL)
                }
            }

            await conversationState.addToolResult(
                id: callId,
                name: call.name,
                content: result.output,
                tag: proactiveContext?.conversationTag
            )
        }

        debugLog(debugConsole, .qa, "Tool execution summary: success=\(toolSuccessCount) failure=\(toolFailureCount)")
        await synchronizeLLMSession()

        if toolFailureCount > 0 && toolSuccessCount == 0 {
            let reason = firstToolError ?? "the tool call was denied or failed"
            let msg = "I couldn't complete that because the required tool didn't run: \(reason)"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            if generationContext.allowsAudibleOutput {
                await speakText(msg, isFinal: true)
            }
            endAssistantGeneration()
            await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: msg, success: false)
            activeCapabilityTicket = nil
            return
        }

        if turnCount == 0,
           toolFailureCount == 0,
           toolCalls.count == 1,
           let directToolReply
        {
            eventBus.send(.assistantText(text: directToolReply, isFinal: true))
            if generationContext.allowsAudibleOutput {
                await speakText(directToolReply, isFinal: true, emitAssistantText: false)
            }
            await conversationState.addAssistantMessage(
                directToolReply,
                tag: proactiveContext?.conversationTag
            )
            await synchronizeLLMSession()
            await persistFinalAssistantTurnIfNeeded(directToolReply)
            endAssistantGeneration()
            engage()
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END direct_tool_reply name=\(toolCalls[0].name) ===")
            return
        }

        // Recurse: generate again with tool results in context.
        await generateWithTools(
            userText: userText,
            isToolFollowUp: true,
            turnCount: turnCount + 1,
            forceSuppressThinking: forceSuppressThinking,
            generationContext: generationContext,
            generationID: generationID,
            proactiveContext: proactiveContext
        )
    }

    /// Snapshot of the current foreground turn's prompt/tool context.
    private var currentTurnGenerationContext: GenerationContext?

    // MARK: - Speech State

    private func endAssistantGeneration() {
        assistantGenerating = false
        eventBus.send(.assistantGenerating(false))
        scheduleDeferredProactiveDrain()
    }

    static func shouldShowToolModeUpgradePopup(reasonCode: String) -> Bool {
        switch reasonCode {
        case "owner_enrollment_required", "non-owner", "tool_not_called":
            return true
        default:
            return false
        }
    }

    private func markAssistantSpeechStarted() {
        guard !assistantSpeaking else { return }
        assistantSpeaking = true
        lastAssistantStart = Date()
        echoSuppressor.onAssistantSpeechStart()
    }

    private func markAssistantSpeechEnded(reason: String, resetVAD: Bool = false) {
        if assistantSpeaking {
            let speechDuration = lastAssistantStart.map { Date().timeIntervalSince($0) } ?? 0
            debugLog(debugConsole, .pipeline, "Speech state → idle (\(reason), dur=\(String(format: "%.1f", speechDuration))s)")
            assistantSpeaking = false
            echoSuppressor.onAssistantSpeechEnd(speechDurationSecs: speechDuration)
        }
        if resetVAD {
            vad.reset()
            resetStreamingSpeakerGate()
            resetStreamingWakeDetector()
            clearPendingSemanticTurn()
        }
        scheduleDeferredProactiveDrain()
    }

    // MARK: - TTS

    /// Non-blocking TTS enqueue — chains onto `pendingTTSTask` so sentences synthesize
    /// in order without blocking the LLM token stream.
    ///
    /// Call this from inside the token generation loop. The LLM keeps producing tokens
    /// while TTS runs concurrently on the actor (re-entrant at `await` points).
    private func enqueueTTS(_ text: String, isFinal: Bool, voiceInstruct: String? = nil, generationID: UUID? = nil) {
        // Set speaking state immediately so echo suppressor and barge-in work correctly.
        markAssistantSpeechStarted()

        let previous = pendingTTSTask
        pendingTTSTask = Task {
            await previous?.value  // Ensure sentence ordering
            guard !isGenerationInterrupted(generationID) else {
                // If this was the final chunk and we're interrupted, ensure speaking
                // state is cleared. The barge-in path calls playback.stop() which
                // fires .stopped → clears assistantSpeaking, but there's a race
                // window where that hasn't fired yet. Belt-and-suspenders.
                if isFinal && assistantSpeaking {
                    NSLog("PipelineCoordinator: interrupted final TTS chunk — clearing speaking state")
                    markAssistantSpeechEnded(reason: "interrupted_final_chunk")
                }
                return
            }
            await synthesizeSentence(text, isFinal: isFinal, voiceInstruct: voiceInstruct)
        }
    }

    /// Wait for all pending TTS work to complete. Call after the token loop ends.
    private func awaitPendingTTS() async {
        await pendingTTSTask?.value
        pendingTTSTask = nil
    }

    /// Wait until playback state reports idle (assistantSpeaking=false), or timeout.
    ///
    /// Useful before tool execution so heavy work doesn't contend with active speech
    /// synthesis/playback and cause audible jitter.
    private func awaitSpeechDrain(timeoutMs: Int, reason: String) async {
        guard assistantSpeaking else { return }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while assistantSpeaking, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if assistantSpeaking {
            debugLog(debugConsole, .pipeline, "⚠️ Speech drain timeout (\(reason)) after \(timeoutMs)ms")
        }
    }

    /// Blocking TTS — used by `speakDirect`, `speakWithVoice`, and other non-streaming paths
    /// where we want to wait for speech to finish before continuing.
    private func speakText(
        _ text: String,
        isFinal: Bool,
        voiceInstruct: String? = nil,
        emitAssistantText: Bool = true
    ) async {
        markAssistantSpeechStarted()

        let cleaned = TextProcessing.stripNonSpeechChars(text)
        if emitAssistantText, !cleaned.isEmpty {
            eventBus.send(.assistantText(text: cleaned, isFinal: isFinal))
        }

        // Use cleaned text for TTS — stripping self-introductions, markup, etc.
        let ttsText = cleaned.isEmpty ? text : cleaned
        let segments = Self.batchedTTSSegments(from: ttsText)
        guard !segments.isEmpty else {
            if isFinal {
                markAssistantSpeechEnded(reason: "tts_empty_after_clean")
            }
            return
        }

        for (index, segment) in segments.enumerated() {
            let segmentIsFinal = isFinal && index == segments.count - 1
            await synthesizeSentence(segment, isFinal: segmentIsFinal, voiceInstruct: voiceInstruct)
        }
    }

    /// Maximum time a single TTS synthesis call can take before we force-cancel.
    /// Prevents `assistantSpeaking` from getting stuck if the TTS model hangs.
    /// This covers both the "stream never yields" and "stream yields slowly" cases
    /// because we wrap the entire stream consumption in a cancellable task group.
    private static let ttsSynthesisTimeoutSeconds: UInt64 = 30

    /// Core TTS synthesis — shared by both `enqueueTTS` and `speakText`.
    ///
    /// Uses a task group with a timeout child so that if the TTS async stream
    /// blocks before yielding its first buffer (model hang), the timeout task
    /// cancels the stream consumer and we fall through to cleanup.
    private func synthesizeSentence(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) async {
        guard await ttsEngine.isLoaded else {
            NSLog("PipelineCoordinator: TTS not loaded, skipping speech")
            debugLog(debugConsole, .pipeline, "⚠️ TTS not loaded — skipping speech")
            if isFinal {
                markAssistantSpeechEnded(reason: "tts_not_loaded")
            }
            return
        }
        debugLog(debugConsole, .pipeline, "TTS: \"\(String(text.prefix(80)))\"\(text.count > 80 ? "…" : "") (final=\(isFinal))")

        let effectiveVoiceInstruct = voiceInstruct ?? config.tts.defaultVoiceInstruct
        var didProduceAudio = false

        do {
            didProduceAudio = try await withThrowingTaskGroup(of: Bool.self) { group in
                // Child 1: consume the TTS stream.
                // Uses Task.checkCancellation() for interruption — the timeout
                // child or external cancellation (barge-in) cancels this task.
                group.addTask { [ttsEngine, playback] in
                    let ttsStartedAt = Date()
                    var firstChunkEmitted = false
                    var produced = false
                    let audioStream = await ttsEngine.synthesize(
                        text: text, voiceInstruct: effectiveVoiceInstruct
                    )
                    // Accumulate TTS chunks before scheduling on the player.
                    // The TTS model (Qwen3-TTS 12Hz) yields small chunks — scheduling
                    // each individually causes actor-hop overhead and risks player underruns.
                    // ~500ms of audio (12 000 samples at 24kHz) per enqueue gives the
                    // player a comfortable rolling buffer without inflating TTFA.
                    var accum: [Float] = []
                    var accumRate = 24_000
                    let accumTarget = 12_000  // ~500ms at 24kHz
                    for try await buffer in audioStream {
                        try Task.checkCancellation()
                        if !firstChunkEmitted {
                            let latencyMs = Date().timeIntervalSince(ttsStartedAt) * 1000
                            firstChunkEmitted = true
                            NSLog("phase1.tts_first_chunk_latency_ms=%.2f", latencyMs)
                        }
                        produced = true
                        accumRate = Int(buffer.format.sampleRate)
                        accum.append(contentsOf: Self.extractSamples(from: buffer))
                        if accum.count >= accumTarget {
                            await playback.enqueue(samples: accum, sampleRate: accumRate, isFinal: false)
                            accum = []
                        }
                    }
                    // Flush any remaining samples; isFinal is handled by markEnd() below.
                    if !accum.isEmpty {
                        await playback.enqueue(samples: accum, sampleRate: accumRate, isFinal: false)
                    }
                    return produced
                }

                // Child 2: timeout watchdog — cancels the group if TTS hangs.
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.ttsSynthesisTimeoutSeconds * 1_000_000_000)
                    // If we reach here, the timeout expired before the stream finished.
                    return false
                }

                // Wait for whichever finishes first.
                if let produced = try await group.next() {
                    // Cancel the remaining child (either the timeout or the stalled stream).
                    group.cancelAll()
                    if !produced {
                        NSLog("PipelineCoordinator: TTS synthesis timeout or produced no audio")
                        debugLog(debugConsole, .pipeline, "⚠️ TTS timeout/no-audio — forcing completion")
                    }
                    return produced
                }
                return false
            }

            if isFinal {
                await playback.markEnd()
            }
            if isFinal && !didProduceAudio && assistantSpeaking {
                NSLog("PipelineCoordinator: TTS produced no audio for final chunk — clearing speaking state")
                debugLog(debugConsole, .pipeline, "⚠️ TTS final chunk produced no audio — force-clearing assistantSpeaking")
                markAssistantSpeechEnded(reason: "tts_final_no_audio")
            }
        } catch is CancellationError {
            NSLog("PipelineCoordinator: TTS cancelled")
            if isFinal {
                markAssistantSpeechEnded(reason: "tts_cancelled")
            }
        } catch {
            NSLog("PipelineCoordinator: TTS error: %@", error.localizedDescription)
            markAssistantSpeechEnded(reason: "tts_error")
            await playback.stop()
        }
    }

    // MARK: - Barge-In

    static func shouldTrackBargeIn(assistantSpeaking: Bool) -> Bool {
        assistantSpeaking
    }

    static func advancePendingBargeIn(
        pending: PendingBargeIn?,
        speechStarted: Bool,
        isSpeech: Bool,
        chunkSamples: [Float],
        rms: Float,
        echoSuppression: Bool,
        bargeInSuppressed: Bool,
        inDenyCooldown: Bool
    ) -> PendingBargeIn? {
        var next = pending
        if speechStarted && !echoSuppression && !bargeInSuppressed && !inDenyCooldown {
            next = PendingBargeIn(capturedAt: Date(), lastRms: rms)
        } else if speechStarted && (echoSuppression || bargeInSuppressed || inDenyCooldown) {
            return nil
        }

        if isSpeech, next != nil {
            next?.speechSamples += chunkSamples.count
            next?.lastRms = rms
            let remainingCapacity = max(0, 16_000 - (next?.audioSamples.count ?? 0))
            if remainingCapacity > 0 {
                next?.audioSamples.append(contentsOf: chunkSamples.prefix(remainingCapacity))
            }
        }

        return next
    }

    static func shouldAllowBargeInInterrupt(assistantSpeaking: Bool, assistantGenerating: Bool) -> Bool {
        // Intentional: barge-in is an audible interruption affordance.
        // If the model is generating silently, we should not interrupt due to
        // ambient noise or speaker bleed while no speech is active.
        assistantSpeaking
    }

    static func shouldStartDeferredFollowUp(
        originTurnID: String?,
        currentTurnID: String?,
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        guard !assistantSpeaking, !assistantGenerating else { return false }
        guard let originTurnID else { return true }
        return originTurnID == currentTurnID
    }

    static func coalescedDeferredProactiveTaskIDs(
        existing: [String],
        incomingTaskID: String
    ) -> [String] {
        var next = existing.filter { $0 != incomingTaskID }
        next.append(incomingTaskID)
        return next
    }

    /// Owner-verified barge-in: only the owner's voice can interrupt Fae mid-speech.
    /// Fail-closed after enrollment: if owner exists but verification fails, barge-in is DENIED.
    private func handleBargeInWithVerification(barge: PendingBargeIn) async {
        guard bargeInEnabledLive ?? config.bargeIn.enabled else { return }
        guard !bargeInSuppressed else { return }
        guard Self.shouldAllowBargeInInterrupt(
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        ) else { return }
        guard barge.lastRms >= config.bargeIn.minRms else { return }

        // Check holdoff — don't interrupt immediately after playback starts.
        if let start = lastAssistantStart {
            let elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed < Double(config.bargeIn.assistantStartHoldoffMs) {
                return
            }
        }

        // Speaker verification (fail-closed when owner exists).
        let isOwner = await verifyBargeInSpeaker(audio: barge.audioSamples)
        guard isOwner else {
            debugLog(debugConsole, .command, "Barge-in blocked (not owner)")
            bargeInDenyCooldownUntil = Date().addingTimeInterval(Self.bargeInDenyCooldownSeconds)
            return
        }

        interrupted = true
        interruptedGenerationID = activeGenerationID
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        Task { await playback.stop() }
        debugLog(debugConsole, .command, "Barge-in (owner verified) rms=\(String(format: "%.4f", barge.lastRms))")
        NSLog("PipelineCoordinator: barge-in triggered (owner verified, rms=%.4f)", barge.lastRms)
    }

    private func markGenerationInterrupted() {
        interrupted = true
        interruptedGenerationID = activeGenerationID
    }

    private func isGenerationInterrupted(_ generationID: UUID?) -> Bool {
        guard interrupted else { return false }
        guard let generationID else { return true }
        if let interruptedGenerationID {
            return interruptedGenerationID == generationID
        }
        return true
    }

    /// Verify the barge-in speaker is the owner. Fail-closed: if owner exists but
    /// verification is unavailable or errors, barge-in is DENIED. Fail-open ONLY
    /// during enrollment (no owner profile yet).
    private func verifyBargeInSpeaker(audio: [Float]) async -> Bool {
        // During enrollment (no owner yet) — allow all barge-in.
        guard let store = speakerProfileStore else { return firstOwnerEnrollmentActive }
        let hasOwner = await store.hasOwnerProfile()
        guard hasOwner else { return true }  // No owner enrolled yet — allow

        // Owner exists — fail closed if encoder unavailable.
        guard let encoder = speakerEncoder, await encoder.isLoaded else {
            return false  // Encoder unavailable but owner exists — DENY
        }

        // Need minimum audio for a meaningful embedding (~350ms at 16kHz = 5600 samples).
        guard audio.count >= 5600 else {
            return false  // Too little audio for reliable verification — DENY
        }

        do {
            let embedding = try await encoder.embed(
                audio: audio,
                sampleRate: AudioCaptureManager.targetSampleRate
            )
            // Relaxed threshold compensates for shorter/noisier barge-in audio.
            let relaxed = max(config.speaker.ownerThreshold - 0.10, 0.50)
            return await store.isOwner(embedding: embedding, threshold: relaxed)
        } catch {
            return false  // Embed failed but owner exists — DENY
        }
    }

    // MARK: - Playback Events

    private func setPlaybackEventHandler() async {
        await playback.setEventHandler { [weak self] event in
            Task { await self?.handlePlaybackEvent(event) }
        }
    }

    private func handlePlaybackEvent(_ event: AudioPlaybackManager.PlaybackEvent) {
        switch event {
        case .finished:
            markAssistantSpeechEnded(reason: "playback_finished", resetVAD: true)
            NSLog("PipelineCoordinator: playback finished")

        case .stopped:
            markAssistantSpeechEnded(reason: "playback_stopped", resetVAD: true)

        case .level(let rms):
            if assistantSpeaking,
               !ttfaEmittedForCurrentTurn,
               rms > 0.0005,
               let turnEndedAt = lastUserTurnEndedAt
            {
                let ttfaMs = Date().timeIntervalSince(turnEndedAt) * 1000
                ttfaEmittedForCurrentTurn = true
                NSLog("phase1.ttfa_ms=%.2f turn_id=%@", ttfaMs, currentTurnID ?? "none")
                debugLog(debugConsole, .pipeline, "TTFA=\(String(format: "%.1f", ttfaMs))ms turn=\(currentTurnID?.prefix(8) ?? "none")")
            }
            eventBus.send(.audioLevel(rms))
        }
    }

    // MARK: - Degraded Mode Helpers

    private func evaluateDegradedMode() async -> PipelineDegradedMode {
        let sttLoaded = await sttEngine.isLoaded
        let llmLoaded = await llmEngine.isLoaded
        let ttsLoaded = await ttsEngine.isLoaded

        if sttLoaded && llmLoaded && ttsLoaded {
            return .full
        }
        if !sttLoaded && !llmLoaded && !ttsLoaded {
            return .unavailable
        }
        if !sttLoaded {
            return .noSTT
        }
        if !llmLoaded {
            return .noLLM
        }
        if !ttsLoaded {
            return .noTTS
        }
        return .unavailable
    }

    private func refreshDegradedModeIfNeeded(context: String) async {
        let current = await evaluateDegradedMode()
        guard degradedMode != current else { return }
        degradedMode = current
        NSLog("phase1.degraded_mode=%@ context=%@", current.rawValue, context)
        debugLog(debugConsole, .qa, "Degraded mode -> \(current.rawValue) (context=\(context))")
        eventBus.send(.degradedModeChanged(mode: current.rawValue, context: context))
    }

    // MARK: - Tool Call Parsing

    struct ToolCall: @unchecked Sendable {
        let name: String
        let arguments: [String: Any]
    }

    /// Parse tool calls from response text.
    /// Supports two formats:
    /// - JSON (Qwen3): `<tool_call>{"name":"...","arguments":{...}}</tool_call>`
    /// - XML (Qwen3.5): `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>`
    static func parseToolCalls(from text: String) -> [ToolCall] {
        var calls: [ToolCall] = []
        var searchStart = text.startIndex

        while let openRange = text.range(of: "<tool_call>", range: searchStart..<text.endIndex) {
            let closeRange = text.range(of: "</tool_call>", range: openRange.upperBound..<text.endIndex)
            let contentEnd = closeRange?.lowerBound ?? text.endIndex
            let content = text[openRange.upperBound..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try JSON format first (Qwen3): {"name":"...","arguments":{...}}
            if let call = parseJSONToolCall(content) {
                calls.append(call)
            }
            // Fall back to XML parameter format (Qwen3.5): <function=name><parameter=key>value</parameter></function>
            else if let call = parseXMLToolCall(content) {
                calls.append(call)
            }

            searchStart = closeRange?.upperBound ?? text.endIndex
        }

        return calls
    }

    private static func parseJSONToolCall(_ content: String) -> ToolCall? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String
        else { return nil }
        let args = json["arguments"] as? [String: Any] ?? [:]
        return ToolCall(name: name, arguments: args)
    }

    /// Parse Qwen3.5 XML parameter format: `<function=name><parameter=key>value</parameter></function>`
    private static func parseXMLToolCall(_ content: String) -> ToolCall? {
        guard let funcMatch = content.range(of: "<function="),
              let funcEnd = content.range(of: ">", range: funcMatch.upperBound..<content.endIndex)
        else { return nil }
        let name = String(content[funcMatch.upperBound..<funcEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        var args: [String: Any] = [:]
        var paramSearchStart = funcEnd.upperBound
        while let paramOpen = content.range(of: "<parameter=", range: paramSearchStart..<content.endIndex),
              let paramNameEnd = content.range(of: ">", range: paramOpen.upperBound..<content.endIndex)
        {
            let key = String(content[paramOpen.upperBound..<paramNameEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                paramSearchStart = paramNameEnd.upperBound
                continue
            }

            let nextBoundary = nextXMLParameterBoundary(in: content, from: paramNameEnd.upperBound)
            let paramClose = content.range(of: "</parameter>", range: paramNameEnd.upperBound..<nextBoundary)
            let valueEnd = paramClose?.lowerBound ?? nextBoundary
            let value = String(content[paramNameEnd.upperBound..<valueEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to parse value as JSON for nested objects/arrays/numbers/booleans
            if let data = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data)
            {
                args[key] = parsed
            } else {
                args[key] = value
            }

            paramSearchStart = paramClose?.upperBound ?? valueEnd
        }

        return ToolCall(name: name, arguments: args)
    }

    private static func nextXMLParameterBoundary(in content: String, from start: String.Index) -> String.Index {
        let parameterOpen = content.range(of: "<parameter=", range: start..<content.endIndex)?.lowerBound
        let functionClose = content.range(of: "</function", range: start..<content.endIndex)?.lowerBound

        return [parameterOpen, functionClose, content.endIndex]
            .compactMap { $0 }
            .min() ?? content.endIndex
    }

    private static func toolCallAcknowledgement(for calls: [ToolCall]) -> String {
        guard let first = calls.first?.name.lowercased() else {
            return ""
        }
        switch first {
        case "session_search":
            return "Let me pull up our earlier conversations."
        case "web_search", "fetch_url":
            return "Let me check that quickly."
        case "calendar", "reminders":
            return "Checking that now."
        case "contacts", "mail", "notes":
            return "One moment, I’m pulling that up."
        case "read", "write", "edit", "bash":
            return "Got it, working on that now."
        default:
            return "Let me check that for you."
        }
    }

    /// Strip tool call markup from response text, leaving only human-readable content.
    static func stripToolCallMarkup(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<tool_call>") {
            if let close = result.range(of: "</tool_call>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip `<voice character="...">...</voice>` tags, keeping inner text.
    private static func stripVoiceTagMarkup(_ text: String) -> String {
        var result = text
        // Remove closing tags first (simpler).
        result = result.replacingOccurrences(of: "</voice>", with: "")
        // Remove opening tags: <voice character="..."> or <voice character='...'>
        if let regex = try? NSRegularExpression(pattern: #"<voice\s+[^>]*>"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip everything up to and including the first `</think>` tag.
    ///
    /// Prevents Qwen3 reasoning content from polluting conversation history and TTS.
    private static func stripThinkContent(_ text: String) -> String {
        guard let endRange = text.range(of: "</think>") else { return text }
        return String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tool names eligible for non-blocking background execution.
    private static let deferredToolAllowlist: Set<String> = [
        "calendar", "reminders", "contacts", "mail", "notes",
        "session_search", "web_search", "fetch_url", "read", "scheduler_list",
    ]

    private static let inlineGroundedToolAllowlist: Set<String> = [
        "calendar", "reminders", "contacts", "mail", "notes",
        "screenshot", "camera",
    ]

    /// Returns true when every tool call is read-only and safe to defer.
    private static func canRunDeferredToolCalls(
        _ calls: [ToolCall],
        registry: ToolRegistry
    ) -> Bool {
        guard !calls.isEmpty else { return false }

        for call in calls {
            guard deferredToolAllowlist.contains(call.name),
                  let tool = registry.tool(named: call.name),
                  !tool.requiresApproval,
                  tool.riskLevel != .high,
                  isReadOnlyDeferredAction(call)
            else {
                return false
            }
        }

        return true
    }

    static func shouldPreferInlineToolExecution(userText: String, toolCalls: [ToolCall]) -> Bool {
        guard toolCalls.count == 1,
              let toolName = toolCalls.first?.name
        else {
            return false
        }

        if inlineGroundedToolAllowlist.contains(toolName) {
            return true
        }

        return (toolName == "read_screen" && isScreenIntentRequest(userText))
            || (toolName == "camera" && isCameraIntentRequest(userText))
            || (toolName == "screenshot" && isScreenIntentRequest(userText))
            || (toolName == "calendar" && isToolBackedLookupRequest(userText))
    }

    /// Action-level guard for tools that can be both read and write.
    private static func isReadOnlyDeferredAction(_ call: ToolCall) -> Bool {
        switch call.name {
        case "calendar":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["list_today", "list_week", "list_date", "search"].contains(action)

        case "reminders":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["list_incomplete", "search"].contains(action)

        case "contacts":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["search", "get_phone", "get_email"].contains(action)

        case "mail":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["check_inbox", "read_recent"].contains(action)

        case "notes":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["search", "list_recent"].contains(action)

        case "scheduler_list", "session_search", "web_search", "fetch_url", "read":
            return true

        default:
            return false
        }
    }

    /// Heuristic: explicit visual requests where the assistant should run webcam capture.
    private static func isCameraIntentRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let cameraPhrases = [
            "can you see me", "do you see me", "look at me", "see me",
            "take a photo", "take a picture", "use the camera", "open the camera",
            "what do you see", "can you see", "look through the camera",
        ]
        if cameraPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        return lower.contains("camera") && (
            lower.contains("see") || lower.contains("look") || lower.contains("photo") || lower.contains("picture")
        )
    }

    /// Heuristic: requests that should inspect the current screen or capture a screenshot.
    private static func isScreenIntentRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let referencedApp = extractReferencedAppName(from: text)
        let explicitScreenPhrases = [
            "what is on my screen", "what's on my screen",
            "what is on the screen", "what's on the screen",
            "what is on my display", "what's on my display",
            "describe my screen", "describe the screen",
            "describe what you see on my screen",
            "look at my screen", "check my screen",
            "read what's on the screen",
            "what's currently displayed on the screen",
            "what is currently displayed on the screen",
            "take a screenshot",
            "capture my screen",
        ]
        if explicitScreenPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        let mentionsScreenSurface = lower.contains("screen")
            || lower.contains("display")
            || lower.contains("screenshot")
            || (lower.contains("window") && referencedApp != nil)
        let asksToInspect = lower.contains("look")
            || lower.contains("check")
            || lower.contains("describe")
            || lower.contains("read")
            || lower.contains("show")
            || lower.contains("tell")
            || lower.contains("what is")
            || lower.contains("what's")
            || lower.contains("use")
        return mentionsScreenSurface && asksToInspect
    }

    private static func screenRepairToolCall(for text: String) -> ToolCall {
        let lower = text.lowercased()
        let appName = extractReferencedAppName(from: text)
        if lower.contains("take a screenshot")
            || lower.contains("capture my screen")
            || lower.contains("screenshot")
        {
            var arguments: [String: Any] = ["prompt": "Describe what is visible on the current screen."]
            if let appName {
                arguments["app"] = appName
            }
            return ToolCall(
                name: "screenshot",
                arguments: arguments
            )
        }
        var arguments: [String: Any] = [:]
        if let appName {
            arguments["app"] = appName
        }
        return ToolCall(name: "read_screen", arguments: arguments)
    }

    private static func extractReferencedAppName(from text: String) -> String? {
        let lower = text.lowercased()
        let builtInCandidates = [
            "Safari",
            "Google Chrome",
            "Chrome",
            "TextEdit",
            "Preview",
            "Finder",
            "Mail",
            "Notes",
            "Calendar",
            "Messages",
            "Slack",
            "Terminal",
            "Ghostty",
            "Discord",
            "WhatsApp",
            "ChatGPT",
            "Codex",
            "Fae",
        ]
        let runningCandidates = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        let candidates = Array(Set(builtInCandidates + runningCandidates)).sorted {
            $0.count > $1.count
        }

        for candidate in candidates {
            let normalized = candidate.lowercased()
            let markers = [
                " in \(normalized)",
                " on \(normalized)",
                " of \(normalized)",
                " from \(normalized)",
                " within \(normalized)",
                "the \(normalized) window",
                "the \(normalized) app",
                "\(normalized) window",
                "\(normalized) app",
            ]
            if markers.contains(where: { lower.contains($0) }) {
                return candidate
            }
        }

        return nil
    }

    /// Heuristic: requests that should be grounded in live tool data (calendar/notes/mail/etc.)
    /// rather than answered from model prior.
    private static func isToolBackedLookupRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let toolNouns = [
            "calendar", "diary", "schedule", "event", "events",
            "meeting", "meetings", "appointment", "appointments",
            "note", "notes", "reminder", "reminders",
            "mail", "email", "inbox", "contact", "contacts",
        ]
        let lookupVerbs = [
            "check", "show", "read", "find", "look up", "list", "what's", "what is",
        ]
        let hasNoun = toolNouns.contains { containsWholeWord($0, in: lower) }
        let hasVerb = lookupVerbs.contains { lower.contains($0) }
        return hasNoun && hasVerb
    }

    static func repairedToolCallForSkippedTurn(_ text: String) -> ToolCall? {
        let lower = text.lowercased()
        let quotedSegments = extractSingleQuotedSegments(from: text)
        let path = extractPathCandidate(from: text)
        let url = extractURLCandidate(from: text)

        if let path, lower.contains("write ") || lower.contains("save the text") || lower.contains("create a file") {
            if let content = quotedSegments.first {
                return ToolCall(name: "write", arguments: ["path": path, "content": content])
            }
        }

        if let path, lower.contains("edit ") || lower.contains("replace ") || lower.contains(" change ") {
            if let replacement = extractReplacementPair(from: text, quotedSegments: quotedSegments) {
                return ToolCall(
                    name: "edit",
                    arguments: [
                        "path": path,
                        "old_string": replacement.old,
                        "new_string": replacement.new,
                    ]
                )
            }
        }

        if let path, lower.contains("read ") || lower.contains("read the file") {
            return ToolCall(name: "read", arguments: ["path": path])
        }

        if let url,
           lower.contains("fetch ")
                || lower.contains("download ")
                || lower.contains("get the contents")
                || lower.contains("page at ")
        {
            return ToolCall(name: "fetch_url", arguments: ["url": url])
        }

        if let sessionSearchQuery = extractSessionSearchQuery(from: text) {
            return ToolCall(name: "session_search", arguments: ["query": sessionSearchQuery])
        }

        if lower.contains("web_search")
            || lower.contains("search the web")
            || lower.contains("search for ")
            || lower.contains("look up")
        {
            if let query = extractSearchQuery(from: text) {
                return ToolCall(name: "web_search", arguments: ["query": query])
            }
        }

        if let calendarCall = repairedCalendarLookupCall(from: text, lowercased: lower) {
            return calendarCall
        }

        if lower.contains("bash")
            || lower.contains("terminal")
            || lower.contains("run the command")
            || lower.contains("execute this bash command")
        {
            if let command = extractCommandCandidate(from: text) {
                return ToolCall(name: "bash", arguments: ["command": command])
            }
        }

        if lower.contains("self_config") || lower.contains("show me all your current settings") {
            return ToolCall(name: "self_config", arguments: ["action": "get_settings"])
        }

        if lower.contains("voice_identity") || lower.contains("voice identity") {
            return ToolCall(name: "voice_identity", arguments: ["action": "check_status"])
        }

        if isCameraIntentRequest(text)
            || lower.contains("capture from the webcam")
            || lower.contains("snap a picture")
        {
            return ToolCall(name: "camera", arguments: ["prompt": "Describe what the camera sees right now."])
        }

        if isScreenIntentRequest(text) {
            return screenRepairToolCall(for: text)
        }

        if lower.contains("create a task called ")
            || lower.contains("schedule a new task named ")
            || lower.contains("scheduler_create")
        {
            if let name = extractNamedEntity(from: text, markers: ["create a task called ", "task called ", "task named ", "schedule a new task named "]),
               let schedule = extractIntervalSchedule(from: lower)
            {
                return ToolCall(
                    name: "scheduler_create",
                    arguments: [
                        "name": name,
                        "schedule_type": "interval",
                        "schedule_params": schedule,
                        "action": "Run scheduled task '\(name)'"
                    ]
                )
            }
        }

        if lower.contains("scheduler_update")
            || (lower.contains("scheduler_list") && lower.contains("change its interval"))
            || (lower.contains("scheduler_list") && lower.contains("every 10 minutes"))
        {
            return ToolCall(name: "scheduler_list", arguments: [:])
        }

        if lower.contains("input_request")
            || lower.contains("ask me for a password")
            || lower.contains("prompt me for a secret key")
        {
            let secure = lower.contains("password") || lower.contains("secret") || lower.contains("key")
            let title: String
            let prompt: String
            let placeholder: String

            if lower.contains("password") {
                title = "Password Required"
                prompt = "Please enter the password."
                placeholder = "Enter password"
            } else if lower.contains("secret key") {
                title = "Secret Key Required"
                prompt = "Please enter the secret key."
                placeholder = "Enter secret key"
            } else {
                title = "Input Required"
                prompt = "Please enter the requested value."
                placeholder = ""
            }

            return ToolCall(
                name: "input_request",
                arguments: [
                    "title": title,
                    "prompt": prompt,
                    "placeholder": placeholder,
                    "secure": secure,
                    "return_to_model": !secure,
                ]
            )
        }

        if lower.contains("activate the ") || lower.contains("load the ") || lower.contains("activate_skill") {
            if let skillName = extractSkillName(from: text) {
                return ToolCall(name: "activate_skill", arguments: ["name": skillName])
            }
        }

        if lower.contains("run the ") || lower.contains("execute ") || lower.contains("run_skill") {
            if let skillName = extractExecutableSkillName(from: text) {
                return ToolCall(name: "run_skill", arguments: ["name": skillName])
            }
        }

        if lower.contains("take a screenshot")
            || lower.contains("capture my screen")
            || lower.contains("screenshot what's on my display")
            || lower.contains("screenshot what is on my display")
        {
            return ToolCall(name: "screenshot", arguments: ["prompt": "Describe what is visible on the current screen."])
        }

        if lower.contains("click on element "),
           let index = extractElementIndex(from: lower)
        {
            return ToolCall(name: "click", arguments: ["element_index": index])
        }

        if lower.contains("click on the fae menu bar icon") {
            return ToolCall(name: "click", arguments: ["x": 848, "y": 16])
        }

        if lower.contains("type "),
           let textToType = extractTypeText(from: text)
        {
            return ToolCall(name: "type_text", arguments: ["text": textToType])
        }

        if lower.contains("scroll down") || lower.contains("scroll the page down") {
            return ToolCall(name: "scroll", arguments: ["direction": "down", "amount": 300])
        }

        return nil
    }

    private static func extractSessionSearchQuery(from text: String) -> String? {
        let lower = text.lowercased()
        let markers = [
            "what did we say about",
            "what did we decide about",
            "search our conversation for",
            "search our conversations for",
            "search previous conversation for",
            "search previous conversations for",
            "search our chat for",
            "look through our chat for",
            "find in our chat",
            "find in previous chats",
            "session_search",
            "session search",
        ]

        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned = cleanInterestTopic(suffix) {
                return cleaned
            }
        }

        return nil
    }

    static func shouldAttemptRepairToolCall(
        _ call: ToolCall,
        registry: ToolRegistry,
        toolMode: String,
        privacyMode: String
    ) -> Bool {
        preflightToolDenial(
            for: [call],
            registry: registry,
            toolMode: toolMode,
            privacyMode: privacyMode
        ) == nil
    }

    static func preflightToolDenial(
        for calls: [ToolCall],
        registry: ToolRegistry,
        toolMode: String,
        privacyMode: String
    ) -> String? {
        for call in calls {
            guard registry.isToolAllowed(call.name, mode: toolMode, privacyMode: privacyMode) else {
                return "Tool '\(call.name)' is not available in current mode/privacy policy (\(toolMode), \(privacyMode))"
            }

            switch call.name {
            case "write", "edit":
                if let path = call.arguments["path"] as? String {
                    switch PathPolicy.validateWritePath(path) {
                    case .blocked(let reason):
                        return reason
                    case .allowed:
                        break
                    }
                }
            default:
                break
            }
        }

        return nil
    }

    static func shouldSuppressThinking(
        forceSuppressThinking: Bool,
        thinkingLevel: FaeThinkingLevel,
        isToolFollowUp: Bool
    ) -> Bool {
        guard !forceSuppressThinking else { return true }
        // Tool follow-up turns keep thinking enabled even in Fast mode so the
        // model can reason over tool results before forming a response.
        if isToolFollowUp { return false }
        return !thinkingLevel.enablesThinking
    }

    private static func extractSingleQuotedSegments(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "'([^']*)'") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let segmentRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[segmentRange])
        }
    }

    private static func extractReplacementPair(
        from text: String,
        quotedSegments: [String]
    ) -> (old: String, new: String)? {
        if quotedSegments.count >= 2 {
            return (quotedSegments[0], quotedSegments[1])
        }

        let patterns = [
            #"(?i)\breplace\s+([^\s'",.]+)\s+with\s+([^\s'",.]+)"#,
            #"(?i)\bchange\s+([^\s'",.]+)\s+to\s+([^\s'",.]+)"#,
        ]

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let oldRange = Range(match.range(at: 1), in: text),
                  let newRange = Range(match.range(at: 2), in: text)
            else {
                continue
            }

            let old = String(text[oldRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let new = String(text[newRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !old.isEmpty, !new.isEmpty {
                return (old, new)
            }
        }

        return nil
    }

    private static func extractPathCandidate(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:(?:~|/)[^\s'",]+)"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let candidateRange = Range(match.range(at: 0), in: text)
        else { return nil }
        return String(text[candidateRange])
    }

    private static func extractURLCandidate(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s'"]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let candidateRange = Range(match.range(at: 0), in: text)
        else { return nil }
        return String(text[candidateRange])
    }

    private static func extractSearchQuery(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in ["search for ", "look up ", "search the web for "] {
            if let range = lower.range(of: marker) {
                let originalRange = range.upperBound..<text.endIndex
                let query = normalizeSearchRepairQuery(String(text[originalRange]))
                if !query.isEmpty {
                    return query
                }
            }
        }
        return nil
    }

    private static func normalizeSearchRepairQuery(_ raw: String) -> String {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = query.lowercased()

        let leadingPrefixes = [
            "for me about ",
            "for me on ",
            "for me regarding ",
            "about ",
            "regarding ",
        ]
        for prefix in leadingPrefixes where lower.hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }

        let trailingPatterns = [
            #"(?i)^(.*?)(?:,?\s+(?:then|and then)\s+(?:give|tell|show|provide|report|summarize|write|return)\b.*)$"#,
            #"(?i)^(.*?)(?:,?\s+and\s+(?:give|tell|show|provide|report|summarize|write|return)\b.*)$"#,
            #"(?i)^(.*?)(?:,?\s+(?:then|and then|and)\s+briefly\b.*)$"#,
        ]

        for pattern in trailingPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(query.startIndex..<query.endIndex, in: query)
            guard let match = regex.firstMatch(in: query, range: range),
                  match.numberOfRanges > 1,
                  let capturedRange = Range(match.range(at: 1), in: query)
            else {
                continue
            }
            query = String(query[capturedRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }

        return query
    }

    private static func repairedCalendarLookupCall(from text: String, lowercased lower: String) -> ToolCall? {
        let calendarIntent = [
            "calendar", "diary", "schedule", "event", "events",
            "meeting", "meetings", "appointment", "appointments",
        ].contains { containsWholeWord($0, in: lower) }
        guard calendarIntent else { return nil }

        if let date = extractISODateCandidate(from: text) {
            return ToolCall(name: "calendar", arguments: ["action": "list_date", "date": date])
        }

        if lower.contains("this week") || lower.contains("next 7 days") || lower.contains("next week") {
            return ToolCall(name: "calendar", arguments: ["action": "list_week"])
        }

        if lower.contains("search") || lower.contains("find ") || lower.contains("look for ") {
            if let query = extractCalendarSearchQuery(from: text, lowercased: lower) {
                return ToolCall(name: "calendar", arguments: ["action": "search", "query": query])
            }
        }

        return ToolCall(name: "calendar", arguments: ["action": "list_today"])
    }

    private static func extractISODateCandidate(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let candidateRange = Range(match.range(at: 0), in: text)
        else {
            return nil
        }
        return String(text[candidateRange])
    }

    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let regex = try? NSRegularExpression(pattern: #"\b\#(escaped)\b"#) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func extractCalendarSearchQuery(from text: String, lowercased lower: String) -> String? {
        for marker in ["search my calendar for ", "find in my calendar ", "find on my calendar ", "look for "] {
            if let range = lower.range(of: marker) {
                let query = text[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !query.isEmpty {
                    return query
                }
            }
        }
        return extractSearchQuery(from: text)
    }

    private static func extractCommandCandidate(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in ["run the command ", "execute this bash command: ", "run ", "command: "] {
            if let range = lower.range(of: marker) {
                let candidate = text[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func extractNamedEntity(from text: String, markers: [String]) -> String? {
        let lower = text.lowercased()
        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            let remainder = text[range.upperBound...]
            let terminators = [" that ", " to ", " with ", ".", ",", "\n"]
            let stop = terminators.compactMap { remainder.range(of: $0)?.lowerBound }.min() ?? remainder.endIndex
            let value = remainder[..<stop].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func extractIntervalSchedule(from lower: String) -> [String: String]? {
        guard let regex = try? NSRegularExpression(pattern: #"every\s+(\d+)\s+(minute|minutes|hour|hours)"#),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
              let amountRange = Range(match.range(at: 1), in: lower),
              let unitRange = Range(match.range(at: 2), in: lower)
        else {
            return nil
        }

        let amount = String(lower[amountRange])
        let unit = String(lower[unitRange])
        if unit.hasPrefix("minute") {
            return ["minutes": amount]
        }
        return ["hours": amount]
    }

    private static func extractSkillName(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in ["activate the ", "load the ", "activate "] {
            guard let range = lower.range(of: marker) else { continue }
            let remainder = text[range.upperBound...]
            if let skillRange = remainder.range(of: "skill", options: .caseInsensitive) {
                let name = remainder[..<skillRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if isSafeSkillName(name) {
                    return name
                }
            }
        }
        return nil
    }

    private static func extractExecutableSkillName(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in ["run the ", "run ", "execute "] {
            guard let range = lower.range(of: marker) else { continue }
            let remainder = text[range.upperBound...]
            let stop = [" skill", ".", ",", "\n"].compactMap { remainder.range(of: $0, options: .caseInsensitive)?.lowerBound }.min() ?? remainder.endIndex
            let candidate = remainder[..<stop].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if isSafeSkillName(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func extractElementIndex(from lower: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"element\s+(\d+)"#),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
              let range = Range(match.range(at: 1), in: lower)
        else {
            return nil
        }
        return Int(lower[range])
    }

    private static func extractTypeText(from text: String) -> String? {
        if let quoted = extractSingleQuotedSegments(from: text).first, !quoted.isEmpty {
            return quoted
        }

        let lower = text.lowercased()
        for marker in ["type ", "type_text "] {
            guard let range = lower.range(of: marker) else { continue }
            let remainder = text[range.upperBound...]
            let stop = [" into ", " in the ", " into the ", ".", ",", "\n"]
                .compactMap { remainder.range(of: $0, options: .caseInsensitive)?.lowerBound }
                .min() ?? remainder.endIndex
            let candidate = remainder[..<stop].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !candidate.isEmpty {
                return candidate
            }
        }

        return nil
    }

    private static func estimateTokenCount(for text: String) -> Int {
        Int(Double(text.count) / 3.5)
    }

    static func directToolReplyText(for call: ToolCall, result: ToolResult) -> String? {
        guard !result.isError else { return nil }

        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch call.name {
        case "bash":
            guard trimmed.count <= 500 else { return nil }
            return "Command output:\n\(trimmed)"

        case "calendar", "reminders", "contacts", "mail", "notes":
            return trimmed

        case "screenshot":
            return stripScreenshotEnvelope(from: trimmed)

        case "camera":
            return stripSimpleToolPrefix("Camera capture:\n", from: trimmed)

        default:
            return nil
        }
    }

    private static func serializeArguments(_ args: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return "{}"
    }

    private static func stripScreenshotEnvelope(from output: String) -> String {
        guard output.hasPrefix("Screenshot ("),
              let newline = output.firstIndex(of: "\n")
        else {
            return output
        }
        return String(output[output.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSimpleToolPrefix(_ prefix: String, from output: String) -> String {
        guard output.hasPrefix(prefix) else { return output }
        return String(output.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract an audio file path from skill output JSON (looks for "audio_file" key).
    private static func extractAudioFilePath(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["audio_file"] as? String,
              path.hasSuffix(".wav")
        else { return nil }
        return path
    }

    private static func inferUserPresentFromCameraOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        let absentSignals = [
            "no person", "no people", "nobody", "empty", "vacant", "no one",
            "no human", "no face", "unoccupied",
        ]
        if absentSignals.contains(where: { lower.contains($0) }) {
            return false
        }
        return true
    }

    private static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tool Execution

    private func startDeferredToolJob(
        userText: String,
        toolCalls: [ToolCall],
        assistantToolMessage: String,
        forceSuppressThinking: Bool,
        capabilityTicket: CapabilityTicket?,
        explicitUserAuthorization: Bool,
        generationContext: GenerationContext,
        originTurnID: String?
    ) async {
        let job = DeferredToolJob(
            id: UUID(),
            userText: userText,
            toolCalls: toolCalls,
            assistantToolMessage: assistantToolMessage,
            forceSuppressThinking: forceSuppressThinking,
            capabilityTicket: capabilityTicket,
            explicitUserAuthorization: explicitUserAuthorization,
            generationContext: generationContext,
            originTurnID: originTurnID
        )

        await conversationState.addAssistantMessage(job.assistantToolMessage)
        debugLog(debugConsole, .pipeline, "Deferred tool job queued: \(job.id.uuidString.prefix(8)) (\(job.toolCalls.count) call(s))")

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDeferredToolJob(job)
        }
        deferredToolTasks[job.id] = task
    }

    private func runDeferredToolJob(_ job: DeferredToolJob) async {
        defer { deferredToolTasks[job.id] = nil }
        guard !Task.isCancelled else { return }

        debugLog(debugConsole, .pipeline, "Deferred tool job started: \(job.id.uuidString.prefix(8))")

        var toolSuccessCount = 0
        var toolFailureCount = 0
        var firstToolError: String?
        var directToolReply: String?

        for call in job.toolCalls {
            guard !Task.isCancelled else { return }

            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)
            let preflightDenial = Self.preflightToolDenial(
                for: [call],
                registry: registry,
                toolMode: effectiveToolMode(),
                privacyMode: effectivePrivacyMode()
            )

            if let preflightDenial {
                debugLog(debugConsole, .approval, "Blocked deferred tool call before execution: \(call.name) — \(preflightDenial)")
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = preflightDenial
                }
                await recordWorkflowPreflightDenied(
                    turnID: job.originTurnID,
                    callId: callId,
                    call: call,
                    reason: preflightDenial
                )
                await conversationState.addToolResult(id: callId, name: call.name, content: preflightDenial)
                continue
            }

            let inputPreview = String(inputJSON.prefix(100))
            debugLog(debugConsole, .toolCall, "id=\(callId.prefix(8)) name=\(call.name) args=\(inputPreview) [deferred]")
            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))

            let result = await executeTool(
                call,
                capabilityTicketOverride: job.capabilityTicket,
                explicitUserAuthorizationOverride: job.explicitUserAuthorization,
                generationContextOverride: job.generationContext,
                traceTurnID: job.originTurnID,
                traceToolCallID: callId
            )
            if result.isError {
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = result.output
                }
            } else {
                toolSuccessCount += 1
                if job.toolCalls.count == 1,
                   let reply = Self.directToolReplyText(for: call, result: result)
                {
                    directToolReply = reply
                }
            }

            let outputPreview = String(result.output.prefix(100))
            debugLog(debugConsole, .toolResult, "id=\(callId.prefix(8)) name=\(call.name) status=\(result.isError ? "error" : "ok") output=\(outputPreview) [deferred]")
            eventBus.send(.toolResult(
                id: callId,
                name: call.name,
                success: !result.isError,
                output: String(result.output.prefix(200))
            ))

            await conversationState.addToolResult(
                id: callId,
                name: call.name,
                content: result.output
            )
        }

        guard !Task.isCancelled else { return }

        debugLog(debugConsole, .qa, "Deferred tool summary: success=\(toolSuccessCount) failure=\(toolFailureCount)")

        if toolFailureCount > 0 && toolSuccessCount == 0 {
            let reason = firstToolError ?? "the tool call was denied or failed"
            let msg = "I couldn't complete that background check because the required tool didn't run: \(reason)"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            if job.generationContext.allowsAudibleOutput {
                await speakText(msg, isFinal: true)
            }
            await finalizeWorkflowTraceIfNeeded(turnID: job.originTurnID, assistantOutcome: msg, success: false)
            return
        }

        // Wait for any in-progress speech to finish before starting the
        // follow-up generation.  Without this, the tool-result LLM response
        // can interrupt the acknowledgment message mid-sentence.
        for _ in 0..<60 {
            guard !Task.isCancelled else { return }
            if !assistantSpeaking, !assistantGenerating { break }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        guard Self.shouldStartDeferredFollowUp(
            originTurnID: job.originTurnID,
            currentTurnID: currentTurnID,
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        ) else {
            debugLog(debugConsole, .pipeline, "Deferred tool follow-up dropped: origin turn no longer active")
            await abandonWorkflowTraceIfNeeded(
                turnID: job.originTurnID,
                reason: "Deferred follow-up dropped because the originating turn was no longer active."
            )
            return
        }

        if let directToolReply {
            eventBus.send(.assistantText(text: directToolReply, isFinal: true))
            if job.generationContext.allowsAudibleOutput {
                await speakText(directToolReply, isFinal: true, emitAssistantText: false)
            }
            await conversationState.addAssistantMessage(directToolReply)
            await synchronizeLLMSession()
            await persistFinalAssistantTurnIfNeeded(directToolReply, turnID: job.originTurnID)
            debugLog(debugConsole, .qa, "=== TURN END deferred_direct_tool_reply name=\(job.toolCalls[0].name) ===")
            return
        }

        explicitUserAuthorizationForTurn = job.explicitUserAuthorization
        assistantGenerating = true
        eventBus.send(.assistantGenerating(true))
        if job.generationContext.playsThinkingTone {
            await playback.playThinkingTone()
        }

        // Re-issue a capability ticket for the follow-up turn so the LLM
        // can make additional tool calls (e.g. a second web_search).
        activeCapabilityTicket = CapabilityTicketIssuer.issue(
            mode: effectiveToolMode(),
            privacyMode: effectivePrivacyMode(),
            registry: registry
        )

        await generateWithTools(
            userText: job.userText,
            isToolFollowUp: true,
            turnCount: 1,
            forceSuppressThinking: job.forceSuppressThinking,
            generationContext: job.generationContext
        )
    }

    private static let defaultToolTimeoutSeconds: TimeInterval = 30
    private static let extendedVisionToolTimeoutSeconds: TimeInterval = 180

    static func toolTimeoutSeconds(for toolName: String) -> TimeInterval {
        switch toolName {
        case "screenshot", "camera", "read_screen":
            return extendedVisionToolTimeoutSeconds
        default:
            return defaultToolTimeoutSeconds
        }
    }

    private func executeTool(
        _ call: ToolCall,
        capabilityTicketOverride: CapabilityTicket? = nil,
        explicitUserAuthorizationOverride: Bool? = nil,
        proactiveContext: ProactiveRequestContext? = nil,
        generationContextOverride: GenerationContext? = nil,
        traceTurnID: String? = nil,
        traceToolCallID: String? = nil
    ) async -> ToolResult {
        let workflowTurnID = traceTurnID ?? currentTurnID
        await recordWorkflowToolCall(
            turnID: workflowTurnID,
            callId: traceToolCallID,
            call: call
        )

        // Tool mode enforcement — reject tools not allowed in current mode.
        let toolMode = effectiveToolMode()
        let privacyMode = effectivePrivacyMode()
        debugLog(debugConsole, .toolCall, "Execute request: \(call.name) mode=\(toolMode) privacy=\(privacyMode)")
        guard registry.isToolAllowed(call.name, mode: toolMode, privacyMode: privacyMode) else {
            debugLog(debugConsole, .toolResult, "Blocked by mode/privacy: \(call.name) mode=\(toolMode) privacy=\(privacyMode)")
            let result = ToolResult.error("Tool '\(call.name)' is not available in current mode/privacy policy (\(toolMode), \(privacyMode))")
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: nil,
                latencyMs: nil
            )
            return result
        }

        if let proactiveContext,
           !proactiveContext.allowedTools.contains(call.name)
        {
            debugLog(debugConsole, .toolResult, "Blocked by proactive allowlist: \(call.name) task=\(proactiveContext.taskId)")
            let result = ToolResult.error("Tool '\(call.name)' is not allowed for proactive task '\(proactiveContext.taskId)'")
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: nil,
                latencyMs: nil
            )
            return result
        }

        // Computer-use action step limiter (click/type_text/scroll).
        let actionTools: Set<String> = ["click", "type_text", "scroll"]
        if actionTools.contains(call.name) {
            computerUseStepCount += 1
            if computerUseStepCount > Self.maxComputerUseSteps {
                let result = ToolResult.error("Computer use step limit reached (\(Self.maxComputerUseSteps) per turn). Ask the user before continuing.")
                await recordWorkflowToolResult(
                    turnID: workflowTurnID,
                    callId: traceToolCallID,
                    call: call,
                    result: result,
                    approved: nil,
                    latencyMs: nil
                )
                return result
            }
        }

        // Auto-enable vision when a vision tool executes after passing the approval gate.
        // The user already gave explicit consent, so don't let a hidden config toggle block it.
        let visionTools: Set<String> = ["screenshot", "camera", "read_screen",
                                         "click", "type_text", "scroll", "find_element"]
        if visionTools.contains(call.name) && !effectiveVisionEnabled() {
            visionEnabledLive = true
            debugLog(debugConsole, .pipeline, "Vision auto-enabled: user approved a vision tool")
            Task { @MainActor in
                SelfConfigTool.configPatcher?("vision.enabled", true)
            }
        }

        // Build VLM provider closure for vision tools.
        // Capture an effective config with vision enabled so loadVLMIfNeeded succeeds.
        var vlmConfigMut = config
        vlmConfigMut.vision.enabled = effectiveVisionEnabled()
        let vlmConfig = vlmConfigMut
        let capturedMM = modelManager
        let vlmProvider: VLMProvider? = {
            guard let mm = capturedMM else { return nil }
            return try await mm.loadVLMIfNeeded(config: vlmConfig)
        }

        guard let tool = registry.tool(named: call.name, vlmProvider: vlmProvider) else {
            let result = ToolResult.error("Unknown tool: \(call.name)")
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: nil,
                latencyMs: nil
            )
            return result
        }

        let policyProfile = currentPolicyProfile()
        let selfConfigRead = Self.isSelfConfigReadAction(arguments: call.arguments)
        let effectiveRequiresApproval = Self.toolRequiresApproval(
            toolName: call.name,
            arguments: call.arguments,
            defaultRequiresApproval: tool.requiresApproval
        )
        let effectiveRiskLevel: ToolRiskLevel = (call.name == "self_config" && selfConfigRead) ? .low : tool.riskLevel

        // Rate limiting.
        if let limitError = await rateLimiter.checkLimit(
            tool: call.name,
            riskLevel: effectiveRiskLevel,
            profile: policyProfile
        ) {
            debugLog(debugConsole, .toolResult, "Rate limited: \(call.name) reason=\(limitError)")
            let result = ToolResult.error(limitError)
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: nil,
                latencyMs: nil
            )
            return result
        }

        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let effectiveTicket = capabilityTicketOverride ?? activeCapabilityTicket
        let hasCapabilityTicket = effectiveTicket?.allows(toolName: call.name) ?? false
        let explicitAuthorization = explicitUserAuthorizationOverride ?? explicitUserAuthorizationForTurn
        let effectiveGenerationContext = generationContextOverride ?? currentTurnGenerationContext
        let intent = ActionIntent(
            source: proactiveContext?.source ?? effectiveGenerationContext?.actionSource ?? .voice,
            toolName: call.name,
            riskLevel: effectiveRiskLevel,
            requiresApproval: effectiveRequiresApproval,
            isOwner: currentSpeakerIsOwner,
            livenessScore: livenessScore,
            explicitUserAuthorization: explicitAuthorization,
            hasCapabilityTicket: hasCapabilityTicket,
            policyProfile: policyProfile,
            argumentSummary: Self.buildApprovalDescription(
                toolName: call.name,
                reason: "confirmation required",
                arguments: call.arguments
            ),
            schedulerTaskId: proactiveContext?.taskId,
            schedulerAllowedTools: proactiveContext?.allowedTools ?? [],
            schedulerConsentGranted: proactiveContext?.consentGranted ?? false
        )

        let brokerDecisionStartedAt = Date()
        var workflowDamageControlIntervened = false

        // MARK: Damage Control — Layer 0 (pre-broker)
        // Evaluates before the outbound guard and TrustedActionBroker.
        // Catastrophic operations are blocked or require manual-only UI confirmation.
        let dcVerdict = await damageControlPolicy.evaluate(
            toolName: call.name,
            arguments: call.arguments,
            locality: modelLocality
        )
        var dcManualDecision: BrokerDecision? = nil
        switch dcVerdict {
        case .allow:
            break

        case .block(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_block",
                toolName: call.name,
                decision: "deny",
                reasonCode: "damageControlBlock",
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC block: \(call.name) — \(reason)")
            let result = ToolResult.error("Blocked by damage-control policy: \(reason)")
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: nil,
                latencyMs: nil,
                damageControlIntervened: true
            )
            return result

        case .disaster(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_disaster",
                toolName: call.name,
                decision: "confirm",
                reasonCode: "damageControlDisaster",
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC disaster: \(call.name) — \(reason)")
            dcManualDecision = .confirm(
                prompt: ConfirmationPrompt(message: reason),
                reason: DecisionReason(code: .damageControlDisaster, message: reason),
                manualOnly: true,
                isDisasterLevel: true
            )

        case .confirmManual(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_confirm_manual",
                toolName: call.name,
                decision: "confirm",
                reasonCode: "damageControlConfirmManual",
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC confirm manual: \(call.name) — \(reason)")
            dcManualDecision = .confirm(
                prompt: ConfirmationPrompt(message: reason),
                reason: DecisionReason(code: .damageControlConfirmManual, message: reason),
                manualOnly: true,
                isDisasterLevel: false
            )
        }

        let brokerDecision: BrokerDecision
        if let dcVerdict = dcManualDecision {
            // DC mandated a manual confirmation — skip outbound guard and broker.
            brokerDecision = dcVerdict
        } else if let outboundDecision = await outboundGuard.evaluate(
            toolName: call.name,
            arguments: call.arguments
        ) {
            switch outboundDecision {
            case .confirm(let message):
                brokerDecision = .confirm(
                    prompt: ConfirmationPrompt(message: message),
                    reason: DecisionReason(
                        code: .outboundRecipientNovelty,
                        message: message
                    )
                )
            case .deny(let message):
                brokerDecision = .deny(
                    reason: DecisionReason(
                        code: .outboundPayloadRisk,
                        message: message
                    )
                )
            }
        } else {
            brokerDecision = await actionBroker.evaluate(intent)
        }
        let brokerDecisionString: String
        let brokerReasonCode: String?
        switch brokerDecision {
        case .allow(let reason):
            brokerDecisionString = "allow"
            brokerReasonCode = reason.code.rawValue
        case .allowWithTransform(_, let reason):
            brokerDecisionString = "allow_with_transform"
            brokerReasonCode = reason.code.rawValue
        case .confirm(_, let reason, _, _):
            brokerDecisionString = "confirm"
            brokerReasonCode = reason.code.rawValue
        case .deny(let reason):
            brokerDecisionString = "deny"
            brokerReasonCode = reason.code.rawValue
        }

        debugLog(debugConsole, .approval, "Broker decision for \(call.name): \(brokerDecisionString) reason=\(brokerReasonCode ?? "none")")

        await securityLogger.log(
            event: "broker_decision",
            toolName: call.name,
            decision: brokerDecisionString,
            reasonCode: brokerReasonCode,
            arguments: call.arguments
        )

        var effectiveDecision = brokerDecision
        if UserDefaults.standard.bool(forKey: "fae.security.shadowMode") {
            switch brokerDecision {
            case .confirm(_, let reason, _, _), .deny(let reason):
                await securityLogger.log(
                    event: "shadow_decision",
                    toolName: call.name,
                    decision: brokerDecisionString,
                    reasonCode: reason.code.rawValue,
                    approved: nil,
                    success: true,
                    error: "Shadow mode bypassed enforcement",
                    arguments: call.arguments
                )
                effectiveDecision = .allow(reason: reason)
            default:
                break
            }
        }

        var approvedByUser = false
        switch effectiveDecision {
        case .allow:
            break

        case .allowWithTransform(let transform, _):
            if let transformError = await applySafetyTransform(
                transform,
                toolName: call.name,
                arguments: call.arguments
            ) {
                let result = ToolResult.error(transformError)
                await recordWorkflowToolResult(
                    turnID: workflowTurnID,
                    callId: traceToolCallID,
                    call: call,
                    result: result,
                    approved: nil,
                    latencyMs: nil,
                    damageControlIntervened: workflowDamageControlIntervened
                )
                return result
            }

        case .confirm(let prompt, _, let manualOnly, let isDisasterLevel):
            if let manager = approvalManager {
                debugLog(debugConsole, .approval, "Requesting approval for \(call.name): \(prompt.message) manualOnly=\(manualOnly)")
                awaitingApproval = true
                manualOnlyApprovalPending = manualOnly
                async let approvalDecision = manager.requestApproval(
                    toolName: call.name,
                    description: prompt.message,
                    manualOnly: manualOnly,
                    isDisasterLevel: isDisasterLevel
                )
                // For manual-only approvals, don't speak the description aloud — the overlay
                // is the primary communication channel. For normal approvals, speak the prompt.
                if !manualOnly {
                    await speakDirect(prompt.message)
                }
                let approved = await approvalDecision
                awaitingApproval = false
                manualOnlyApprovalPending = false
                approvedByUser = approved
                debugLog(debugConsole, .approval, "Approval result for \(call.name): \(approved)")
                if !approved {
                    if let analytics = toolAnalytics {
                        let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                        await analytics.record(
                            toolName: call.name,
                            success: false,
                            latencyMs: latencyMs,
                            approved: false,
                            error: "Tool execution denied by user"
                        )
                    }
                    await securityLogger.log(
                        event: "tool_denied",
                        toolName: call.name,
                        decision: "confirm",
                        reasonCode: brokerReasonCode,
                        approved: false,
                        success: false,
                        error: "Tool execution denied by user",
                        arguments: call.arguments
                    )
                    let result = ToolResult.error("Tool execution denied by user.")
                    await recordWorkflowToolResult(
                        turnID: workflowTurnID,
                        callId: traceToolCallID,
                        call: call,
                        result: result,
                        approved: false,
                        latencyMs: Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000),
                        damageControlIntervened: workflowDamageControlIntervened
                    )
                    return result
                }
            } else {
                if let analytics = toolAnalytics {
                    let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                    await analytics.record(
                        toolName: call.name,
                        success: false,
                        latencyMs: latencyMs,
                        approved: nil,
                        error: "Tool requires approval, but no approval manager is available"
                    )
                }
                await securityLogger.log(
                    event: "tool_denied",
                    toolName: call.name,
                    decision: "confirm",
                    reasonCode: brokerReasonCode,
                    approved: nil,
                    success: false,
                    error: "No approval manager available",
                    arguments: call.arguments
                )
                let result = ToolResult.error("Tool requires approval, but no approval manager is available.")
                await recordWorkflowToolResult(
                    turnID: workflowTurnID,
                    callId: traceToolCallID,
                    call: call,
                    result: result,
                    approved: nil,
                    latencyMs: Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000),
                    damageControlIntervened: workflowDamageControlIntervened
                )
                return result
            }

        case .deny(let reason):
            debugLog(debugConsole, .toolResult, "Denied by broker: \(call.name) reason=\(reason.code.rawValue)")
            if let analytics = toolAnalytics {
                let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                await analytics.record(
                    toolName: call.name,
                    success: false,
                    latencyMs: latencyMs,
                    approved: nil,
                    error: "Denied by broker: \(reason.code.rawValue)"
                )
            }
            await securityLogger.log(
                event: "tool_denied",
                toolName: call.name,
                decision: "deny",
                reasonCode: reason.code.rawValue,
                approved: nil,
                success: false,
                error: reason.message,
                arguments: call.arguments
            )
            let result = ToolResult.error(reason.message)
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: nil,
                latencyMs: Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000),
                damageControlIntervened: workflowDamageControlIntervened
            )
            return result
        }

        // Execute with timeout and analytics.
        var executionArguments = call.arguments
        if call.name == "run_skill", let ticketId = effectiveTicket?.id {
            executionArguments["capability_ticket"] = ticketId
        }
        if call.name == "voice_identity",
           let action = executionArguments["action"] as? String,
           action == "collect_sample"
        {
            executionArguments["enrollment_active"] = firstOwnerEnrollmentActive
        }

        let timeoutSeconds = Self.toolTimeoutSeconds(for: call.name)
        let startTime = Date()
        let result: ToolResult
        do {
            result = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await tool.execute(input: executionArguments)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .error("Tool timed out after \(Int(timeoutSeconds))s")
                }
                guard let r = try await group.next() else {
                    group.cancelAll()
                    return .error("Tool execution did not return a result")
                }
                group.cancelAll()
                return r
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Tool threw error: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            if let analytics = toolAnalytics {
                await analytics.record(
                    toolName: call.name,
                    success: false,
                    latencyMs: latencyMs,
                    approved: approvedByUser ? true : nil,
                    error: error.localizedDescription
                )
            }
            await securityLogger.log(
                event: "tool_result",
                toolName: call.name,
                decision: brokerDecisionString,
                reasonCode: brokerReasonCode,
                approved: approvedByUser ? true : nil,
                success: false,
                error: error.localizedDescription,
                arguments: call.arguments
            )
            let result = ToolResult.error("Tool error: \(error.localizedDescription)")
            await recordWorkflowToolResult(
                turnID: workflowTurnID,
                callId: traceToolCallID,
                call: call,
                result: result,
                approved: approvedByUser ? true : nil,
                latencyMs: latencyMs,
                damageControlIntervened: workflowDamageControlIntervened
            )
            return result
        }

        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        if let analytics = toolAnalytics {
            await analytics.record(
                toolName: call.name,
                success: !result.isError,
                latencyMs: latencyMs,
                approved: approvedByUser ? true : nil,
                error: result.isError ? result.output : nil
            )
        }

        await securityLogger.log(
            event: "tool_result",
            toolName: call.name,
            decision: brokerDecisionString,
            reasonCode: brokerReasonCode,
            approved: approvedByUser ? true : nil,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            arguments: call.arguments
        )

        if !result.isError {
            await outboundGuard.recordSuccessfulSend(toolName: call.name, arguments: call.arguments)
        }

        await recordWorkflowToolResult(
            turnID: workflowTurnID,
            callId: traceToolCallID,
            call: call,
            result: result,
            approved: approvedByUser ? true : nil,
            latencyMs: latencyMs,
            damageControlIntervened: workflowDamageControlIntervened
        )

        return result
    }

    /// Map current tool mode to an autonomy policy profile.
    ///
    /// - off => cautious profile
    /// - read_only/read_write/full => balanced profile
    /// - full_no_approval => autonomous profile
    private func currentPolicyProfile() -> PolicyProfile {
        switch effectiveToolMode() {
        case "off":
            return .moreCautious
        case "full_no_approval":
            return .moreAutonomous
        case "read_only", "read_write", "full":
            return .balanced
        default:
            return .balanced
        }
    }

    /// Apply deterministic safety wrappers before executing a tool.
    private func applySafetyTransform(
        _ transform: SafetyTransform,
        toolName: String,
        arguments: [String: Any]
    ) async -> String? {
        switch transform {
        case .none:
            return nil

        case .checkpointBeforeMutation:
            if ["write", "edit"].contains(toolName) {
                guard let path = arguments["path"] as? String else {
                    return "Safety checkpoint failed: missing path argument"
                }

                switch PathPolicy.validateWritePath(path) {
                case .blocked(let reason):
                    return reason
                case .allowed(let canonical):
                    let checkpointId = ReversibilityEngine.createCheckpoint(
                        for: canonical,
                        reason: "\(toolName) transform"
                    )
                    if checkpointId == nil {
                        return "Safety checkpoint failed: could not create reversible snapshot"
                    }

                    await securityLogger.log(
                        event: "safety_transform",
                        toolName: toolName,
                        decision: "checkpointBeforeMutation",
                        reasonCode: nil,
                        approved: nil,
                        success: true,
                        error: nil,
                        arguments: ["path": canonical, "checkpoint_id": checkpointId ?? ""]
                    )
                    return nil
                }
            }

            if toolName == "manage_skill",
               let action = arguments["action"] as? String,
               action == "delete",
               let name = arguments["name"] as? String,
               Self.isSafeSkillName(name)
            {
                let path = SkillManager.skillsDirectory.appendingPathComponent(name).path
                let checkpointId = ReversibilityEngine.createCheckpoint(
                    for: path,
                    reason: "manage_skill delete transform"
                )
                if checkpointId == nil {
                    return "Safety checkpoint failed: could not snapshot skill before delete"
                }
                await securityLogger.log(
                    event: "safety_transform",
                    toolName: toolName,
                    decision: "checkpointBeforeMutation",
                    reasonCode: nil,
                    approved: nil,
                    success: true,
                    error: nil,
                    arguments: ["path": path, "checkpoint_id": checkpointId ?? ""]
                )
            }

            return nil
        }
    }

    /// Self-config actions that are read-only and should bypass approval prompts.
    private static let selfConfigReadActions: Set<String> = [
        "get_settings", "get_directive", "get_instructions",
    ]

    static func isSelfConfigReadAction(arguments: [String: Any]) -> Bool {
        guard let action = (arguments["action"] as? String)?.lowercased() else { return false }
        return selfConfigReadActions.contains(action)
    }

    static func toolRequiresApproval(
        toolName: String,
        arguments: [String: Any],
        defaultRequiresApproval: Bool
    ) -> Bool {
        if toolName == "self_config" {
            return !isSelfConfigReadAction(arguments: arguments)
        }
        if toolName == "calendar" {
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            if action == "create" {
                return true
            }
        }
        if toolName == "reminders" {
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            if action == "create" || action == "complete" {
                return true
            }
        }
        return defaultRequiresApproval
    }

    private static func selfConfigApprovalSummary(arguments: [String: Any]) -> String {
        let action = (arguments["action"] as? String)?.lowercased() ?? ""
        if selfConfigReadActions.contains(action) {
            return "I can check your current settings."
        }

        if action == "adjust_setting" {
            let key = arguments["key"] as? String ?? "a setting"
            return "I can update \(key)."
        }

        if action.contains("directive") || action.contains("instructions") {
            switch action {
            case "set_directive", "set_instructions":
                return "I can replace your persistent directive."
            case "append_directive", "append_instructions":
                return "I can append to your persistent directive."
            case "clear_directive", "clear_instructions":
                return "I can clear your persistent directive."
            default:
                return "I can update your persistent directive."
            }
        }

        return "I can update your Fae settings."
    }

    /// Build a plain-language confirmation prompt with concrete action context.
    private static func buildApprovalDescription(
        toolName: String, reason: String, arguments: [String: Any]
    ) -> String {
        let summary: String
        switch toolName {
        case "bash":
            if let command = arguments["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
                summary = "I can run this command: \(preview)."
            } else {
                summary = "I can run a shell command for this step."
            }

        case "write":
            if let path = arguments["path"] as? String {
                summary = "I can write to \(path)."
            } else {
                summary = "I can write file content for this step."
            }

        case "edit":
            if let path = arguments["path"] as? String {
                summary = "I can edit \(path)."
            } else {
                summary = "I can edit a file for this step."
            }

        case "self_config":
            summary = selfConfigApprovalSummary(arguments: arguments)

        case "run_skill":
            let skillName = arguments["name"] as? String ?? "a skill"
            summary = "I can run \(skillName) now."

        case "manage_skill":
            let action = arguments["action"] as? String ?? "modify"
            summary = "I can \(action) a skill in your local skills library."

        case "delegate_agent":
            let provider = arguments["provider"] as? String ?? "an external agent"
            let mode = arguments["mode"] as? String ?? "read_only"
            summary = "I can delegate this task to \(provider) in \(mode) mode."

        case "scheduler_create":
            summary = "I can create a scheduled task that runs automatically later."

        case "scheduler_update":
            summary = "I can update a scheduled task."

        case "scheduler_delete":
            summary = "I can delete this scheduled task."

        default:
            summary = "I can use \(toolName) for this step."
        }

        return "\(summary) Say yes or no, or press the Yes/No button."
    }

    // MARK: - Helpers

    private static func isSafeSkillName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..") { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}
