import AppKit
import CryptoKit
import Foundation

/// Pure static helper functions for tool call routing, repair, intent detection,
/// and response processing. Extracted from PipelineCoordinator to reduce its line count.
///
/// All functions are stateless — they take explicit parameters and return values
/// without accessing any coordinator state.
enum ToolRoutingHelpers {

    // MARK: - Acknowledgements

    static func toolCallAcknowledgement(for calls: [ToolCall]) -> String {
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
            return "One moment, I'm pulling that up."
        case "read", "write", "edit", "bash":
            return "Got it, working on that now."
        default:
            return "Let me check that for you."
        }
    }

    // MARK: - Markup Stripping

    /// Strip `<voice character="...">...</voice>` tags, keeping inner text.
    static func stripVoiceTagMarkup(_ text: String) -> String {
        var result = text
        // Remove closing tags first (simpler).
        result = result.replacingOccurrences(of: "</voice>", with: "")
        // Remove opening tags: <voice character="...">, <voice character='...'>,
        // or a bare <voice> the model may emit without attributes.
        if let regex = try? NSRegularExpression(pattern: #"<voice(\s+[^>]*)?>"#) {
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
    static func stripThinkContent(_ text: String) -> String {
        guard let endRange = text.range(of: "</think>") else { return text }
        return String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Deferred Tool Logic

    /// Tool names eligible for non-blocking background execution.
    static let deferredToolAllowlist: Set<String> = [
        "calendar", "reminders", "contacts", "mail", "notes",
        "session_search", "web_search", "fetch_url", "read", "scheduler_list",
    ]

    static let inlineGroundedToolAllowlist: Set<String> = [
        "calendar", "reminders", "contacts", "mail", "notes",
        "screenshot", "camera",
    ]

    /// Returns true when every tool call is read-only and safe to defer.
    static func canRunDeferredToolCalls(
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
    static func isReadOnlyDeferredAction(_ call: ToolCall) -> Bool {
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

    // MARK: - Intent Detection

    /// Heuristic: explicit visual requests where the assistant should run webcam capture.
    /// Detects when the LLM's response implies it intended to use a tool but didn't.
    /// Common failure mode with smaller local models: they describe the action
    /// ("Let me check your settings") instead of emitting a tool call.
    static func responseImpliesToolIntent(_ response: String) -> Bool {
        let lower = stripThinkContent(response)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Short responses are more likely to be tool-intent preamble that got cut off.
        // Long responses are usually substantive answers.
        guard lower.count < 400 else { return false }

        let toolIntentPhrases = [
            "let me check", "let me look", "let me search", "let me find",
            "let me see", "let me pull up", "let me get", "let me fetch",
            "let me verify", "let me review", "let me examine",
            "i'll check", "i'll look", "i'll search", "i'll find",
            "i'll pull up", "i'll get", "i'll fetch", "i'll verify",
            "i'll review", "i'll examine", "i'll run",
            "let me run", "let me use", "i'll use",
            "checking that now", "looking that up", "searching for",
            "let me look through", "let me look into",
        ]

        return toolIntentPhrases.contains { lower.contains($0) }
    }

    static func isCameraIntentRequest(_ text: String) -> Bool {
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
    static func isScreenIntentRequest(_ text: String) -> Bool {
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

    static func screenRepairToolCall(for text: String) -> ToolCall {
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

    static func extractReferencedAppName(from text: String) -> String? {
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
    static func isToolBackedLookupRequest(_ text: String) -> Bool {
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

    // MARK: - Tool Call Repair

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

        // Close/quit/hide app requests -> window_control close_app.
        if let closeAppCall = repairedCloseAppCall(lowercased: lower) {
            return closeAppCall
        }

        if let calendarCall = repairedCalendarLookupCall(from: text, lowercased: lower) {
            return calendarCall
        }

        if let remindersCall = repairedRemindersLookupCall(from: text, lowercased: lower) {
            return remindersCall
        }

        if let contactsCall = repairedContactsLookupCall(from: text, lowercased: lower) {
            return contactsCall
        }

        if let mailCall = repairedMailLookupCall(lowercased: lower) {
            return mailCall
        }

        if let notesCall = repairedNotesLookupCall(from: text, lowercased: lower) {
            return notesCall
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
            || lower.contains("pop up a window")
            || lower.contains("popup a window")
            || lower.contains("pop up window")
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

    // MARK: - Preflight / Suppression

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

    // MARK: - Extraction Helpers

    static func extractSingleQuotedSegments(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "'([^']*)'") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let segmentRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[segmentRange])
        }
    }

    static func extractReplacementPair(
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

    static func extractPathCandidate(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:(?:~|/)[^\s'",]+)"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let candidateRange = Range(match.range(at: 0), in: text)
        else { return nil }
        return String(text[candidateRange])
    }

    static func extractURLCandidate(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s'"]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let candidateRange = Range(match.range(at: 0), in: text)
        else { return nil }
        return String(text[candidateRange])
    }

    static func extractSearchQuery(from text: String) -> String? {
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

    static func normalizeSearchRepairQuery(_ raw: String) -> String {
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

    // MARK: - Domain-Specific Repair

    static func repairedCalendarLookupCall(from text: String, lowercased lower: String) -> ToolCall? {
        let calendarIntent = [
            "calendar", "diary", "schedule", "event", "events",
            "meeting", "meetings", "appointment", "appointments",
        ].contains { containsWholeWord($0, in: lower) }
        guard calendarIntent else { return nil }

        // Don't force a calendar lookup when the user wants to close/quit/hide it.
        let closeWords = ["close", "quit", "hide", "dismiss", "shut", "kill", "stop"]
        if closeWords.contains(where: { lower.contains($0) }) {
            return nil
        }

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

    static func repairedRemindersLookupCall(from text: String, lowercased lower: String) -> ToolCall? {
        let remindersIntent = [
            "reminder", "reminders", "to-do", "todo", "task list",
        ].contains { containsWholeWord($0, in: lower) }
        guard remindersIntent else { return nil }

        // Don't force a reminders lookup when the user wants to close/quit/hide it.
        let closeWords = ["close", "quit", "hide", "dismiss", "shut", "kill", "stop"]
        if closeWords.contains(where: { lower.contains($0) }) {
            return nil
        }

        if lower.contains("search") || lower.contains("find ") || lower.contains("look for ") {
            let query = extractCalendarSearchQuery(from: text, lowercased: lower) ?? ""
            if !query.isEmpty {
                return ToolCall(name: "reminders", arguments: ["action": "search", "query": query])
            }
        }

        return ToolCall(name: "reminders", arguments: ["action": "list_incomplete"])
    }

    /// Detect "close the calendar" / "quit reminders" etc. and return a window_control close_app call.
    static func repairedCloseAppCall(lowercased lower: String) -> ToolCall? {
        let closeVerbs = ["close", "quit", "hide", "dismiss"]
        guard closeVerbs.contains(where: { lower.contains($0) }) else { return nil }

        let appMap: [(keywords: [String], appName: String)] = [
            (["calendar", "ical"], "Calendar"),
            (["reminder"], "Reminders"),
            (["contact", "address book"], "Contacts"),
            (["mail", "email app"], "Mail"),
            (["note"], "Notes"),
            (["safari", "browser"], "Safari"),
            (["finder"], "Finder"),
            (["music", "itunes"], "Music"),
        ]
        for entry in appMap {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                return ToolCall(name: "window_control", arguments: ["action": "close_app", "app_name": entry.appName])
            }
        }
        return nil
    }

    static func repairedContactsLookupCall(from text: String, lowercased lower: String) -> ToolCall? {
        let contactsIntent = [
            "contact", "contacts", "phone number", "email address",
        ].contains { containsWholeWord($0, in: lower) }
        guard contactsIntent else { return nil }

        let query = extractCalendarSearchQuery(from: text, lowercased: lower) ?? ""
        guard !query.isEmpty else { return nil }

        if lower.contains("phone") || lower.contains("number") {
            return ToolCall(name: "contacts", arguments: ["action": "get_phone", "query": query])
        }
        if lower.contains("email") {
            return ToolCall(name: "contacts", arguments: ["action": "get_email", "query": query])
        }
        return ToolCall(name: "contacts", arguments: ["action": "search", "query": query])
    }

    static func repairedMailLookupCall(lowercased lower: String) -> ToolCall? {
        let mailIntent = [
            "mail", "email", "inbox",
        ].contains { containsWholeWord($0, in: lower) }
        guard mailIntent else { return nil }
        return ToolCall(name: "mail", arguments: ["action": "check_inbox"])
    }

    static func repairedNotesLookupCall(from text: String, lowercased lower: String) -> ToolCall? {
        // "notes" is ambiguous — only match when paired with a lookup verb.
        let notesIntent = containsWholeWord("notes", in: lower)
        let lookupVerb = ["check", "show", "list", "find", "search", "read"].contains { lower.contains($0) }
        guard notesIntent && lookupVerb else { return nil }

        if lower.contains("search") || lower.contains("find ") {
            let query = extractCalendarSearchQuery(from: text, lowercased: lower) ?? ""
            if !query.isEmpty {
                return ToolCall(name: "notes", arguments: ["action": "search", "query": query])
            }
        }

        return ToolCall(name: "notes", arguments: ["action": "list_recent"])
    }

    static func extractISODateCandidate(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let candidateRange = Range(match.range(at: 0), in: text)
        else {
            return nil
        }
        return String(text[candidateRange])
    }

    static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let regex = try? NSRegularExpression(pattern: #"\b\#(escaped)\b"#) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    static func extractCalendarSearchQuery(from text: String, lowercased lower: String) -> String? {
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

    static func extractCommandCandidate(from text: String) -> String? {
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

    static func extractNamedEntity(from text: String, markers: [String]) -> String? {
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

    static func extractIntervalSchedule(from lower: String) -> [String: String]? {
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

    static func extractSkillName(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in ["activate the ", "load the ", "activate "] {
            guard let range = lower.range(of: marker) else { continue }
            let remainder = text[range.upperBound...]
            if let skillRange = remainder.range(of: "skill", options: .caseInsensitive) {
                let name = remainder[..<skillRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if ToolExecutor.isSafeSkillName(name) {
                    return name
                }
            }
        }
        return nil
    }

    static func extractExecutableSkillName(from text: String) -> String? {
        let lower = text.lowercased()
        for marker in ["run the ", "run ", "execute "] {
            guard let range = lower.range(of: marker) else { continue }
            let remainder = text[range.upperBound...]
            let stop = [" skill", ".", ",", "\n"].compactMap { remainder.range(of: $0, options: .caseInsensitive)?.lowerBound }.min() ?? remainder.endIndex
            let candidate = remainder[..<stop].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if ToolExecutor.isSafeSkillName(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func extractElementIndex(from lower: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"element\s+(\d+)"#),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
              let range = Range(match.range(at: 1), in: lower)
        else {
            return nil
        }
        return Int(lower[range])
    }

    static func extractTypeText(from text: String) -> String? {
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

    static func estimateTokenCount(for text: String) -> Int {
        Int(Double(text.count) / 3.5)
    }

    // MARK: - Tool Result Processing

    static func directToolReplyText(for call: ToolCall, result: ToolResult) -> String? {
        guard !result.isError else { return nil }

        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch call.name {
        // bash output is never spoken directly — always routed back to the LLM
        // for interpretation so the user gets a natural-language response
        // instead of raw command output like "HTTP/2 301".

        // Apple tools: direct reply with conversational formatting.
        // LLM interpretation causes hallucination on all models (4B/9B/35B)
        // because tool results aren't reliably visible in the follow-up context.
        // Instead, format the raw data as natural speech directly.
        case "calendar", "reminders", "contacts", "mail", "notes":
            return trimmed

        // Vision tools (camera, screenshot) must NOT use direct reply.
        // Their output is a raw VLM description that should flow back to
        // the LLM for interpretation — the model decides whether to greet
        // the user, comment on screen content, or stay silent.
        // Direct reply would speak "The man is sitting in a chair" verbatim.

        default:
            return nil
        }
    }

    static func serializeArguments(_ args: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return "{}"
    }


    /// Extract an audio file path from skill output JSON (looks for "audio_file" key).
    static func extractAudioFilePath(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["audio_file"] as? String,
              path.hasSuffix(".wav")
        else { return nil }
        return path
    }

    static func inferUserPresentFromCameraOutput(_ output: String) -> Bool {
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

    static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Session Search

    static func extractSessionSearchQuery(from text: String) -> String? {
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
            let cleaned = suffix
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }
}
