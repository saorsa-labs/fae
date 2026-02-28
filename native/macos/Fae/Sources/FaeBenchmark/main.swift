// FaeBenchmark — Swift MLX LLM Benchmark for Fae
//
// Benchmarks Qwen3 and Qwen3.5 models on Apple Silicon via mlx-swift-lm.
// Uses the same ML stack as Fae for accurate, aligned measurements.
//
// Usage:
//   swift run FaeBenchmark --model qwen3.5-35b-a3b
//   swift run FaeBenchmark --all
//   swift run FaeBenchmark --model qwen3-8b --throughput --tools
//
// Models auto-download from HuggingFace on first run.

import Foundation
import MLXLLM
import MLXLMCommon

// MARK: - Model Registry

struct ModelEntry {
    let shortName: String
    let modelID: String
}

let models: [ModelEntry] = [
    ModelEntry(shortName: "qwen3-0.6b", modelID: "mlx-community/Qwen3-0.6B-4bit"),
    ModelEntry(shortName: "qwen3-1.7b", modelID: "mlx-community/Qwen3-1.7B-4bit"),
    ModelEntry(shortName: "qwen3-4b", modelID: "mlx-community/Qwen3-4B-4bit"),
    ModelEntry(shortName: "qwen3-8b", modelID: "mlx-community/Qwen3-8B-4bit"),
    // NexVeridian text-only conversions (vision tower stripped).
    // mlx-community versions are VL — incompatible with text-only loading.
    ModelEntry(shortName: "qwen3.5-35b-a3b", modelID: "NexVeridian/Qwen3.5-35B-A3B-4bit"),
    ModelEntry(shortName: "qwen3.5-27b", modelID: "NexVeridian/Qwen3.5-27B-4bit"),
]

// MARK: - Result Types

struct ThroughputResult: Codable {
    let contextLabel: String
    let promptTokens: Int
    let generatedTokens: Int
    let visibleChars: Int
    let thinkingChars: Int
    let wallTimeS: Double
    let tokensPerSecond: Double      // Pure generation speed (MLX internal, excludes prefill)
    let promptTokensPerSecond: Double // Prompt processing speed (MLX internal)
    let ramMB: Double

    enum CodingKeys: String, CodingKey {
        case contextLabel = "context_label"
        case promptTokens = "prompt_tokens"
        case generatedTokens = "generated_tokens"
        case visibleChars = "visible_chars"
        case thinkingChars = "thinking_chars"
        case wallTimeS = "wall_time_s"
        case tokensPerSecond = "tokens_per_second"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case ramMB = "ram_mb"
    }
}

struct NoThinkResult: Codable {
    let prompt: String
    let thinkOnTokens: Int
    let thinkOnTimeS: Double
    let thinkOffTokens: Int
    let thinkOffTimeS: Double
    let overheadTokens: String
    let overheadTime: String
    let compliant: Bool

    enum CodingKeys: String, CodingKey {
        case prompt
        case thinkOnTokens = "think_on_tokens"
        case thinkOnTimeS = "think_on_time_s"
        case thinkOffTokens = "think_off_tokens"
        case thinkOffTimeS = "think_off_time_s"
        case overheadTokens = "overhead_tokens"
        case overheadTime = "overhead_time"
        case compliant
    }
}

struct ToolCallResult: Codable {
    let prompt: String
    let expectedTool: String
    let actualTool: String
    let correct: Bool
    let temperature: Float

    enum CodingKeys: String, CodingKey {
        case prompt
        case expectedTool = "expected_tool"
        case actualTool = "actual_tool"
        case correct
        case temperature
    }
}

struct ModelBenchmarkResult: Codable {
    let modelID: String
    let modelShort: String
    var idleRAMMB: Double
    var throughputNoThink: [ThroughputResult]
    var throughputThinkOn: [ThroughputResult]
    var noThinkCompliance: [NoThinkResult]
    var toolCalling: [ToolCallResult]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelShort = "model_short"
        case idleRAMMB = "idle_ram_mb"
        case throughputNoThink = "throughput_no_think"
        case throughputThinkOn = "throughput_think_on"
        case noThinkCompliance = "no_think_compliance"
        case toolCalling = "tool_calling"
    }
}

struct BenchmarkOutput: Codable {
    let hardware: Hardware
    let date: String
    let backend: String
    let models: [ModelBenchmarkResult]

    struct Hardware: Codable {
        let arch: String
        let ramGB: Int

        enum CodingKeys: String, CodingKey {
            case arch
            case ramGB = "ram_gb"
        }
    }
}

// MARK: - Helpers

func currentRAMMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if result == KERN_SUCCESS {
        return Double(info.resident_size) / (1024 * 1024)
    }
    return 0
}

func systemRAMGB() -> Int {
    Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
}

func buildFillerText(targetWords: Int) -> String {
    let sentences = [
        "The history of artificial intelligence is a fascinating journey through decades of research and development.",
        "Machine learning algorithms have transformed how we process and understand data across many industries.",
        "Neural networks inspired by biological systems have become the foundation of modern deep learning approaches.",
        "Natural language processing enables computers to understand and generate human language with increasing accuracy.",
        "Computer vision systems can now identify objects and faces with superhuman performance in many benchmarks.",
        "Reinforcement learning has achieved remarkable results in game playing and robotics applications worldwide.",
        "The ethical implications of artificial intelligence deployment require careful consideration and governance frameworks.",
        "Transfer learning allows models trained on one task to be adapted efficiently for related problems and domains.",
        "Generative models can create realistic images text and audio that are increasingly difficult to distinguish from human work.",
        "Edge computing brings machine learning inference closer to data sources reducing latency and improving privacy.",
        "Federated learning enables training models across distributed devices without centralizing sensitive personal data.",
        "Quantum computing promises to accelerate certain machine learning algorithms exponentially in the coming decades.",
        "Autonomous vehicles rely on a combination of sensors machine learning and real time decision making systems.",
        "Healthcare applications of AI include medical image analysis drug discovery and personalized treatment planning.",
        "Climate modeling and environmental monitoring benefit from advanced machine learning prediction capabilities.",
        "Robotics and automation continue to evolve with improved perception planning and manipulation abilities.",
        "The democratization of AI tools has made machine learning accessible to developers without specialized training.",
        "Large language models have demonstrated emergent capabilities that were not explicitly programmed or expected.",
        "Data privacy regulations like GDPR impact how machine learning systems collect process and store information.",
        "The computational costs of training large models raise questions about environmental sustainability and access.",
    ]
    var text = ""
    var idx = 0
    while text.split(separator: " ").count < targetWords {
        text += sentences[idx % sentences.count] + " "
        idx += 1
    }
    return text.trimmingCharacters(in: .whitespaces)
}

func countThinkingChars(_ text: String) -> (visible: Int, thinking: Int) {
    let pattern = try! NSRegularExpression(pattern: "<think>(.*?)</think>", options: .dotMatchesLineSeparators)
    let range = NSRange(text.startIndex..., in: text)
    let matches = pattern.matches(in: text, range: range)

    var thinkingChars = 0
    for match in matches {
        if let thinkRange = Range(match.range(at: 1), in: text) {
            thinkingChars += text[thinkRange].count
        }
    }

    let visible = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (visible.count, thinkingChars)
}

// MARK: - Tool Schemas (for tool calling tests)

// Tool calling system prompt — tells the LLM it is Fae and can use tools.
let toolCallingSystemPrompt = """
/no_think

You are Fae, a personal AI companion running on macOS. When the user's request requires a tool, \
call the appropriate tool. For simple conversation, just respond directly without tools.
"""

// OpenAI function-calling format tools for UserInput.tools — the chat template will inject these.
let toolSpecs: [[String: any Sendable]] = [
    [
        "type": "function",
        "function": [
            "name": "calendar",
            "description": "Access macOS Calendar events. Actions: list_today, list_week, list_date, create, search.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list_today", "list_week", "list_date", "create", "search"],
                               "description": "Calendar action to perform"] as [String: any Sendable],
                    "query": ["type": "string", "description": "Search query"] as [String: any Sendable],
                    "date": ["type": "string", "description": "Date in YYYY-MM-DD format"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["action"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
        "type": "function",
        "function": [
            "name": "reminders",
            "description": "Access macOS Reminders. Actions: list_incomplete, create, complete, search.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list_incomplete", "create", "complete", "search"],
                               "description": "Reminders action"] as [String: any Sendable],
                    "title": ["type": "string", "description": "Reminder title"] as [String: any Sendable],
                    "query": ["type": "string", "description": "Search query"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["action"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
        "type": "function",
        "function": [
            "name": "contacts",
            "description": "Search macOS Contacts. Actions: search, get_phone, get_email.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["search", "get_phone", "get_email"],
                               "description": "Contacts action"] as [String: any Sendable],
                    "query": ["type": "string", "description": "Search query (name)"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["action", "query"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
        "type": "function",
        "function": [
            "name": "mail",
            "description": "Interact with macOS Mail. Actions: check_inbox, read_recent, send.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["check_inbox", "read_recent", "send"],
                               "description": "Mail action"] as [String: any Sendable],
                    "to": ["type": "string", "description": "Recipient email"] as [String: any Sendable],
                    "body": ["type": "string", "description": "Email body"] as [String: any Sendable],
                    "count": ["type": "integer", "description": "Number of messages"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["action"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
        "type": "function",
        "function": [
            "name": "notes",
            "description": "Access macOS Notes. Actions: list_recent, create, search.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list_recent", "create", "search"],
                               "description": "Notes action"] as [String: any Sendable],
                    "title": ["type": "string", "description": "Note title"] as [String: any Sendable],
                    "body": ["type": "string", "description": "Note body"] as [String: any Sendable],
                    "query": ["type": "string", "description": "Search query"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["action"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "Search the web using DuckDuckGo. Returns up to 5 results with titles, snippets, and URLs.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search query"] as [String: any Sendable],
                    "max_results": ["type": "integer", "description": "Max results (default 5)"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["query"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
    [
        "type": "function",
        "function": [
            "name": "read",
            "description": "Read the contents of a file from the filesystem.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path to read"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["path"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
]

let toolCallTests: [(prompt: String, expectedTool: String)] = [
    ("What's on my calendar tomorrow?", "calendar"),
    ("Remind me to buy groceries at 5pm", "reminders"),
    ("Search the web for the latest news about Apple", "web_search"),
    ("Send an email to john@example.com saying I'll be late", "mail"),
    ("What's David's phone number?", "contacts"),
    ("Create a note called Shopping List with milk, eggs, bread", "notes"),
    ("Read the file at ~/Documents/todo.txt", "read"),
    ("Can you look something up for me about quantum computing?", "web_search"),
    ("How are you feeling today?", "none"),
    ("Tell me a joke about programming", "none"),
]

let noThinkTestPrompts = [
    "What is the capital of France?",
    "Explain quantum computing in one sentence.",
    "What is 17 * 23?",
    "Name three planets in our solar system.",
    "What year did World War II end?",
]

// MARK: - Benchmark Engine

actor BenchmarkEngine {
    private var container: ModelContainer?
    private let modelID: String
    private let shortName: String

    init(modelID: String, shortName: String) {
        self.modelID = modelID
        self.shortName = shortName
    }

    func load() async throws {
        print("  Loading \(shortName) (\(modelID))...")
        let config = ModelConfiguration(id: modelID)
        container = try await LLMModelFactory.shared.loadContainer(configuration: config)
        print("  Loaded.")
    }

    func warmup() async throws {
        guard let container else { return }
        print("  Warming up (3 throwaway generations)...")
        for _ in 0..<3 {
            let input = UserInput(
                chat: [
                    .system("/no_think\nYou are a helpful assistant."),
                    .user("Hello"),
                ]
            )
            let lmInput = try await container.prepare(input: input)
            let params = GenerateParameters(maxTokens: 16, temperature: 0.7)
            let stream = try await container.generate(input: lmInput, parameters: params)
            for await _ in stream {}
        }
    }

    struct GenerateResult {
        let text: String
        let promptTokens: Int
        let genTokens: Int
        let wallTime: Double
        let genTPS: Double      // MLX-internal generation tokens/sec (excludes prefill)
        let promptTPS: Double   // MLX-internal prompt processing tokens/sec
        let toolCalls: [ToolCall] // Tool calls parsed by the library
    }

    func generate(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Float,
        tools: [[String: any Sendable]]? = nil
    ) async throws -> GenerateResult {
        guard let container else {
            throw BenchmarkError.modelNotLoaded
        }

        let input = UserInput(
            chat: [
                .system(system),
                .user(user),
            ],
            tools: tools
        )

        let lmInput = try await container.prepare(input: input)
        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )

        let start = CFAbsoluteTimeGetCurrent()
        let stream = try await container.generate(input: lmInput, parameters: params)

        var fullText = ""
        var promptTokens = 0
        var genTokens = 0
        var genTPS: Double = 0
        var promptTPS: Double = 0
        var capturedToolCalls: [ToolCall] = []

        for await generation in stream {
            switch generation {
            case .chunk(let text):
                fullText += text
            case .info(let info):
                promptTokens = info.promptTokenCount
                genTokens = info.generationTokenCount
                genTPS = info.tokensPerSecond
                promptTPS = info.promptTokensPerSecond
            case .toolCall(let call):
                capturedToolCalls.append(call)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return GenerateResult(
            text: fullText,
            promptTokens: promptTokens,
            genTokens: genTokens,
            wallTime: elapsed,
            genTPS: genTPS,
            promptTPS: promptTPS,
            toolCalls: capturedToolCalls
        )
    }

    // MARK: - Throughput Sweep

    func runContextSweep(thinkMode: String) async throws -> [ThroughputResult] {
        let system: String
        if thinkMode == "no_think" {
            system = "/no_think\n\nYou are a helpful assistant. Be concise."
        } else {
            system = "You are a helpful assistant. Be concise."
        }

        let filler = buildFillerText(targetWords: 6500)
        let words = filler.split(separator: " ")

        let tests: [(label: String, userPrompt: String, maxTokens: Int)] = [
            ("Short (~20 tok)", "What is the weather like today?", 128),
            ("~200 tok ctx", words.prefix(150).joined(separator: " ") + " Summarize.", 256),
            ("~500 tok ctx", words.prefix(350).joined(separator: " ") + " Summarize.", 256),
            ("~1K tok ctx", words.prefix(750).joined(separator: " ") + " Summarize.", 256),
            ("~2K tok ctx", words.prefix(1500).joined(separator: " ") + " Summarize.", 256),
            ("~4K tok ctx", words.prefix(3000).joined(separator: " ") + " Summarize.", 256),
            ("~8.5K tok", filler + " Given all of this context, what are the three most important developments?", 256),
        ]

        var results: [ThroughputResult] = []
        for (label, userPrompt, maxTokens) in tests {
            print("    \(label)...", terminator: "")
            fflush(stdout)

            // Best of 2 runs (by generation T/s)
            var bestTPS: Double = 0
            var bestResult: ThroughputResult?

            for _ in 0..<2 {
                let result = try await generate(
                    system: system,
                    user: userPrompt,
                    maxTokens: maxTokens,
                    temperature: 0.7
                )

                let tps = result.genTPS
                if tps > bestTPS {
                    bestTPS = tps
                    let (visible, thinking) = countThinkingChars(result.text)
                    let ram = currentRAMMB()
                    bestResult = ThroughputResult(
                        contextLabel: label,
                        promptTokens: result.promptTokens,
                        generatedTokens: result.genTokens,
                        visibleChars: visible,
                        thinkingChars: thinking,
                        wallTimeS: (result.wallTime * 100).rounded() / 100,
                        tokensPerSecond: (tps * 10).rounded() / 10,
                        promptTokensPerSecond: (result.promptTPS * 10).rounded() / 10,
                        ramMB: ram.rounded()
                    )
                }
            }

            if let r = bestResult {
                print(" \(r.tokensPerSecond) T/s (gen), \(r.promptTokensPerSecond) T/s (prompt), \(Int(r.ramMB)) MB")
                results.append(r)
            } else {
                print(" FAILED")
            }
        }

        return results
    }

    // MARK: - /no_think Compliance

    func runNoThinkTest() async throws -> [NoThinkResult] {
        let systemOn = "You are a helpful assistant. Be concise."
        let systemOff = "/no_think\n\nYou are a helpful assistant. Be concise."

        var results: [NoThinkResult] = []
        for prompt in noThinkTestPrompts {
            print("    Testing: \(prompt.prefix(50))...", terminator: "")
            fflush(stdout)

            // Thinking ON
            let resOn = try await generate(
                system: systemOn, user: prompt, maxTokens: 256, temperature: 0.7
            )
            let tokOn = resOn.genTokens
            let timeOn = resOn.wallTime
            _ = countThinkingChars(resOn.text)

            // Thinking OFF
            let resOff = try await generate(
                system: systemOff, user: prompt, maxTokens: 256, temperature: 0.7
            )
            let tokOff = resOff.genTokens
            let timeOff = resOff.wallTime
            let (_, thinkCharsOff) = countThinkingChars(resOff.text)

            let tokOverhead = tokOff > 0 ? "\(Int(round(Double(tokOn) / Double(max(tokOff, 1)))))x" : "N/A"
            let timeOverhead = timeOff > 0.001 ? "\(Int(round(timeOn / max(timeOff, 0.001))))x" : "N/A"
            let compliant = thinkCharsOff <= 10

            print(" \(compliant ? "OK" : "LEAKS") (on=\(tokOn)tok, off=\(tokOff)tok)")
            results.append(NoThinkResult(
                prompt: prompt,
                thinkOnTokens: tokOn,
                thinkOnTimeS: (timeOn * 100).rounded() / 100,
                thinkOffTokens: tokOff,
                thinkOffTimeS: (timeOff * 100).rounded() / 100,
                overheadTokens: tokOverhead,
                overheadTime: timeOverhead,
                compliant: compliant
            ))
        }

        return results
    }

    // MARK: - Tool Calling

    func runToolCallingTest(temperature: Float = 0.2) async throws -> [ToolCallResult] {
        let system = toolCallingSystemPrompt
        let validTools = Set(["calendar", "reminders", "contacts", "mail", "notes",
                              "web_search", "web_search", "read", "write", "bash"])

        var results: [ToolCallResult] = []
        for test in toolCallTests {
            print("    Tool test: \(test.prompt.prefix(50))...", terminator: "")
            fflush(stdout)

            // Pass tools via UserInput.tools so the chat template injects them properly.
            let toolResult = try await generate(
                system: system,
                user: test.prompt,
                maxTokens: 512,
                temperature: temperature,
                tools: test.expectedTool == "none" ? nil : toolSpecs
            )
            let output = toolResult.text

            var actual = "none"

            // 1. Check for library-parsed .toolCall events (native path)
            if let firstCall = toolResult.toolCalls.first {
                let name = firstCall.function.name
                // Map web_search back to web_search for comparison
                actual = name == "web_search" ? "web_search" : name
            }

            // 2. Fallback: check raw text for <tool_call> tags (in case library didn't parse)
            if actual == "none" && output.contains("<tool_call>") {
                if let nameRange = output.range(of: #""name"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                    let match = output[nameRange]
                    if let valueRange = match.range(of: #""([^"]+)"$"#, options: .regularExpression) {
                        let candidate = String(match[valueRange]).replacingOccurrences(of: "\"", with: "")
                        let mapped = candidate == "web_search" ? "web_search" : candidate
                        if validTools.contains(candidate) { actual = mapped }
                    }
                }
            }

            // 3. Fallback: look for "name": "tool_name" pattern in raw text
            if actual == "none" {
                if let nameMatch = output.range(of: #"["']name["']\s*:\s*["'](\w+)["']"#, options: .regularExpression) {
                    let captured = output[nameMatch]
                    if let valRange = captured.range(of: #"["'](\w+)["']$"#, options: .regularExpression) {
                        let candidate = String(captured[valRange])
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        let mapped = candidate == "web_search" ? "web_search" : candidate
                        if validTools.contains(candidate) { actual = mapped }
                    }
                }
            }

            let correct = actual == test.expectedTool
            print(" \(correct ? "OK" : "MISS") (expected=\(test.expectedTool), got=\(actual))")
            if !correct && test.expectedTool != "none" {
                let nativeCount = toolResult.toolCalls.count
                let preview = String(output.prefix(300)).replacingOccurrences(of: "\n", with: "\\n")
                print("      Native .toolCall events: \(nativeCount)")
                print("      Response: \(preview)")
            }

            results.append(ToolCallResult(
                prompt: test.prompt,
                expectedTool: test.expectedTool,
                actualTool: actual,
                correct: correct,
                temperature: temperature
            ))
        }

        return results
    }

    func unload() {
        container = nil
    }
}

enum BenchmarkError: Error {
    case modelNotLoaded
}

// MARK: - CLI Argument Parsing

struct CLIArgs {
    var modelShortName: String?
    var runAll = false
    var qwen3Only = false
    var qwen35Only = false
    var doThroughput = false
    var doNoThink = false
    var doRAM = false
    var doTools = false
    var outputPath: String?
    var markdownPath: String?

    var runAllDimensions: Bool {
        !doThroughput && !doNoThink && !doRAM && !doTools
    }
}

func parseArgs() -> CLIArgs {
    var args = CLIArgs()
    let argv = CommandLine.arguments

    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--model":
            i += 1
            if i < argv.count { args.modelShortName = argv[i] }
        case "--all":
            args.runAll = true
        case "--qwen3-only":
            args.qwen3Only = true
        case "--qwen35-only":
            args.qwen35Only = true
        case "--throughput":
            args.doThroughput = true
        case "--no-think":
            args.doNoThink = true
        case "--ram":
            args.doRAM = true
        case "--tools":
            args.doTools = true
        case "--output":
            i += 1
            if i < argv.count { args.outputPath = argv[i] }
        case "--markdown":
            i += 1
            if i < argv.count { args.markdownPath = argv[i] }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            print("Unknown argument: \(argv[i])")
            printUsage()
            exit(1)
        }
        i += 1
    }

    return args
}

func printUsage() {
    print("""
    FaeBenchmark — Swift MLX LLM Benchmark for Fae

    Usage:
      swift run FaeBenchmark --model <short-name>   Benchmark a single model
      swift run FaeBenchmark --all                   Benchmark all models
      swift run FaeBenchmark --qwen3-only            Benchmark Qwen3 models only
      swift run FaeBenchmark --qwen35-only           Benchmark Qwen3.5 models only

    Model short names:
      qwen3-0.6b, qwen3-1.7b, qwen3-4b, qwen3-8b,
      qwen3.5-35b-a3b, qwen3.5-27b

    Dimensions (default: all):
      --throughput   Run throughput benchmark (7 context sizes x 2 modes)
      --no-think     Run /no_think compliance test
      --ram          Measure idle RAM usage
      --tools        Run tool calling accuracy test

    Output:
      --output <path>     JSON output path (default: scripts/mlx_benchmark_results.json)
      --markdown <path>   Markdown output path (default: stdout)
    """)
}

// MARK: - Markdown Output

func resultsToMarkdown(_ benchmarks: [ModelBenchmarkResult]) -> String {
    var lines: [String] = []
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let today = dateFormatter.string(from: Date())

    lines.append("## MLX Benchmark Results (Swift)")
    lines.append("")
    lines.append("**Hardware:** Apple Silicon, \(systemRAMGB()) GB unified memory")
    lines.append("**Quantization:** 4-bit (MLX)")
    lines.append("**Backend:** mlx-swift-lm (native Swift, same stack as Fae)")
    lines.append("**Date:** \(today)")
    lines.append("")

    // Model summary
    lines.append("### Model Summary")
    lines.append("")
    lines.append("| Model | Idle RAM | Peak T/s (no_think) | ~500 tok T/s | 8.5K ctx T/s |")
    lines.append("|---|---:|---:|---:|---:|")

    for b in benchmarks {
        let peakNoThink = b.throughputNoThink.map(\.tokensPerSecond).max() ?? 0
        let ctx500 = b.throughputNoThink.first(where: { $0.contextLabel.contains("500") })?.tokensPerSecond ?? 0
        let ctx8k = b.throughputNoThink.first(where: { $0.contextLabel.contains("8.5K") })?.tokensPerSecond ?? 0
        lines.append("| \(b.modelShort) | \(Int(b.idleRAMMB)) MB | \(Int(peakNoThink)) | \(Int(ctx500)) | \(Int(ctx8k)) |")
    }
    lines.append("")

    // Speed by context — /no_think
    lines.append("### Speed by Context Size — /no_think")
    lines.append("")
    let headers = ["Context"] + benchmarks.map(\.modelShort)
    lines.append("| " + headers.joined(separator: " | ") + " |")
    lines.append("|" + (["---"] + Array(repeating: "---:", count: benchmarks.count)).joined(separator: "|") + "|")

    var allLabels: [String] = []
    for b in benchmarks {
        for r in b.throughputNoThink {
            if !allLabels.contains(r.contextLabel) { allLabels.append(r.contextLabel) }
        }
    }

    for label in allLabels {
        var row = [label]
        for b in benchmarks {
            if let val = b.throughputNoThink.first(where: { $0.contextLabel == label })?.tokensPerSecond {
                row.append("\(Int(val))")
            } else {
                row.append("-")
            }
        }
        lines.append("| " + row.joined(separator: " | ") + " |")
    }
    lines.append("")

    // Speed by context — thinking ON
    lines.append("### Speed by Context Size — Thinking ON")
    lines.append("")
    lines.append("| " + headers.joined(separator: " | ") + " |")
    lines.append("|" + (["---"] + Array(repeating: "---:", count: benchmarks.count)).joined(separator: "|") + "|")

    for label in allLabels {
        var row = [label]
        for b in benchmarks {
            if let val = b.throughputThinkOn.first(where: { $0.contextLabel == label })?.tokensPerSecond {
                row.append("\(Int(val))")
            } else {
                row.append("-")
            }
        }
        lines.append("| " + row.joined(separator: " | ") + " |")
    }
    lines.append("")

    // /no_think compliance
    let hasCompliance = benchmarks.contains(where: { !$0.noThinkCompliance.isEmpty })
    if hasCompliance {
        lines.append("### /no_think Compliance")
        lines.append("")
        lines.append("| Model | Compliant | Details |")
        lines.append("|---|---|---|")
        for b in benchmarks where !b.noThinkCompliance.isEmpty {
            let allOK = b.noThinkCompliance.allSatisfy(\.compliant)
            let status = allOK ? "Yes" : "Leaks thinking tokens"
            lines.append("| \(b.modelShort) | \(status) | |")
        }
        lines.append("")
    }

    // Tool calling
    let hasTools = benchmarks.contains(where: { !$0.toolCalling.isEmpty })
    if hasTools {
        lines.append("### Tool Calling Accuracy")
        lines.append("")
        lines.append("| Model | Correct | Total | Accuracy |")
        lines.append("|---|---:|---:|---:|")
        for b in benchmarks where !b.toolCalling.isEmpty {
            let correct = b.toolCalling.filter(\.correct).count
            let total = b.toolCalling.count
            let pct = total > 0 ? Int(round(Double(correct) / Double(total) * 100)) : 0
            lines.append("| \(b.modelShort) | \(correct) | \(total) | \(pct)% |")
        }
        lines.append("")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Main

func benchmarkModel(
    modelID: String,
    shortName: String,
    doThroughput: Bool,
    doNoThink: Bool,
    doRAM: Bool,
    doTools: Bool
) async throws -> ModelBenchmarkResult {
    print("\n" + String(repeating: "=", count: 70))
    print("  \(shortName) (\(modelID))")
    print(String(repeating: "=", count: 70))

    let engine = BenchmarkEngine(modelID: modelID, shortName: shortName)
    try await engine.load()

    var result = ModelBenchmarkResult(
        modelID: modelID,
        modelShort: shortName,
        idleRAMMB: 0,
        throughputNoThink: [],
        throughputThinkOn: [],
        noThinkCompliance: [],
        toolCalling: []
    )

    // RAM
    if doRAM {
        print("\n  Measuring idle RAM...")
        result.idleRAMMB = currentRAMMB().rounded()
        print("    Idle RAM: \(Int(result.idleRAMMB)) MB")
    }

    // Warmup
    try await engine.warmup()

    // Throughput
    if doThroughput {
        print("\n  Throughput (/no_think):")
        result.throughputNoThink = try await engine.runContextSweep(thinkMode: "no_think")

        print("\n  Throughput (thinking ON):")
        result.throughputThinkOn = try await engine.runContextSweep(thinkMode: "think_on")
    }

    // /no_think compliance
    if doNoThink {
        print("\n  /no_think compliance:")
        result.noThinkCompliance = try await engine.runNoThinkTest()
    }

    // Tool calling
    if doTools {
        print("\n  Tool calling (temp=0.2):")
        result.toolCalling = try await engine.runToolCallingTest(temperature: 0.2)
    }

    await engine.unload()
    return result
}

func run() async throws {
    let args = parseArgs()

    let doThroughput = args.doThroughput || args.runAllDimensions
    let doNoThink = args.doNoThink || args.runAllDimensions
    let doRAM = args.doRAM || args.runAllDimensions
    let doTools = args.doTools || args.runAllDimensions

    // Determine models to benchmark
    let modelList: [ModelEntry]
    if let shortName = args.modelShortName {
        if let entry = models.first(where: { $0.shortName == shortName }) {
            modelList = [entry]
        } else if let entry = models.first(where: { $0.modelID == shortName }) {
            modelList = [entry]
        } else {
            print("Unknown model: \(shortName)")
            print("Available: \(models.map(\.shortName).joined(separator: ", "))")
            exit(1)
        }
    } else if args.runAll {
        modelList = models
    } else if args.qwen3Only {
        modelList = models.filter { !$0.shortName.hasPrefix("qwen3.5") }
    } else if args.qwen35Only {
        modelList = models.filter { $0.shortName.hasPrefix("qwen3.5") }
    } else {
        printUsage()
        exit(1)
    }

    print("FaeBenchmark — \(modelList.count) model(s)")
    print("Hardware: \(ProcessInfo.processInfo.machineArchitecture), \(systemRAMGB()) GB RAM")
    print("Backend: mlx-swift-lm (native Swift)")
    print("Dimensions: throughput=\(doThroughput), no_think=\(doNoThink), ram=\(doRAM), tools=\(doTools)")

    var benchmarks: [ModelBenchmarkResult] = []
    for entry in modelList {
        do {
            let result = try await benchmarkModel(
                modelID: entry.modelID,
                shortName: entry.shortName,
                doThroughput: doThroughput,
                doNoThink: doNoThink,
                doRAM: doRAM,
                doTools: doTools
            )
            benchmarks.append(result)
        } catch {
            print("\n  ERROR benchmarking \(entry.shortName): \(error)")
        }
    }

    guard !benchmarks.isEmpty else {
        print("\nNo benchmarks completed.")
        exit(1)
    }

    // JSON output
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    let output = BenchmarkOutput(
        hardware: .init(arch: ProcessInfo.processInfo.machineArchitecture, ramGB: systemRAMGB()),
        date: dateFormatter.string(from: Date()),
        backend: "mlx-swift-lm",
        models: benchmarks
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(output)

    let outputPath = args.outputPath ?? "scripts/mlx_benchmark_results.json"
    try jsonData.write(to: URL(fileURLWithPath: outputPath))
    print("\nJSON results saved to: \(outputPath)")

    // Markdown output
    let md = resultsToMarkdown(benchmarks)
    if let markdownPath = args.markdownPath {
        try md.write(toFile: markdownPath, atomically: true, encoding: .utf8)
        print("Markdown results saved to: \(markdownPath)")
    } else {
        print("\n" + String(repeating: "=", count: 70))
        print("MARKDOWN OUTPUT")
        print(String(repeating: "=", count: 70))
        print(md)
    }
}

// MARK: - ProcessInfo Extension

extension ProcessInfo {
    var machineArchitecture: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { buf in
            String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

// MARK: - Entry Point

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        try await run()
    } catch {
        print("Fatal error: \(error)")
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
