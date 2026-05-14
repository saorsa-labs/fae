import Foundation

/// Pure static helper functions for turn-level decision making: memory recall,
/// tool visibility, deterministic easy turns (arithmetic, name declaration/recall),
/// TTS batching, voice approval, tool aliases, and LLM failure messages.
///
/// Extracted from PipelineCoordinator to reduce its line count.
/// All functions are stateless.
enum TurnHelpers {

    // MARK: - Memory Recall

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

    static func explicitInterestTopic(in userText: String, lower: String) -> String? {
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

    static func cleanInterestTopic(_ topic: String) -> String? {
        let cleaned = topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Tool Visibility

    static func visibleToolNamesForTurn(
        firstOwnerEnrollmentActive: Bool,
        userText: String,
        availableToolNames: [String],
        proactiveAllowedTools: Set<String>?,
        isConversationContinuation: Bool = false
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

        // In a conversation continuation (within 45s of last assistant message),
        // show all tools unless this is a proactive task with a specific allowlist.
        // Keyword-based narrowing is unreliable for continuation turns where the
        // user is responding to a previous prompt (e.g. providing an API key that
        // was requested by input_request — the text "api key" would incorrectly
        // narrow visible tools to just input_request).
        if isConversationContinuation && proactiveAllowedTools == nil {
            return nil
        }

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

    /// Common English words that happen to be tool names but should NOT
    /// suppress memory recall when used in natural speech.
    private static let ambiguousToolNames: Set<String> = [
        "read", "edit", "write", "notes", "mail", "scroll", "camera",
    ]

    static func explicitlyMentionedToolNames(
        in userText: String,
        availableToolNames: [String]
    ) -> Set<String> {
        let normalized = " " + userText.lowercased() + " "
        var matches: Set<String> = []

        for toolName in availableToolNames {
            if ambiguousToolNames.contains(toolName) { continue }

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

        if lower.count > 200 { return [] }

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
        ]) || ToolRoutingHelpers.isToolBackedLookupRequest(userText) {
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

        let isCloseOrQuitRequest = containsAny([
            "close ", "quit ", "hide ", "dismiss ", "shut ", "kill ",
            "stop the ", "close the ", "quit the ", "hide the ",
        ])

        if containsAny([
            "calendar", "schedule", "meeting", "appointment", "tomorrow",
            "free time", "availability", "busy"
        ]) || (containsAny(["today"]) && containsAny(["what", "show", "list", "check", "any"])) {
            if isCloseOrQuitRequest {
                add("bash", "window_control")
            } else {
                add("calendar")
            }
        }

        if containsAny(["remind me", "reminder", "todo", "to-do", "task list", "tasks"]) {
            if isCloseOrQuitRequest { add("bash", "window_control") } else { add("reminders") }
        }

        if containsAny(["contact", "phone number", "email address"]) {
            if isCloseOrQuitRequest { add("bash", "window_control") } else { add("contacts") }
        }

        if containsAny(["send email", "draft email", "compose email", "mail "]) {
            if isCloseOrQuitRequest { add("bash", "window_control") } else { add("mail", "contacts") }
        }

        if containsAny(["note", "notes", "jot down"]) {
            if isCloseOrQuitRequest { add("bash", "window_control") } else { add("notes") }
        }

        if containsAny([
            "paste", "type it", "type that", "type in", "let me type",
            "text input", "input field", "text box", "window to paste",
            "window to type", "give me a field", "need to type", "need to paste",
            "i'll paste", "ill paste", "i will paste", "i'll type", "ill type",
            "pop a window", "pop up a window", "pop up window", "popup a window", "popup window",
            "pop up a field", "popup a field", "open a window to",
            "give you a link", "give you some", "give you the",
            "here's a link", "here is a link", "heres a link",
            "here's some", "here is some", "heres some",
            "i have the info", "i have some info", "i have the data",
            "i have some data", "let me give", "i'll send", "ill send",
            "i will send", "share a link", "share some",
            "url", "urls", "api key", "password", "token", "credential",
            "link for you", "data for you", "info for you",
        ]) {
            add("input_request")
        }

        if containsAny([
            "screen", "what's on my screen", "what is on my screen", "what's on screen",
            "on my display", "on the screen", "ui", "button",
            "click ", "scroll", "find element", "screenshot"
        ]) {
            add("screenshot", "read_screen", "click", "type_text", "scroll", "find_element")
        }

        if containsAny([
            "camera", "photo", "take a picture", "webcam",
            "what can you see", "what do you see", "can you see me",
            "look at me", "look at this", "look around", "look at the room",
            "in the room", "in front of you", "in front of me",
            "see my face", "see me", "who's there", "who is there",
            "what's around", "what is around", "show you something",
        ]) {
            add("camera")
        }

        if containsAny([
            "skill", "activate skill", "run skill", "manage skill",
            "discord", "whatsapp", "imessage", "slack", "channel",
            "set up", "setup", "connect to", "integration", "configure",
        ]) {
            add("activate_skill", "run_skill", "manage_skill", "channel_setup",
                "bash", "read", "write", "edit", "self_config", "input_request")
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
        let lower = userText.lowercased()
        let memoryIntentPhrases = [
            "memory", "what do you know", "what you know", "tell me about me",
            "remember about me", "know about me", "what have you learned",
        ]
        if memoryIntentPhrases.contains(where: { lower.contains($0) }) {
            return false
        }

        if isEphemeralArithmeticQuery(userText) {
            return true
        }

        if !explicitlyMentionedToolNames(in: userText, availableToolNames: availableToolNames).isEmpty {
            return true
        }

        if ToolRoutingHelpers.isToolBackedLookupRequest(userText) {
            return true
        }

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

    // MARK: - Deterministic Easy Turns

    private static let arithmeticNumberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred",
    ]

    static func isEphemeralArithmeticQuery(_ text: String) -> Bool {
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

    static func normalizeEasyTurnInput(_ text: String) -> String {
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

    static func deterministicArithmeticReply(for text: String) -> String? {
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

    static func parseArithmeticExpression(_ text: String) -> (lhs: Double, operatorSymbol: String, rhs: Double)? {
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

    static func parseArithmeticOperand(_ text: String) -> Double? {
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

    static func standaloneUserNameDeclaration(in text: String) -> String? {
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

    static func isLikelyStandaloneHumanName(_ candidate: String) -> Bool {
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

    static func isSimpleUserNameRecallQuery(_ text: String) -> Bool {
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

    // MARK: - TTS Batching

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

    // MARK: - Voice Approval

    static func shouldAcceptVoiceApprovalResponse(
        awaitingApproval: Bool,
        manualOnlyApprovalPending: Bool,
        assistantSpeaking: Bool
    ) -> Bool {
        guard awaitingApproval else { return false }
        guard !manualOnlyApprovalPending else { return false }
        return !assistantSpeaking
    }

    // MARK: - Tool Aliases

    static func toolNameAliases(_ toolName: String) -> [String] {
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

    // MARK: - Failure Messages

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
}
