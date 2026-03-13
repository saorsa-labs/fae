import Foundation

struct FreeformEvalCase {
    let id: String
    let category: String
    let prompt: String
    let maxTokens: Int
    let checks: [FreeformCheck]
}

enum FreeformCheck {
    case exact(String)
    case containsAll([String])
    case containsAny([String])
    case forbidsAny([String])
    case requiresQuestion
    case minWords(Int)
    case maxWords(Int)
}

struct FreeformEvalResult: Codable {
    let caseID: String
    let category: String
    let prompt: String
    let rawOutput: String
    let failedChecks: [String]
    let passedChecks: Int
    let totalChecks: Int
    let wordCount: Int
    let correct: Bool
    let firstTokenLatencyMS: Double
    let wallTimeS: Double

    enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case category
        case prompt
        case rawOutput = "raw_output"
        case failedChecks = "failed_checks"
        case passedChecks = "passed_checks"
        case totalChecks = "total_checks"
        case wordCount = "word_count"
        case correct
        case firstTokenLatencyMS = "first_token_latency_ms"
        case wallTimeS = "wall_time_s"
    }
}

let freeformEvalCategoryOrder = [
    "exact_reply",
    "exact_format",
    "clarify_before_action",
    "tool_result_calendar",
    "tool_result_document",
    "permission_response",
    "memory_discipline",
    "summarization_grounded",
    "supportive_reply",
    "rewrite_actionable",
]

let freeformEvalCategoryLabels: [String: String] = [
    "exact_reply": "Exact reply",
    "exact_format": "Exact format",
    "clarify_before_action": "Clarify",
    "tool_result_calendar": "Calendar",
    "tool_result_document": "Doc/web result",
    "permission_response": "Permission",
    "memory_discipline": "Memory",
    "summarization_grounded": "Summary",
    "supportive_reply": "Support",
    "rewrite_actionable": "Rewrite",
]

let freeformEvalSystemPrompt = """
/no_think
You are Fae, a helpful local assistant being evaluated.
Reply directly and naturally to the user prompt.
Follow explicit formatting instructions exactly.
If the prompt includes tool results or permission context, stay grounded to that context.
Do not mention this evaluation. Do not include analysis or reasoning.
"""

let qwenCalibratedFreeformEvalSystemPrompt = """
/no_think
You are Qwen running in freeform benchmark mode.
Return only the final user-facing reply.
Do not include analysis, reasoning, "Thinking Process", labels, or markdown fences unless the user explicitly asks for them.
Follow explicit formatting instructions exactly.
If the prompt includes tool results or permission context, stay grounded to that context and do not invent missing facts.
"""

func freeformPromptConfig(test: FreeformEvalCase, qwenCalibrated: Bool) -> EvalPromptConfig {
    EvalPromptConfig(
        system: qwenCalibrated ? qwenCalibratedFreeformEvalSystemPrompt : freeformEvalSystemPrompt,
        user: test.prompt,
        maxTokens: test.maxTokens
    )
}

private func cleanedFreeformOutput(_ text: String) -> String {
    var source = text
    if let thinkClose = source.range(of: "</think>", options: .backwards) {
        source = String(source[thinkClose.upperBound...])
    }
    return source
        .replacingOccurrences(of: "```", with: "")
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedFreeformSearchText(_ text: String) -> String {
    cleanedFreeformOutput(text)
        .lowercased()
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedExactText(_ text: String) -> String {
    cleanedFreeformOutput(text)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func freeformWordCount(_ text: String) -> Int {
    cleanedFreeformOutput(text)
        .split(whereSeparator: \.isWhitespace)
        .count
}

func evaluateFreeformOutput(_ output: String, checks: [FreeformCheck]) -> (correct: Bool, failures: [String], wordCount: Int) {
    let cleaned = cleanedFreeformOutput(output)
    let normalized = normalizedFreeformSearchText(output)
    let exact = normalizedExactText(output)
    let wordCount = freeformWordCount(output)

    var failures: [String] = []

    for check in checks {
        switch check {
        case .exact(let expected):
            if exact != normalizedExactText(expected) {
                failures.append("exact")
            }
        case .containsAll(let needles):
            let missing = needles.filter { !normalized.contains($0.lowercased()) }
            if !missing.isEmpty {
                failures.append("contains_all:\(missing.joined(separator: ","))")
            }
        case .containsAny(let needles):
            let found = needles.contains { normalized.contains($0.lowercased()) }
            if !found {
                failures.append("contains_any:\(needles.joined(separator: "|"))")
            }
        case .forbidsAny(let needles):
            let hits = needles.filter { normalized.contains($0.lowercased()) }
            if !hits.isEmpty {
                failures.append("forbids_any:\(hits.joined(separator: ","))")
            }
        case .requiresQuestion:
            if !cleaned.contains("?") {
                failures.append("question")
            }
        case .minWords(let count):
            if wordCount < count {
                failures.append("min_words:\(count)")
            }
        case .maxWords(let count):
            if wordCount > count {
                failures.append("max_words:\(count)")
            }
        }
    }

    return (failures.isEmpty, failures, wordCount)
}

private struct ExactFormatSeed {
    let prompt: String
    let expected: String
}

private struct ClarifySeed {
    let prompt: String
    let hints: [String]
}

private struct ToolResultSeed {
    let prompt: String
    let required: [String]
    let forbidden: [String]
}

private struct MemorySeed {
    let prompt: String
    let expected: String
}

private struct SummarySeed {
    let prompt: String
    let required: [String]
    let forbidden: [String]
}

private struct SupportSeed {
    let prompt: String
    let requiredAny: [String]
    let forbidden: [String]
    let needsQuestion: Bool
}

private struct RewriteSeed {
    let prompt: String
    let required: [String]
    let politeAny: [String]
}

private func buildFreeformEvalCases() -> [FreeformEvalCase] {
    var cases: [FreeformEvalCase] = []

    let exactReplyTargets = [
        "ok", "BLUE", "north,south", "Tuesday", "42",
        "quiet local helper", "alpha-beta", "Edinburgh", "done", "YES",
        "no", "fae", "1/2", "A1", "green",
        "Inverness", "coffee", "status:ok", "north south east", "ready",
        "single-line", "3.14", "apple,pear", "Monday", "HELLO",
    ]

    for (index, target) in exactReplyTargets.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "exact-reply-%03d", index + 1),
                category: "exact_reply",
                prompt: "Reply with exactly: \(target)",
                maxTokens: 24,
                checks: [.exact(target)]
            )
        )
    }

    let exactFormatSeeds: [ExactFormatSeed] = [
        .init(prompt: "Reply with exactly two bullet points: apples and pears.", expected: "- apples\n- pears"),
        .init(prompt: "Reply with exactly one sentence: Local models are fast.", expected: "Local models are fast."),
        .init(prompt: "Reply with exactly three comma-separated words: north,south,east", expected: "north,south,east"),
        .init(prompt: "Reply with exactly one line: Edinburgh | Glasgow", expected: "Edinburgh | Glasgow"),
        .init(prompt: "Reply with exactly two lines: first then second.", expected: "first\nsecond"),
        .init(prompt: "Reply with exactly: [ok]", expected: "[ok]"),
        .init(prompt: "Reply with exactly the lowercase text: fae is ready", expected: "fae is ready"),
        .init(prompt: "Reply with exactly two bullet points: tea and coffee.", expected: "- tea\n- coffee"),
        .init(prompt: "Reply with exactly one sentence: The build passed.", expected: "The build passed."),
        .init(prompt: "Reply with exactly two comma-separated words: read,write", expected: "read,write"),
        .init(prompt: "Reply with exactly one line: owner=ash", expected: "owner=ash"),
        .init(prompt: "Reply with exactly two lines: calm then focus.", expected: "calm\nfocus"),
        .init(prompt: "Reply with exactly the uppercase word: READY", expected: "READY"),
        .init(prompt: "Reply with exactly one sentence: Permissions are required.", expected: "Permissions are required."),
        .init(prompt: "Reply with exactly two bullet points: local first and private by default.", expected: "- local first\n- private by default"),
        .init(prompt: "Reply with exactly: user@example.com", expected: "user@example.com"),
        .init(prompt: "Reply with exactly one line: 09:00 design review", expected: "09:00 design review"),
        .init(prompt: "Reply with exactly three comma-separated words: calm,clear,kind", expected: "calm,clear,kind"),
        .init(prompt: "Reply with exactly one sentence: I can help with that.", expected: "I can help with that."),
        .init(prompt: "Reply with exactly two lines: hello then goodbye.", expected: "hello\ngoodbye"),
        .init(prompt: "Reply with exactly: {done}", expected: "{done}"),
        .init(prompt: "Reply with exactly the word: maybe", expected: "maybe"),
        .init(prompt: "Reply with exactly two bullet points: browse web and summarise results.", expected: "- browse web\n- summarise results"),
        .init(prompt: "Reply with exactly one line: context=8192", expected: "context=8192"),
        .init(prompt: "Reply with exactly one sentence: Voice is enabled.", expected: "Voice is enabled."),
    ]

    for (index, seed) in exactFormatSeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "exact-format-%03d", index + 1),
                category: "exact_format",
                prompt: seed.prompt,
                maxTokens: 48,
                checks: [.exact(seed.expected)]
            )
        )
    }

    let clarifySeeds: [ClarifySeed] = [
        .init(prompt: "User says: 'Schedule lunch with Sam next week.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what day", "which day", "what time", "when works"]),
        .init(prompt: "User says: 'Remind me to call Mum tomorrow afternoon.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what time", "which time", "tomorrow afternoon"]),
        .init(prompt: "User says: 'Email Alex about the draft.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which alex", "what address", "which email"]),
        .init(prompt: "User says: 'Add dentist to my calendar on Friday.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what time", "which time"]),
        .init(prompt: "User says: 'Set a reminder for the report.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["when", "what time", "which day"]),
        .init(prompt: "User says: 'Write a file for today's notes.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["where", "what path", "which folder"]),
        .init(prompt: "User says: 'Read the contract and summarise it.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which file", "what path", "where is the contract"]),
        .init(prompt: "User says: 'Find Jordan in my contacts and send the update.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which jordan", "what contact", "what address"]),
        .init(prompt: "User says: 'Book travel for Glasgow next month.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which dates", "what dates", "when next month"]),
        .init(prompt: "User says: 'Create a note for the design meeting.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what should i include", "what title", "which details"]),
        .init(prompt: "User says: 'Move my 1:1 to later.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which 1:1", "what time", "how much later"]),
        .init(prompt: "User says: 'Search for the latest Apple news and email it to Pat.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which pat", "what address", "which email"]),
        .init(prompt: "User says: 'Delete the old note.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which note", "what title", "which old note"]),
        .init(prompt: "User says: 'Open the report and update it.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which report", "what path", "what should i update"]),
        .init(prompt: "User says: 'Send flowers reminder for Gran.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["when", "what time", "which day"]),
        .init(prompt: "User says: 'Email the invoice to Chris.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which chris", "what address", "which email"]),
        .init(prompt: "User says: 'Add a follow-up next Thursday.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what time", "which thursday", "follow-up for what"]),
        .init(prompt: "User says: 'Remind me about airport pickup.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["when", "what time", "which day"]),
        .init(prompt: "User says: 'Read my notes from yesterday.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which note", "what title", "which notes"]),
        .init(prompt: "User says: 'Create the document we discussed.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what should it include", "what title", "where should i save"]),
        .init(prompt: "User says: 'Text Jamie that I'm running late.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which jamie", "what contact", "how late"]),
        .init(prompt: "User says: 'Search my files for the tax PDF.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which year", "what filename", "where should i search"]),
        .init(prompt: "User says: 'Add coffee with Erin sometime this week.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what day", "which day", "what time"]),
        .init(prompt: "User says: 'Send the summary to marketing.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["who in marketing", "what address", "which contact"]),
        .init(prompt: "User says: 'Save this as a note.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what title", "what should i save", "which note title"]),
        .init(prompt: "User says: 'Plan a reminder for the school run.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what time", "which day", "when"]),
        .init(prompt: "User says: 'Update the todo file.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which file", "what path", "what should i change"]),
        .init(prompt: "User says: 'Find the right Alex and send a meeting note.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["which alex", "what contact", "what address"]),
        .init(prompt: "User says: 'Book a catch-up with Priya.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["what day", "what time", "when works"]),
        .init(prompt: "User says: 'Write the release checklist file.' Reply as Fae in one sentence. Ask the minimum necessary clarifying question before taking action.", hints: ["where", "what path", "which folder"]),
    ]

    for (index, seed) in clarifySeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "clarify-%03d", index + 1),
                category: "clarify_before_action",
                prompt: seed.prompt,
                maxTokens: 64,
                checks: [
                    .requiresQuestion,
                    .containsAny(seed.hints),
                    .forbidsAny(["done", "scheduled", "created", "sent", "wrote", "updated"]),
                    .maxWords(32),
                ]
            )
        )
    }

    let calendarSeeds: [ToolResultSeed] = [
        .init(prompt: "Calendar tool returned: 09:00 design review; 13:00 lunch with Sam; 16:30 dentist. The user asked: 'What's on my schedule tomorrow?' Reply in one sentence.", required: ["09:00", "design review", "13:00", "lunch with sam", "16:30", "dentist"], forbidden: []),
        .init(prompt: "Calendar tool returned: 08:30 train to Glasgow; 11:00 budget review. The user asked: 'What's on tomorrow morning?' Reply in one sentence.", required: ["08:30", "train to glasgow", "11:00", "budget review"], forbidden: []),
        .init(prompt: "Calendar tool returned: 14:00 1:1 with Ash; 15:30 code review. The user asked: 'Summarise my afternoon.' Reply in one sentence.", required: ["14:00", "1:1 with ash", "15:30", "code review"], forbidden: []),
        .init(prompt: "Calendar tool returned: 10:00 dentist; 18:00 family dinner. The user asked: 'What have I got on Friday?' Reply in one sentence.", required: ["10:00", "dentist", "18:00", "family dinner"], forbidden: []),
        .init(prompt: "Calendar tool returned: 07:45 school drop-off; 12:00 lunch with Erin; 19:00 choir. The user asked: 'Give me a quick daily summary.' Reply in one sentence.", required: ["07:45", "school drop-off", "12:00", "lunch with erin", "19:00", "choir"], forbidden: []),
        .init(prompt: "Calendar tool returned: 11:30 physio; 15:00 design sync. The user asked: 'What do I have after lunch?' Reply in one sentence.", required: ["15:00", "design sync"], forbidden: ["11:30 physio"]),
        .init(prompt: "Calendar tool returned: 09:15 stand-up; 09:45 roadmap review; 10:30 hiring call. The user asked: 'Summarise my first half of the morning.' Reply in one sentence.", required: ["09:15", "stand-up", "09:45", "roadmap review", "10:30", "hiring call"], forbidden: []),
        .init(prompt: "Calendar tool returned: 13:00 lunch with Pat; 14:00 write-up block. The user asked: 'What happens after noon?' Reply in one sentence.", required: ["13:00", "lunch with pat", "14:00", "write-up block"], forbidden: []),
        .init(prompt: "Calendar tool returned: 16:00 pickup at station. The user asked: 'Do I have anything late today?' Reply in one sentence.", required: ["16:00", "pickup at station"], forbidden: []),
        .init(prompt: "Calendar tool returned: no events found for tomorrow. The user asked: 'What's on tomorrow?' Reply in one sentence.", required: ["no events", "tomorrow"], forbidden: ["09:00", "meeting", "appointment"]),
        .init(prompt: "Calendar tool returned: 08:00 gym; 09:30 sprint planning; 17:30 groceries. The user asked: 'What's in my day?' Reply in one sentence.", required: ["08:00", "gym", "09:30", "sprint planning", "17:30", "groceries"], forbidden: []),
        .init(prompt: "Calendar tool returned: 12:30 lunch; 13:30 interview prep; 15:00 interview. The user asked: 'What does my afternoon look like?' Reply in one sentence.", required: ["12:30", "lunch", "13:30", "interview prep", "15:00", "interview"], forbidden: []),
        .init(prompt: "Calendar tool returned: 10:00 demo; 11:00 retro; 12:00 lunch. The user asked: 'What's before lunch?' Reply in one sentence.", required: ["10:00", "demo", "11:00", "retro"], forbidden: ["12:00 lunch"]),
        .init(prompt: "Calendar tool returned: 18:30 dinner with Iona. The user asked: 'Do I have plans tonight?' Reply in one sentence.", required: ["18:30", "dinner with iona"], forbidden: []),
        .init(prompt: "Calendar tool returned: 09:00 onboarding; 10:00 architecture review; 14:00 customer call. The user asked: 'Summarise the key appointments.' Reply in one sentence.", required: ["09:00", "onboarding", "10:00", "architecture review", "14:00", "customer call"], forbidden: []),
        .init(prompt: "Calendar tool returned: 08:00 school run; 09:00 stand-up; 17:00 school run. The user asked: 'What fixed commitments are in my day?' Reply in one sentence.", required: ["08:00", "school run", "09:00", "stand-up", "17:00", "school run"], forbidden: []),
        .init(prompt: "Calendar tool returned: 14:30 project review; 16:00 dentist; 18:30 dinner. The user asked: 'What have I got later?' Reply in one sentence.", required: ["14:30", "project review", "16:00", "dentist", "18:30", "dinner"], forbidden: []),
        .init(prompt: "Calendar tool returned: 09:00 focus block; 11:00 design sync; 13:00 lunch. The user asked: 'What meetings do I have?' Reply in one sentence.", required: ["11:00", "design sync"], forbidden: ["09:00 focus block"]),
        .init(prompt: "Calendar tool returned: 15:00 physio. The user asked: 'Any appointments this afternoon?' Reply in one sentence.", required: ["15:00", "physio"], forbidden: []),
        .init(prompt: "Calendar tool returned: 08:15 nursery drop-off; 12:00 lunch with Robin; 18:00 parents' evening. The user asked: 'Give me a short summary for today.' Reply in one sentence.", required: ["08:15", "nursery drop-off", "12:00", "lunch with robin", "18:00", "parents' evening"], forbidden: []),
        .init(prompt: "Calendar tool returned: 10:30 product review; 11:30 follow-up notes. The user asked: 'What is the main thing before noon?' Reply in one sentence.", required: ["10:30", "product review"], forbidden: ["11:30 follow-up notes"]),
        .init(prompt: "Calendar tool returned: 17:00 collect parcel; 19:30 concert. The user asked: 'What do I have this evening?' Reply in one sentence.", required: ["17:00", "collect parcel", "19:30", "concert"], forbidden: []),
        .init(prompt: "Calendar tool returned: 09:00 team sync; 09:30 customer prep; 10:00 customer call. The user asked: 'Summarise the customer-related items.' Reply in one sentence.", required: ["09:30", "customer prep", "10:00", "customer call"], forbidden: ["09:00 team sync"]),
        .init(prompt: "Calendar tool returned: 13:00 lunch with Pat; 16:00 school pickup. The user asked: 'What do I need to remember later today?' Reply in one sentence.", required: ["13:00", "lunch with pat", "16:00", "school pickup"], forbidden: []),
        .init(prompt: "Calendar tool returned: 11:00 GP appointment; 12:15 pharmacy pickup. The user asked: 'What health-related errands are on my calendar?' Reply in one sentence.", required: ["11:00", "gp appointment", "12:15", "pharmacy pickup"], forbidden: []),
    ]

    for (index, seed) in calendarSeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "calendar-result-%03d", index + 1),
                category: "tool_result_calendar",
                prompt: seed.prompt,
                maxTokens: 96,
                checks: [
                    .containsAll(seed.required),
                    .forbidsAny(seed.forbidden),
                    .maxWords(34),
                ]
            )
        )
    }

    let documentSeeds: [ToolResultSeed] = [
        .init(prompt: "Read tool returned this todo list: buy milk, send invoice, call vet. The user asked for a concise summary. Reply in one sentence.", required: ["buy milk", "send invoice", "call vet"], forbidden: []),
        .init(prompt: "Read tool returned meeting notes: launch moved to Tuesday, marketing needs final copy by Monday, design sign-off is pending. The user asked for a short summary. Reply in one sentence.", required: ["tuesday", "marketing", "monday", "design sign-off"], forbidden: []),
        .init(prompt: "Web search returned three recent Apple headlines: new MacBook launch, Apple Vision update, services revenue rises. The user asked for a quick summary. Reply in one sentence.", required: ["apple", "macbook", "vision", "services"], forbidden: []),
        .init(prompt: "Read tool returned release checklist items: run migration, update docs, capture screenshots, tag release. The user asked for a concise summary. Reply in one sentence.", required: ["migration", "docs", "screenshots", "tag release"], forbidden: []),
        .init(prompt: "Read tool returned the file contents: line 1 'owner=ash', line 2 'context=8192', line 3 'tool_mode=full'. The user asked what is configured. Reply in one sentence.", required: ["owner=ash", "context=8192", "tool_mode=full"], forbidden: []),
        .init(prompt: "Contacts tool returned no match for Alex. The user asked: 'Can you email Alex for me?' Reply in one sentence.", required: ["couldn't find", "alex"], forbidden: ["alex@example.com"]),
        .init(prompt: "Web search returned: Glasgow rail strike planned Monday, service reductions expected, travellers advised to check operators. The user asked for the key point. Reply in one sentence.", required: ["glasgow", "rail strike", "monday", "check"], forbidden: []),
        .init(prompt: "Read tool returned a draft email: 'Thanks for the update. I'll review the proposal by Thursday.' The user asked for a summary. Reply in one sentence.", required: ["review", "proposal", "thursday"], forbidden: []),
        .init(prompt: "Read tool returned a grocery note: bread, tomatoes, basil, olive oil. The user asked for a quick summary. Reply in one sentence.", required: ["bread", "tomatoes", "basil", "olive oil"], forbidden: []),
        .init(prompt: "Web search returned: local weather warning for high winds, travel disruption possible, avoid unnecessary coastal trips. The user asked for a short summary. Reply in one sentence.", required: ["high winds", "travel disruption", "coastal"], forbidden: []),
        .init(prompt: "Read tool returned a bug list: startup freeze on cold boot, missing permission overlay on write, flaky voice wake after playback. The user asked for the main issues. Reply in one sentence.", required: ["startup freeze", "permission overlay", "voice wake"], forbidden: []),
        .init(prompt: "Read tool returned project status: benchmark rerun complete, live eval blocked by startup readiness, docs updated. The user asked for a concise update. Reply in one sentence.", required: ["benchmark rerun", "startup readiness", "docs updated"], forbidden: []),
        .init(prompt: "Web search returned headlines: UK budget announced, markets mixed, energy support extended. The user asked for a one-sentence summary. Reply in one sentence.", required: ["uk budget", "markets", "energy support"], forbidden: []),
        .init(prompt: "Read tool returned travel checklist: passport, chargers, medicine, printed tickets. The user asked for a short recap. Reply in one sentence.", required: ["passport", "chargers", "medicine", "tickets"], forbidden: []),
        .init(prompt: "Contacts tool returned one match: Priya Shah, priya@example.com. The user asked for Priya's email. Reply in one sentence.", required: ["priya@example.com"], forbidden: []),
        .init(prompt: "Read tool returned sprint goals: stabilise voice path, tighten tool repair, add freeform evals. The user asked for the priorities. Reply in one sentence.", required: ["voice path", "tool repair", "freeform evals"], forbidden: []),
        .init(prompt: "Web search returned: Apple supplier delays may affect autumn launch, analysts expect cautious guidance. The user asked for the gist. Reply in one sentence.", required: ["apple", "delays", "autumn launch", "guidance"], forbidden: []),
        .init(prompt: "Read tool returned book notes: chapter one covers memory systems, chapter two covers retrieval, chapter three covers evaluation. The user asked for a concise summary. Reply in one sentence.", required: ["memory systems", "retrieval", "evaluation"], forbidden: []),
        .init(prompt: "Read tool returned: 'Remember to call the GP, pay council tax, and send the school form.' The user asked for a quick summary. Reply in one sentence.", required: ["call the gp", "pay council tax", "school form"], forbidden: []),
        .init(prompt: "Web search returned: severe rain warning for Edinburgh, commuter disruption likely, schools monitoring closures. The user asked for the key points. Reply in one sentence.", required: ["edinburgh", "rain warning", "commuter disruption", "schools"], forbidden: []),
        .init(prompt: "Read tool returned this changelog: switched to single-model Qwen, added on-demand VLM, updated RAM auto-selection. The user asked what changed. Reply in one sentence.", required: ["single-model qwen", "on-demand vlm", "ram auto-selection"], forbidden: []),
        .init(prompt: "Read tool returned a support ticket: user hears audio cue but Fae does not answer, likely voice gating issue after playback. The user asked for the problem. Reply in one sentence.", required: ["audio cue", "does not answer", "voice gating"], forbidden: []),
        .init(prompt: "Web search returned: local airport security delays, passengers advised to arrive early, morning flights worst affected. The user asked for a short summary. Reply in one sentence.", required: ["security delays", "arrive early", "morning flights"], forbidden: []),
        .init(prompt: "Read tool returned note contents: dentist at 10, pick up parcel at 5, buy printer ink. The user asked for a concise summary. Reply in one sentence.", required: ["dentist", "10", "parcel", "5", "printer ink"], forbidden: []),
        .init(prompt: "Read tool returned deployment notes: cache repaired, model switched in-app, approval overlays fixed. The user asked for the headline update. Reply in one sentence.", required: ["cache repaired", "switched in-app", "approval overlays fixed"], forbidden: []),
    ]

    for (index, seed) in documentSeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "document-result-%03d", index + 1),
                category: "tool_result_document",
                prompt: seed.prompt,
                maxTokens: 96,
                checks: [
                    .containsAll(seed.required),
                    .forbidsAny(seed.forbidden),
                    .maxWords(38),
                ]
            )
        )
    }

    let permissionTools = [
        "calendar", "reminders", "contacts", "mail", "notes",
        "read", "write", "camera", "microphone", "screen recording",
        "photos", "downloads", "desktop", "automation", "accessibility",
        "full disk access", "browser", "location", "calendar write", "reminders write",
    ]

    for (index, toolName) in permissionTools.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "permission-%03d", index + 1),
                category: "permission_response",
                prompt: "The \(toolName) action failed because permission is denied. Reply naturally in one or two sentences, explain the block clearly, and suggest the next step.",
                maxTokens: 72,
                checks: [
                    .containsAny([toolName, "permission", "access"]),
                    .containsAny(["grant", "allow", "enable", "once access", "after access"]),
                    .containsAny(["different approach", "another way", "once you", "after you"]),
                    .forbidsAny(["completed successfully", "done", "already sent", "already wrote"]),
                    .maxWords(42),
                ]
            )
        )
    }

    let memorySeeds: [MemorySeed] = [
        .init(prompt: "Conversation: User says, 'My birthday is on April 12.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: birthday = April 12"),
        .init(prompt: "Conversation: User says, 'Please call me Ash from now on.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: preferred name = Ash"),
        .init(prompt: "Conversation: User says, 'I'm allergic to peanuts.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: allergy = peanuts"),
        .init(prompt: "Conversation: User says, 'I'm vegan.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: dietary preference = vegan"),
        .init(prompt: "Conversation: Memory already says favorite drink = tea. User now says, 'Actually coffee is my favorite drink.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: favorite drink = coffee (supersedes tea)"),
        .init(prompt: "Conversation: User says, 'I moved to Inverness last month.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: city = Inverness"),
        .init(prompt: "Conversation: User says, 'My pronouns are they/them.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: pronouns = they/them"),
        .init(prompt: "Conversation: User says, 'My dog is called Moss.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: dog = Moss"),
        .init(prompt: "Conversation: User says, 'I work night shifts on Tuesdays.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: Tuesday schedule = night shift"),
        .init(prompt: "Conversation: User says, 'I prefer train travel when possible.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: travel preference = train"),
        .init(prompt: "Conversation: User says, 'I live in Leith.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: area = Leith"),
        .init(prompt: "Conversation: User says, 'I am lactose intolerant.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: intolerance = lactose"),
        .init(prompt: "Conversation: User says, 'My partner is called Jamie.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: partner = Jamie"),
        .init(prompt: "Conversation: User says, 'I start work at 7 most weekdays.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: weekday start time = 7"),
        .init(prompt: "Conversation: User says, 'I use metric units.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "STORE: unit preference = metric"),
        .init(prompt: "Conversation: User says, 'My verification code today is 493821.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'I had soup for lunch.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'It's raining here right now.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'My parcel tracking number is AB12345.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'I'm in seat 14A today.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'I had toast this morning.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'This meeting ran long.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'The train is delayed tonight.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'I feel a bit tired today.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
        .init(prompt: "Conversation: User says, 'The Wi-Fi password is office-guest-22.' Reply with exactly either STORE: <fact> or IGNORE.", expected: "IGNORE"),
    ]

    for (index, seed) in memorySeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "memory-%03d", index + 1),
                category: "memory_discipline",
                prompt: seed.prompt,
                maxTokens: 40,
                checks: [.exact(seed.expected)]
            )
        )
    }

    let summarySeeds: [SummarySeed] = [
        .init(prompt: "Source text: 'The team shipped the macOS update on Tuesday. It fixed a calendar sync bug, reduced memory usage, and improved startup time.' Summarise this in one sentence.", required: ["tuesday", "calendar sync", "memory", "startup"], forbidden: ["cancelled", "security breach"]),
        .init(prompt: "Source text: 'Mara missed the bus because heavy rain slowed traffic. She called ahead and arrived twenty minutes late.' Summarise this in one sentence.", required: ["rain", "late", "called ahead"], forbidden: ["early", "sunny"]),
        .init(prompt: "Source text: 'The workshop covered prompt design, local models, and privacy trade-offs. Attendees asked many questions about on-device inference.' Summarise this in one sentence.", required: ["prompt design", "local models", "privacy", "on-device"], forbidden: ["gardening", "cancelled"]),
        .init(prompt: "Source text: 'A small fire in the kitchen was quickly extinguished. No one was hurt, but the room smelled strongly of smoke.' Summarise this in one sentence.", required: ["small fire", "no one was hurt", "smoke"], forbidden: ["building destroyed"]),
        .init(prompt: "Source text: 'Fae switched from a dual concierge design to single-model Qwen3.5. Vision now loads on demand through a separate Qwen3-VL model.' Summarise this in one sentence.", required: ["single-model", "qwen3.5", "vision", "on demand"], forbidden: ["liquid default"]),
        .init(prompt: "Source text: 'The train left at 08:15, stopped at Stirling, and arrived in Glasgow at 09:10.' Summarise this in one sentence.", required: ["08:15", "stirling", "glasgow", "09:10"], forbidden: ["edinburgh"]),
        .init(prompt: "Source text: 'The release was delayed because the secure input overlay was invisible. After switching to a darker card surface, manual checks passed.' Summarise this in one sentence.", required: ["delayed", "secure input overlay", "darker card surface", "passed"], forbidden: ["unchanged"]),
        .init(prompt: "Source text: 'The weather warning covers Edinburgh and Fife. High winds are expected overnight, and ferry disruption is likely.' Summarise this in one sentence.", required: ["edinburgh", "fife", "high winds", "ferry"], forbidden: ["heatwave"]),
        .init(prompt: "Source text: 'The benchmark harness showed perfect tool calling for Qwen3.5-4B, 9B, 27B, and 35B-A3B, but the live app path exposed a readiness bug.' Summarise this in one sentence.", required: ["perfect tool calling", "4b", "9b", "readiness bug"], forbidden: ["no bug"]),
        .init(prompt: "Source text: 'Iona reviewed the draft, suggested a shorter opening, and asked for clearer next steps by Friday.' Summarise this in one sentence.", required: ["shorter opening", "clearer next steps", "friday"], forbidden: ["approved without changes"]),
        .init(prompt: "Source text: 'The family arrived at 6, ate dinner at 7, and left just before 9 because the last train was delayed.' Summarise this in one sentence.", required: ["6", "7", "before 9", "train was delayed"], forbidden: ["left at noon"]),
        .init(prompt: "Source text: 'Camera use is occasional, not continuous. Screenshots and sparse still frames are the main perception mode.' Summarise this in one sentence.", required: ["occasional", "not continuous", "screenshots", "still frames"], forbidden: ["always on video"]),
        .init(prompt: "Source text: 'The package contains a notebook, a charger, two adapters, and a handwritten card.' Summarise this in one sentence.", required: ["notebook", "charger", "two adapters", "handwritten card"], forbidden: ["laptop"]),
        .init(prompt: "Source text: 'Alex changed the meeting from Wednesday to Thursday at 11, and the room moved from Cedar to Rowan.' Summarise this in one sentence.", required: ["thursday", "11", "cedar", "rowan"], forbidden: ["wednesday remains"]),
        .init(prompt: "Source text: 'The freeform eval should replace flaky MCQs as the main signal for correctness, consistency, and conversational quality.' Summarise this in one sentence.", required: ["freeform eval", "replace", "mcqs", "conversational quality"], forbidden: ["mcqs remain main signal"]),
        .init(prompt: "Source text: 'The gardener pruned the apple tree, planted basil, and fixed the broken gate before the rain began.' Summarise this in one sentence.", required: ["apple tree", "basil", "broken gate", "rain"], forbidden: ["snow"]),
        .init(prompt: "Source text: 'Pat forgot the tickets at home, drove back to get them, and still reached the theatre before the curtain.' Summarise this in one sentence.", required: ["tickets", "drove back", "theatre", "before the curtain"], forbidden: ["missed the show"]),
        .init(prompt: "Source text: 'The build succeeded on the second attempt after the missing destination flag was added to xcodebuild.' Summarise this in one sentence.", required: ["second attempt", "destination flag", "xcodebuild"], forbidden: ["never built"]),
        .init(prompt: "Source text: 'The budget includes rent, food, transport, and a small emergency buffer.' Summarise this in one sentence.", required: ["rent", "food", "transport", "emergency buffer"], forbidden: ["luxury travel"]),
        .init(prompt: "Source text: 'The school emailed to confirm the trip leaves at 07:30, requires packed lunch, and returns by 18:00.' Summarise this in one sentence.", required: ["07:30", "packed lunch", "18:00"], forbidden: ["overnight stay"]),
        .init(prompt: "Source text: 'Contacts permission looked denied because EventKit write-only access was being treated as failure, but the fix corrected that path.' Summarise this in one sentence.", required: ["write-only access", "treated as failure", "fix corrected"], forbidden: ["contacts were never affected"]),
        .init(prompt: "Source text: 'Qwen3-VL loads on demand, which keeps idle RAM lower than always loading a separate vision model.' Summarise this in one sentence.", required: ["loads on demand", "idle ram lower", "vision model"], forbidden: ["always loaded"]),
        .init(prompt: "Source text: 'The cafe was busy but calm, and the barista remembered the usual order without being asked.' Summarise this in one sentence.", required: ["busy but calm", "barista", "usual order"], forbidden: ["empty cafe"]),
        .init(prompt: "Source text: 'The river path was closed after flooding, so walkers were redirected through the upper park instead.' Summarise this in one sentence.", required: ["closed", "flooding", "redirected", "upper park"], forbidden: ["river path open"]),
        .init(prompt: "Source text: 'After the benchmark rerun, the remaining blocker was not model quality but the app startup path never reaching pipeline ready.' Summarise this in one sentence.", required: ["not model quality", "startup path", "pipeline ready"], forbidden: ["models were unusable"]),
    ]

    for (index, seed) in summarySeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "summary-%03d", index + 1),
                category: "summarization_grounded",
                prompt: seed.prompt,
                maxTokens: 96,
                checks: [
                    .containsAll(seed.required),
                    .forbidsAny(seed.forbidden),
                    .maxWords(34),
                ]
            )
        )
    }

    let supportSeeds: [SupportSeed] = [
        .init(prompt: "User says: 'I'm overwhelmed and don't know where to start.' Reply naturally in one or two sentences.", requiredAny: ["let's break", "one small step", "what feels most urgent"], forbidden: ["not my problem", "calm down"], needsQuestion: true),
        .init(prompt: "User says: 'I'm nervous about the presentation.' Reply naturally in one or two sentences.", requiredAny: ["you've got this", "let's keep it simple", "want to practise"], forbidden: ["just relax", "stop worrying"], needsQuestion: true),
        .init(prompt: "User says: 'Can you explain this simply?' Reply naturally in one or two sentences.", requiredAny: ["keep it simple", "plain terms", "step by step"], forbidden: ["jargon", "figure it out"], needsQuestion: false),
        .init(prompt: "User says: 'I made a mistake in that email.' Reply naturally in one or two sentences.", requiredAny: ["draft", "correction", "want me to help"], forbidden: ["ignore it forever", "impossible"], needsQuestion: true),
        .init(prompt: "User says: 'I'm behind on everything today.' Reply naturally in one or two sentences.", requiredAny: ["prioritise", "one thing", "we can"], forbidden: ["hopeless", "not my problem"], needsQuestion: true),
        .init(prompt: "User says: 'I need a quick summary before my meeting.' Reply naturally in one or two sentences.", requiredAny: ["concise", "key points", "I can"], forbidden: ["twelve paragraphs"], needsQuestion: false),
        .init(prompt: "User says: 'I feel a bit stuck.' Reply naturally in one or two sentences.", requiredAny: ["unstick", "next step", "we can"], forbidden: ["give up", "nothing to do"], needsQuestion: true),
        .init(prompt: "User says: 'I'm embarrassed I forgot again.' Reply naturally in one or two sentences.", requiredAny: ["that's okay", "we can make a plan", "want a reminder"], forbidden: ["that's bad", "your fault"], needsQuestion: true),
        .init(prompt: "User says: 'I need help being kinder in this reply.' Reply naturally in one or two sentences.", requiredAny: ["gentler", "draft", "want me to rewrite"], forbidden: ["be harsher"], needsQuestion: true),
        .init(prompt: "User says: 'This is all a bit much today.' Reply naturally in one or two sentences.", requiredAny: ["one thing at a time", "small next step", "we can"], forbidden: ["deal with it"], needsQuestion: true),
        .init(prompt: "User says: 'Can you give me a calmer version of this message?' Reply naturally in one or two sentences.", requiredAny: ["calmer", "rewrite", "want me to"], forbidden: ["send it angry"], needsQuestion: true),
        .init(prompt: "User says: 'I'm worried I've missed something important.' Reply naturally in one or two sentences.", requiredAny: ["checklist", "scan", "let's review"], forbidden: ["too late"], needsQuestion: true),
        .init(prompt: "User says: 'I can't focus.' Reply naturally in one or two sentences.", requiredAny: ["five minutes", "single task", "let's narrow"], forbidden: ["impossible"], needsQuestion: true),
        .init(prompt: "User says: 'Can you make this easier to understand?' Reply naturally in one or two sentences.", requiredAny: ["simpler", "plain language", "clear"], forbidden: ["more complex"], needsQuestion: false),
        .init(prompt: "User says: 'I need to apologise without sounding defensive.' Reply naturally in one or two sentences.", requiredAny: ["apology", "own it", "draft"], forbidden: ["blame them"], needsQuestion: true),
        .init(prompt: "User says: 'I keep putting this off.' Reply naturally in one or two sentences.", requiredAny: ["first step", "ten minutes", "we can"], forbidden: ["lazy"], needsQuestion: true),
        .init(prompt: "User says: 'Can you help me say this more gently?' Reply naturally in one or two sentences.", requiredAny: ["gentler", "rewrite", "want me to"], forbidden: ["be blunt"], needsQuestion: true),
        .init(prompt: "User says: 'I'm a bit ashamed to ask for help.' Reply naturally in one or two sentences.", requiredAny: ["okay to ask", "I can help", "we can"], forbidden: ["you should know"], needsQuestion: true),
        .init(prompt: "User says: 'I need a quick confidence boost.' Reply naturally in one or two sentences.", requiredAny: ["you can do this", "you've handled this before", "one steady step"], forbidden: ["you will fail"], needsQuestion: false),
        .init(prompt: "User says: 'I don't know how to start the message.' Reply naturally in one or two sentences.", requiredAny: ["draft", "opening line", "want me to"], forbidden: ["just send anything"], needsQuestion: true),
        .init(prompt: "User says: 'This feels messy.' Reply naturally in one or two sentences.", requiredAny: ["tidy it up", "key points", "we can"], forbidden: ["hopeless"], needsQuestion: true),
        .init(prompt: "User says: 'Can you make this sound warmer?' Reply naturally in one or two sentences.", requiredAny: ["warmer", "rewrite", "want me to"], forbidden: ["make it colder"], needsQuestion: true),
        .init(prompt: "User says: 'I think I need to slow down.' Reply naturally in one or two sentences.", requiredAny: ["pause", "breathe", "one thing"], forbidden: ["rush"], needsQuestion: false),
        .init(prompt: "User says: 'Can you turn this into a kinder reply?' Reply naturally in one or two sentences.", requiredAny: ["kinder", "rewrite", "want me to"], forbidden: ["sharper"], needsQuestion: true),
        .init(prompt: "User says: 'I just need a little help to get moving.' Reply naturally in one or two sentences.", requiredAny: ["small step", "I can help", "want to start"], forbidden: ["can't help"], needsQuestion: true),
    ]

    for (index, seed) in supportSeeds.enumerated() {
        var checks: [FreeformCheck] = [
            .containsAny(seed.requiredAny),
            .forbidsAny(seed.forbidden),
            .minWords(6),
            .maxWords(42),
        ]
        if seed.needsQuestion {
            checks.append(.requiresQuestion)
        }
        cases.append(
            FreeformEvalCase(
                id: String(format: "support-%03d", index + 1),
                category: "supportive_reply",
                prompt: seed.prompt,
                maxTokens: 96,
                checks: checks
            )
        )
    }

    let rewriteSeeds: [RewriteSeed] = [
        .init(prompt: "Draft a brief reply accepting lunch on Tuesday at 1pm. Keep it under 25 words.", required: ["tuesday", "1pm"], politeAny: ["sounds good", "works for me", "see you"]),
        .init(prompt: "Draft a short reply declining Friday lunch because I'm away. Keep it under 25 words.", required: ["friday", "away"], politeAny: ["sorry", "can't make it", "another time"]),
        .init(prompt: "Draft a short email asking for a deadline extension to Wednesday. Keep it under 35 words.", required: ["wednesday", "deadline"], politeAny: ["could", "please", "thank you"]),
        .init(prompt: "Draft a short message saying I'll be 10 minutes late. Keep it under 20 words.", required: ["10 minutes", "late"], politeAny: ["sorry", "be there soon"]),
        .init(prompt: "Draft a short reply thanking Priya for the update and saying I'll review it tonight. Keep it under 30 words.", required: ["priya", "review", "tonight"], politeAny: ["thanks", "thank you"]),
        .init(prompt: "Draft a short note asking Jamie if 3pm works. Keep it under 20 words.", required: ["3pm"], politeAny: ["does", "work", "would"]),
        .init(prompt: "Draft a short reply confirming the meeting room is Rowan. Keep it under 20 words.", required: ["rowan"], politeAny: ["confirmed", "we're in", "see you"]),
        .init(prompt: "Draft a short apology for missing the call and ask to reschedule tomorrow. Keep it under 30 words.", required: ["sorry", "tomorrow"], politeAny: ["reschedule", "could we"]),
        .init(prompt: "Draft a short message saying the file is attached and the key points are highlighted. Keep it under 25 words.", required: ["attached", "highlighted"], politeAny: ["here", "I've"]),
        .init(prompt: "Draft a short reply saying I can do Thursday after 2. Keep it under 20 words.", required: ["thursday", "after 2"], politeAny: ["works", "can do"]),
        .init(prompt: "Draft a short reminder message to bring the passport and charger. Keep it under 20 words.", required: ["passport", "charger"], politeAny: ["don't forget", "remember"]),
        .init(prompt: "Draft a short note to the neighbour asking them to leave the parcel inside. Keep it under 25 words.", required: ["parcel", "inside"], politeAny: ["please", "could you"]),
        .init(prompt: "Draft a short message saying I finished the benchmark rerun and will send results soon. Keep it under 25 words.", required: ["benchmark rerun", "results"], politeAny: ["finished", "soon"]),
        .init(prompt: "Draft a short reply asking Alex which file they mean. Keep it under 20 words.", required: ["which file"], politeAny: ["do you mean", "which"]),
        .init(prompt: "Draft a short message saying I'm at the station and will arrive at 6. Keep it under 20 words.", required: ["station", "6"], politeAny: ["arrive", "be there"]),
        .init(prompt: "Draft a short response telling Pat the summary is ready and attached. Keep it under 20 words.", required: ["summary", "attached"], politeAny: ["ready", "here"]),
        .init(prompt: "Draft a short note asking if lunch can move to 12:30. Keep it under 20 words.", required: ["12:30"], politeAny: ["could", "can"]),
        .init(prompt: "Draft a short reply saying the train is delayed but I'm on the way. Keep it under 20 words.", required: ["train", "delayed", "on the way"], politeAny: ["sorry", "still"]),
        .init(prompt: "Draft a short email saying I reviewed the proposal and left comments. Keep it under 25 words.", required: ["reviewed", "comments"], politeAny: ["I've", "left"]),
        .init(prompt: "Draft a short message asking what time the school pickup is. Keep it under 20 words.", required: ["what time", "school pickup"], politeAny: ["is"]),
        .init(prompt: "Draft a short reply confirming dinner at 7 on Saturday. Keep it under 20 words.", required: ["7", "saturday"], politeAny: ["confirmed", "see you"]),
        .init(prompt: "Draft a short message saying I'll send the final copy by Monday morning. Keep it under 20 words.", required: ["monday morning", "final copy"], politeAny: ["I'll send", "by"]),
        .init(prompt: "Draft a short note asking for the invoice address. Keep it under 20 words.", required: ["invoice", "address"], politeAny: ["could you", "what is"]),
        .init(prompt: "Draft a short reply saying the secure input fix is in and ready to test. Keep it under 25 words.", required: ["secure input fix", "ready to test"], politeAny: ["is in", "ready"]),
        .init(prompt: "Draft a short message saying I can talk after the school run. Keep it under 20 words.", required: ["after the school run"], politeAny: ["can talk", "free"]),
    ]

    for (index, seed) in rewriteSeeds.enumerated() {
        cases.append(
            FreeformEvalCase(
                id: String(format: "rewrite-%03d", index + 1),
                category: "rewrite_actionable",
                prompt: seed.prompt,
                maxTokens: 96,
                checks: [
                    .containsAll(seed.required),
                    .containsAny(seed.politeAny),
                    .maxWords(34),
                ]
            )
        )
    }

    return cases
}

let freeformEvalCases: [FreeformEvalCase] = buildFreeformEvalCases()
