import Foundation

/// Keyword-based intent classifier for routing user queries.
///
/// Determines whether a voice query needs tools (background agent),
/// deeper reasoning, or can be handled by the voice LLM directly.
///
/// Replaces: `src/intent.rs` + classify_intent_with_context from `src/agent/mod.rs`
struct IntentClassifier {

    struct Intent {
        var needsTools: Bool = false
        var needsThinking: Bool = false
        var toolAllowlist: [String] = []
        var taskDescription: String = ""
    }

    // MARK: - Keyword Arrays

    static let webKeywords = [
        "search", "look up", "latest", "news", "web", "internet",
        "online", "website", "article",
    ]

    static let calendarKeywords = [
        "calendar", "meeting", "event", "schedule on my calendar",
        "what's on my schedule", "when is my", "book a meeting", "block time",
    ]

    static let remindersKeywords = [
        "reminder", "reminders", "todo", "to-do", "remind me",
        "set a reminder", "add a reminder", "don't forget",
    ]

    static let notesKeywords = [
        "my notes", "in notes", "apple notes", "create a note",
        "save a note", "notes app",
    ]

    static let mailKeywords = ["mail", "email", "inbox"]

    static let contactsKeywords = [
        "contact", "contacts", "phone number", "address book",
    ]

    static let schedulerKeywords = [
        "scheduled task", "remind me every", "every day", "recurring",
        "run every", "morning briefing", "daily briefing", "briefing",
        "each morning", "every morning", "every evening", "every night",
        "every week", "every month", "every hour", "schedule a",
        "create a schedule", "set up a schedule", "add a schedule",
        "daily check", "weekly check", "periodic", "at noon",
        "at midnight", "every monday", "every friday",
        "check in every", "update me every", "notify me every",
        "alert me every", "tell me every", "remind daily",
        "each day", "each week", "each month",
    ]

    static let bashKeywords = [
        "what time", "current time", "the time", "what date",
        "current date", "the date", "today's date", "what day",
        "disk space", "disk usage", "how much space", "storage",
        "system info", "uptime", "memory usage", "cpu usage",
        "battery", "ip address", "run a command", "run command",
        "run the command", "execute", "check the weather",
        "what's the weather",
    ]

    static let fileKeywords = [
        "read file", "open file", "show file", "in this file",
        "in this repo", "in this project",
    ]

    static let desktopKeywords = [
        "screenshot", "take a screenshot", "click on", "type into",
        "list windows", "focus window", "launch app",
    ]

    static let canvasKeywords = [
        "draw", "chart", "graph", "diagram", "visualize", "render a",
    ]

    static let deeperReasoningKeywords = [
        "explain", "analyze", "analyse", "compare", "contrast",
        "pros and cons", "think about", "think through", "reason about",
        "help me understand", "break down", "walk me through",
        "step by step", "why does", "why would", "why is it",
        "how does", "how would", "what if", "what would happen",
        "implications of", "difference between", "summarize",
        "evaluate", "critique", "should i", "plan for",
        "strategy for", "design a", "architect",
    ]

    static let briefReasoningKeywords = [
        "what time", "current time", "the time", "what date",
        "current date", "today's date", "what day", "uptime",
        "disk space", "disk usage", "storage", "memory usage",
        "cpu usage", "battery", "ip address",
    ]

    static let confirmationKeywords = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay",
        "go ahead", "please do", "do it", "sounds good",
        "alright", "of course", "absolutely", "definitely",
        "please", "go for it", "make it so", "proceed",
        "confirm", "perfect", "great",
    ]

    // MARK: - Classification

    /// Classify a user utterance to determine routing.
    static func classify(_ text: String, lastAssistantText: String? = nil) -> Intent {
        let lower = text.lowercased()
        var intent = Intent()

        // Check for tool-needing keywords.
        var tools: [String] = []

        if containsAny(lower, terms: bashKeywords) {
            tools.append("bash")
        }
        if containsAny(lower, terms: webKeywords) {
            tools.append(contentsOf: ["web_search", "fetch_url"])
        }
        if containsAny(lower, terms: calendarKeywords) {
            tools.append("calendar")
        }
        if containsAny(lower, terms: remindersKeywords) {
            tools.append("reminders")
        }
        if containsAny(lower, terms: notesKeywords) {
            tools.append("notes")
        }
        if containsAny(lower, terms: mailKeywords) {
            tools.append("mail")
        }
        if containsAny(lower, terms: contactsKeywords) {
            tools.append("contacts")
        }
        if containsAny(lower, terms: schedulerKeywords) {
            tools.append(contentsOf: ["scheduler_list", "scheduler_create",
                                       "scheduler_update", "scheduler_delete",
                                       "scheduler_trigger"])
        }
        if containsAny(lower, terms: fileKeywords) {
            tools.append("read")
        }
        if containsAny(lower, terms: desktopKeywords) {
            tools.append("desktop")
        }
        if containsAny(lower, terms: canvasKeywords) {
            tools.append(contentsOf: ["canvas_render", "canvas_interact", "canvas_export"])
        }

        if !tools.isEmpty {
            intent.needsTools = true
            intent.toolAllowlist = tools
            intent.taskDescription = text
        }

        // Check for deeper reasoning (only if no tools needed).
        if !intent.needsTools {
            if containsAny(lower, terms: deeperReasoningKeywords)
                && !containsAny(lower, terms: briefReasoningKeywords)
            {
                intent.needsThinking = true
            }
        }

        return intent
    }

    /// Check if text is a confirmation/approval response.
    static func isConfirmation(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return containsAny(lower, terms: confirmationKeywords)
    }

    // MARK: - Private

    private static func containsAny(_ haystack: String, terms: [String]) -> Bool {
        terms.contains { haystack.contains($0) }
    }
}
