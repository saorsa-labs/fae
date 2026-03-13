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
    ModelEntry(shortName: "qwen3.5-0.8b", modelID: "mlx-community/Qwen3.5-0.8B-4bit"),
    ModelEntry(shortName: "qwen3.5-2b", modelID: "mlx-community/Qwen3.5-2B-4bit"),
    ModelEntry(shortName: "qwen3.5-4b", modelID: "mlx-community/Qwen3.5-4B-4bit"),
    ModelEntry(shortName: "qwen3.5-9b", modelID: "mlx-community/Qwen3.5-9B-4bit"),
    // NexVeridian text-only conversions (vision tower stripped).
    // mlx-community versions are VL — incompatible with text-only loading.
    ModelEntry(shortName: "qwen3.5-35b-a3b", modelID: "mlx-community/Qwen3.5-35B-A3B-4bit"),
    ModelEntry(shortName: "qwen3.5-27b", modelID: "mlx-community/Qwen3.5-27B-4bit"),
    ModelEntry(
        shortName: "qwen3.5-27b-opus-distilled",
        modelID: "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"
    ),
]

func usesQwenCompatibleToolCallFormat(modelID: String) -> Bool {
    let lower = modelID.lowercased()
    return lower.contains("qwen")
        || lower.contains("saorsa1-worker")
        || lower.contains("saorsa1-tiny")
}

// MARK: - Result Types

struct ThroughputResult: Codable {
    let contextLabel: String
    let promptTokens: Int
    let generatedTokens: Int
    let visibleChars: Int
    let thinkingChars: Int
    let wallTimeS: Double
    let firstTokenLatencyMS: Double
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
        case firstTokenLatencyMS = "first_token_latency_ms"
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
    let toolCallSource: String
    let rawResponsePreview: String
    let correct: Bool
    let temperature: Float

    enum CodingKeys: String, CodingKey {
        case prompt
        case expectedTool = "expected_tool"
        case actualTool = "actual_tool"
        case toolCallSource = "tool_call_source"
        case rawResponsePreview = "raw_response_preview"
        case correct
        case temperature
    }
}

struct IntelligenceEvalResult: Codable {
    let category: String
    let prompt: String
    let expectedAnswer: String
    let actualAnswer: String
    let correct: Bool
    let firstTokenLatencyMS: Double
    let wallTimeS: Double

    enum CodingKeys: String, CodingKey {
        case category
        case prompt
        case expectedAnswer = "expected_answer"
        case actualAnswer = "actual_answer"
        case correct
        case firstTokenLatencyMS = "first_token_latency_ms"
        case wallTimeS = "wall_time_s"
    }
}

struct SerializationEvalResult: Codable {
    let format: String
    let task: String
    let prompt: String
    let expectedFields: [String: String]
    let actualFields: [String: String]
    let rawOutput: String
    let valid: Bool
    let correct: Bool
    let firstTokenLatencyMS: Double
    let wallTimeS: Double

    enum CodingKeys: String, CodingKey {
        case format
        case task
        case prompt
        case expectedFields = "expected_fields"
        case actualFields = "actual_fields"
        case rawOutput = "raw_output"
        case valid
        case correct
        case firstTokenLatencyMS = "first_token_latency_ms"
        case wallTimeS = "wall_time_s"
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
    var intelligenceEval: [IntelligenceEvalResult]
    var faeCapabilityEval: [IntelligenceEvalResult]
    var assistantFitEval: [IntelligenceEvalResult]
    var freeformEval: [FreeformEvalResult]
    var serializationEval: [SerializationEvalResult]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelShort = "model_short"
        case idleRAMMB = "idle_ram_mb"
        case throughputNoThink = "throughput_no_think"
        case throughputThinkOn = "throughput_think_on"
        case noThinkCompliance = "no_think_compliance"
        case toolCalling = "tool_calling"
        case intelligenceEval = "intelligence_eval"
        case faeCapabilityEval = "fae_capability_eval"
        case assistantFitEval = "assistant_fit_eval"
        case freeformEval = "freeform_eval"
        case serializationEval = "serialization_eval"
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

// Tool calling system prompt — close to Fae's production guidance.
// Native tool specs are passed via UserInput.tools so the model's chat template
// can select the right output format for its family.
let toolCallingSystemPrompt = """
/no_think

You are Fae, a personal AI companion running on macOS. When the user's request requires a tool, \
call the appropriate tool. For simple conversation, just respond directly without tools.

Tool usage:
- Calendar, reminders, mail, contacts, notes queries: ALWAYS call the relevant tool. Do NOT answer from memory.
- Real-time data, file access, and web lookups: use the appropriate tool.
- If tools are provided, call them using the model's native tool-calling format.
- Qwen-family models may emit XML function calls.
- Liquid-family models may emit special-token or Pythonic tool calls.
- After a tool result, respond naturally in spoken language.
- For simple conversation, just respond directly without tools.
- Keep spoken responses concise (1-4 sentences).
- NEVER expose raw tool call markup, JSON, or code to the user.
"""

let toolCallingNativeTools: [[String: any Sendable]] = [
    [
        "type": "function",
        "function": [
            "name": "calendar",
            "description": "Access macOS Calendar events.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "One of list_today, list_week, list_date, create, search.",
                    ] as [String: String],
                    "query": ["type": "string"] as [String: String],
                    "date": ["type": "string"] as [String: String],
                ] as [String: Any],
                "required": ["action"],
            ] as [String: Any],
        ] as [String: Any],
    ],
    [
        "type": "function",
        "function": [
            "name": "reminders",
            "description": "Access macOS Reminders.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "One of list_incomplete, create, complete, search.",
                    ] as [String: String],
                    "title": ["type": "string"] as [String: String],
                    "query": ["type": "string"] as [String: String],
                ] as [String: Any],
                "required": ["action"],
            ] as [String: Any],
        ] as [String: Any],
    ],
    [
        "type": "function",
        "function": [
            "name": "contacts",
            "description": "Search macOS Contacts.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "One of search, get_phone, get_email.",
                    ] as [String: String],
                    "query": ["type": "string"] as [String: String],
                ] as [String: Any],
                "required": ["action", "query"],
            ] as [String: Any],
        ] as [String: Any],
    ],
    [
        "type": "function",
        "function": [
            "name": "mail",
            "description": "Interact with macOS Mail.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "One of check_inbox, read_recent, send.",
                    ] as [String: String],
                    "to": ["type": "string"] as [String: String],
                    "body": ["type": "string"] as [String: String],
                    "count": ["type": "integer"] as [String: String],
                ] as [String: Any],
                "required": ["action"],
            ] as [String: Any],
        ] as [String: Any],
    ],
    [
        "type": "function",
        "function": [
            "name": "notes",
            "description": "Access macOS Notes.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "One of list_recent, create, search.",
                    ] as [String: String],
                    "title": ["type": "string"] as [String: String],
                    "body": ["type": "string"] as [String: String],
                    "query": ["type": "string"] as [String: String],
                ] as [String: Any],
                "required": ["action"],
            ] as [String: Any],
        ] as [String: Any],
    ],
    [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "Search the web and return titles, snippets, and URLs.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"] as [String: String],
                    "max_results": ["type": "integer"] as [String: String],
                ] as [String: Any],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
    ],
    [
        "type": "function",
        "function": [
            "name": "read",
            "description": "Read the contents of a file from the filesystem.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"] as [String: String],
                ] as [String: Any],
                "required": ["path"],
            ] as [String: Any],
        ] as [String: Any],
    ],
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

// Additional MCQ eval suites live in EvalSuites.swift.

// MARK: - Benchmark Engine

actor BenchmarkEngine {
    private var container: ModelContainer?
    private let modelID: String
    private let shortName: String
    private let qwenCalibrated: Bool

    init(modelID: String, shortName: String, qwenCalibrated: Bool = false) {
        self.modelID = modelID
        self.shortName = shortName
        self.qwenCalibrated = qwenCalibrated
    }

    private var useQwenCalibratedPrompts: Bool {
        qwenCalibrated && (shortName.lowercased().contains("qwen") || modelID.lowercased().contains("qwen"))
    }

    func load() async throws {
        print("  Loading \(shortName) (\(modelID))...")
        var config = ModelConfiguration(id: modelID)
        if usesQwenCompatibleToolCallFormat(modelID: modelID) {
            config.toolCallFormat = .xmlFunction
            print("  Using xmlFunction tool-call parser.")
        }
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
        let firstTokenLatencyMS: Double
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
        var firstTokenLatencyMS: Double?
        var genTPS: Double = 0
        var promptTPS: Double = 0
        var capturedToolCalls: [ToolCall] = []

        for await generation in stream {
            switch generation {
            case .chunk(let text):
                if firstTokenLatencyMS == nil, !text.isEmpty {
                    firstTokenLatencyMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
                }
                fullText += text
            case .info(let info):
                promptTokens = info.promptTokenCount
                genTokens = info.generationTokenCount
                genTPS = info.tokensPerSecond
                promptTPS = info.promptTokensPerSecond
            case .toolCall(let call):
                if firstTokenLatencyMS == nil {
                    firstTokenLatencyMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
                }
                capturedToolCalls.append(call)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return GenerateResult(
            text: fullText,
            promptTokens: promptTokens,
            genTokens: genTokens,
            wallTime: elapsed,
            firstTokenLatencyMS: firstTokenLatencyMS ?? (elapsed * 1000),
            genTPS: genTPS,
            promptTPS: promptTPS,
            toolCalls: capturedToolCalls
        )
    }

    // MARK: - Throughput Sweep

    func runContextSweep(thinkMode: String, contexts: Set<String> = []) async throws -> [ThroughputResult] {
        let system: String
        if thinkMode == "no_think" {
            system = "/no_think\n\nYou are a helpful assistant. Be concise."
        } else {
            system = "You are a helpful assistant. Be concise."
        }

        let filler = buildFillerText(targetWords: 6500)
        let words = filler.split(separator: " ")

        let allTests: [(key: String, label: String, userPrompt: String, maxTokens: Int)] = [
            ("short", "Short (~20 tok)", "What is the weather like today?", 128),
            ("200", "~200 tok ctx", words.prefix(150).joined(separator: " ") + " Summarize.", 256),
            ("500", "~500 tok ctx", words.prefix(350).joined(separator: " ") + " Summarize.", 256),
            ("1k", "~1K tok ctx", words.prefix(750).joined(separator: " ") + " Summarize.", 256),
            ("2k", "~2K tok ctx", words.prefix(1500).joined(separator: " ") + " Summarize.", 256),
            ("4k", "~4K tok ctx", words.prefix(3000).joined(separator: " ") + " Summarize.", 256),
            ("8.5k", "~8.5K tok", filler + " Given all of this context, what are the three most important developments?", 256),
        ]
        let tests = contexts.isEmpty ? allTests : allTests.filter { contexts.contains($0.key) }

        var results: [ThroughputResult] = []
        for (_, label, userPrompt, maxTokens) in tests {
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
                        firstTokenLatencyMS: (result.firstTokenLatencyMS * 10).rounded() / 10,
                        tokensPerSecond: (tps * 10).rounded() / 10,
                        promptTokensPerSecond: (result.promptTPS * 10).rounded() / 10,
                        ramMB: ram.rounded()
                    )
                }
            }

            if let r = bestResult {
                print(" \(Int(r.firstTokenLatencyMS)) ms TTFT, \(r.tokensPerSecond) T/s (gen), \(r.promptTokensPerSecond) T/s (prompt), \(Int(r.ramMB)) MB")
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

    // MARK: - General Intelligence

    private func runMCQEval(_ questions: [MCQQuestion], label: String) async throws -> [IntelligenceEvalResult] {
        var results: [IntelligenceEvalResult] = []

        for test in questions {
            print("    \(label) [\(test.category)]: \(test.prompt.prefix(42).replacingOccurrences(of: "\n", with: " "))...", terminator: "")
            fflush(stdout)

            let promptConfig = mcqPromptConfig(question: test, qwenCalibrated: useQwenCalibratedPrompts)
            var result = try await generate(
                system: promptConfig.system,
                user: promptConfig.user,
                maxTokens: promptConfig.maxTokens,
                temperature: 0.0
            )

            var actual = extractChoiceLetter(from: result.text)
            if useQwenCalibratedPrompts && actual == "?" {
                result = try await generate(
                    system: promptConfig.system,
                    user: promptConfig.user + "\n\nReminder: keep generating until you emit a final <answer>X</answer> tag.",
                    maxTokens: max(promptConfig.maxTokens * 4, 192),
                    temperature: 0.0
                )
                actual = extractChoiceLetter(from: result.text)
            }

            let correct = actual == test.answer
            print(" \(correct ? "OK" : "MISS") expected=\(test.answer) got=\(actual)")

            results.append(IntelligenceEvalResult(
                category: test.category,
                prompt: test.prompt,
                expectedAnswer: test.answer,
                actualAnswer: actual,
                correct: correct,
                firstTokenLatencyMS: (result.firstTokenLatencyMS * 10).rounded() / 10,
                wallTimeS: (result.wallTime * 100).rounded() / 100
            ))
        }

        return results
    }

    func runIntelligenceEval() async throws -> [IntelligenceEvalResult] {
        try await runMCQEval(mmluMiniQuestions, label: "MMLU-mini")
    }

    func runFaeCapabilityEval() async throws -> [IntelligenceEvalResult] {
        try await runMCQEval(faeCapabilityQuestions, label: "Fae-cap")
    }

    func runAssistantFitEval() async throws -> [IntelligenceEvalResult] {
        try await runMCQEval(assistantFitQuestions, label: "Assistant-fit")
    }

    func runFreeformEval() async throws -> [FreeformEvalResult] {
        var results: [FreeformEvalResult] = []

        for test in freeformEvalCases {
            print("    Freeform [\(test.category)]: \(test.id)...", terminator: "")
            fflush(stdout)

            let promptConfig = freeformPromptConfig(test: test, qwenCalibrated: useQwenCalibratedPrompts)
            let result = try await generate(
                system: promptConfig.system,
                user: promptConfig.user,
                maxTokens: promptConfig.maxTokens,
                temperature: 0.0
            )

            let evaluation = evaluateFreeformOutput(result.text, checks: test.checks)
            print(" \(evaluation.correct ? "OK" : "MISS") checks=\(test.checks.count - evaluation.failures.count)/\(test.checks.count) words=\(evaluation.wordCount)")

            results.append(FreeformEvalResult(
                caseID: test.id,
                category: test.category,
                prompt: test.prompt,
                rawOutput: result.text,
                failedChecks: evaluation.failures,
                passedChecks: test.checks.count - evaluation.failures.count,
                totalChecks: test.checks.count,
                wordCount: evaluation.wordCount,
                correct: evaluation.correct,
                firstTokenLatencyMS: (result.firstTokenLatencyMS * 10).rounded() / 10,
                wallTimeS: (result.wallTime * 100).rounded() / 100
            ))
        }

        return results
    }

    func runSerializationEval() async throws -> [SerializationEvalResult] {
        var results: [SerializationEvalResult] = []

        for test in serializationEvalCases {
            print("    Ser [\(test.format)]: \(test.task)...", terminator: "")
            fflush(stdout)

            let promptConfig = serializationPromptConfig(test: test, qwenCalibrated: useQwenCalibratedPrompts)
            var result = try await generate(
                system: promptConfig.system,
                user: promptConfig.user,
                maxTokens: promptConfig.maxTokens,
                temperature: 0.0
            )

            var actualFields = parseStructuredFields(from: result.text, format: test.format)
            var normalizedActual = normalizeFields(actualFields)
            let normalizedExpected = normalizeFields(test.expectedFields)
            if useQwenCalibratedPrompts && normalizedActual.isEmpty {
                result = try await generate(
                    system: promptConfig.system,
                    user: promptConfig.user + "\n\nReminder: keep generating until the full payload is complete and closed.",
                    maxTokens: max(promptConfig.maxTokens * 2, 512),
                    temperature: 0.0
                )
                actualFields = parseStructuredFields(from: result.text, format: test.format)
                normalizedActual = normalizeFields(actualFields)
            }

            let valid = !normalizedActual.isEmpty
            let correct = normalizedActual == normalizedExpected
            print(" \(correct ? "OK" : "MISS") valid=\(valid ? "yes" : "no")")

            results.append(SerializationEvalResult(
                format: test.format,
                task: test.task,
                prompt: test.prompt,
                expectedFields: test.expectedFields,
                actualFields: actualFields,
                rawOutput: result.text,
                valid: valid,
                correct: correct,
                firstTokenLatencyMS: (result.firstTokenLatencyMS * 10).rounded() / 10,
                wallTimeS: (result.wallTime * 100).rounded() / 100
            ))
        }

        return results
    }

    // MARK: - Tool Calling

    func runToolCallingTest(temperature: Float = 0.0) async throws -> [ToolCallResult] {
        let system = toolCallingSystemPrompt
        let validTools = Set(["calendar", "reminders", "contacts", "mail", "notes",
                              "web_search", "read", "write", "bash"])

        var results: [ToolCallResult] = []
        for test in toolCallTests {
            print("    Tool test: \(test.prompt.prefix(50))...", terminator: "")
            fflush(stdout)

            let toolResult = try await generate(
                system: system,
                user: test.prompt,
                maxTokens: 512,
                temperature: temperature,
                tools: toolCallingNativeTools
            )
            let output = toolResult.text

            var actual = "none"
            var toolCallSource = "none"
            let rawResponsePreview = String(output.prefix(300)).replacingOccurrences(of: "\n", with: "\\n")

            // 1. Check for library-parsed .toolCall events (native path)
            if let firstCall = toolResult.toolCalls.first {
                let name = firstCall.function.name
                // Map web_search back to web_search for comparison
                actual = name == "web_search" ? "web_search" : name
                toolCallSource = "native_tool_event"
            }

            // 2. Fallback: check raw text for <tool_call> tags (in case library didn't parse)
            if actual == "none" && output.contains("<tool_call>") {
                if let nameRange = output.range(of: #""name"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                    let match = output[nameRange]
                    if let valueRange = match.range(of: #""([^"]+)"$"#, options: .regularExpression) {
                        let candidate = String(match[valueRange]).replacingOccurrences(of: "\"", with: "")
                        let mapped = candidate == "web_search" ? "web_search" : candidate
                        if validTools.contains(candidate) {
                            actual = mapped
                            toolCallSource = "raw_tool_call_json"
                        }
                    }
                }
            }

            // 3. Fallback: Qwen XML tool-call format.
            if actual == "none" {
                if let functionRange = output.range(of: #"<function=([A-Za-z_][A-Za-z0-9_]*)>"#, options: .regularExpression) {
                    let captured = output[functionRange]
                    let candidate = String(captured)
                        .replacingOccurrences(of: "<function=", with: "")
                        .replacingOccurrences(of: ">", with: "")
                    if validTools.contains(candidate) {
                        actual = candidate
                        toolCallSource = "raw_qwen_xml"
                    }
                }
            }

            // 4. Fallback: Liquid Pythonic/special-token tool-call format.
            if actual == "none" {
                if let functionRange = output.range(of: #"<\|tool_call_start\|>\s*\[\s*([A-Za-z_][A-Za-z0-9_]*)\("#, options: .regularExpression) {
                    let captured = output[functionRange]
                    if let nameRange = String(captured).range(of: #"[A-Za-z_][A-Za-z0-9_]*(?=\()"#, options: .regularExpression) {
                        let candidate = String(String(captured)[nameRange])
                        if validTools.contains(candidate) {
                            actual = candidate
                            toolCallSource = "raw_liquid_pythonic"
                        }
                    }
                }
            }

            // 5. Fallback: loose JSON-ish name field in raw text.
            if actual == "none" {
                if let nameMatch = output.range(of: #"["']name["']\s*:\s*["'](\w+)["']"#, options: .regularExpression) {
                    let captured = output[nameMatch]
                    if let valRange = captured.range(of: #"["'](\w+)["']$"#, options: .regularExpression) {
                        let candidate = String(captured[valRange])
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        if validTools.contains(candidate) {
                            actual = candidate
                            toolCallSource = "raw_name_field"
                        }
                    }
                }
            }

            let correct = actual == test.expectedTool
            print(" \(correct ? "OK" : "MISS") (expected=\(test.expectedTool), got=\(actual))")
            if !correct && test.expectedTool != "none" {
                let nativeCount = toolResult.toolCalls.count
                print("      Native .toolCall events: \(nativeCount)")
                print("      Tool source: \(toolCallSource)")
                print("      Response: \(rawResponsePreview)")
            }

            results.append(ToolCallResult(
                prompt: test.prompt,
                expectedTool: test.expectedTool,
                actualTool: actual,
                toolCallSource: toolCallSource,
                rawResponsePreview: rawResponsePreview,
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
    var qwenCalibrated = false
    var doThroughput = false
    var doNoThink = false
    var doRAM = false
    var doTools = false
    var doIntelligence = false
    var doFaeCapabilities = false
    var doAssistantFit = false
    var doFreeform = false
    var doSerialization = false
    var contexts: [String] = []
    var outputPath: String?
    var markdownPath: String?

    var runAllDimensions: Bool {
        !doThroughput && !doNoThink && !doRAM && !doTools && !doIntelligence && !doFaeCapabilities && !doAssistantFit && !doFreeform && !doSerialization
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
        case "--qwen-calibrated":
            args.qwenCalibrated = true
        case "--intelligence", "--mmlu-mini":
            args.doIntelligence = true
        case "--fae-capabilities":
            args.doFaeCapabilities = true
        case "--assistant-fit", "--fae-priority":
            args.doAssistantFit = true
        case "--freeform", "--assistant-freeform":
            args.doFreeform = true
        case "--serialization", "--formats":
            args.doSerialization = true
        case "--contexts":
            i += 1
            if i < argv.count {
                args.contexts = argv[i]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            }
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
      qwen3.5-0.8b, qwen3.5-2b, qwen3.5-4b, qwen3.5-9b,
      qwen3.5-27b, qwen3.5-27b-opus-distilled, qwen3.5-35b-a3b

    Dimensions (default: all):
      --throughput       Run throughput benchmark (7 context sizes x 2 modes)
      --no-think         Run /no_think compliance test
      --ram              Measure idle RAM usage
      --tools            Run tool calling accuracy test
      --qwen-calibrated  Use temporary Qwen-specific prompt calibration for evals
      --intelligence     Run MMLU-style mini MCQ eval (alias: --mmlu-mini)
      --fae-capabilities Run Fae-specific capability MCQ eval
      --assistant-fit    Run Fae-priority assistant-fit MCQ eval (alias: --fae-priority)
      --freeform         Run the comprehensive freeform assistant eval (~250 cases)
      --serialization    Run structured output eval across JSON/XML/YAML (alias: --formats)
      --contexts         Comma-separated context keys: short,200,500,1k,2k,4k,8.5k

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

    let hasIntelligence = benchmarks.contains(where: { !$0.intelligenceEval.isEmpty })
    if hasIntelligence {
        lines.append("### General Intelligence (MMLU-style mini MCQ)")
        lines.append("")
        lines.append("| Model | Correct | Total | Accuracy |")
        lines.append("|---|---:|---:|---:|")
        for b in benchmarks where !b.intelligenceEval.isEmpty {
            let correct = b.intelligenceEval.filter(\.correct).count
            let total = b.intelligenceEval.count
            let pct = total > 0 ? Int(round(Double(correct) / Double(total) * 100)) : 0
            lines.append("| \(b.modelShort) | \(correct) | \(total) | \(pct)% |")
        }
        lines.append("")
    }

    let hasFaeCapabilities = benchmarks.contains(where: { !$0.faeCapabilityEval.isEmpty })
    if hasFaeCapabilities {
        lines.append("### Fae-specific Capability Eval")
        lines.append("")
        lines.append("| Model | Correct | Total | Accuracy |")
        lines.append("|---|---:|---:|---:|")
        for b in benchmarks where !b.faeCapabilityEval.isEmpty {
            let correct = b.faeCapabilityEval.filter(\.correct).count
            let total = b.faeCapabilityEval.count
            let pct = total > 0 ? Int(round(Double(correct) / Double(total) * 100)) : 0
            lines.append("| \(b.modelShort) | \(correct) | \(total) | \(pct)% |")
        }
        lines.append("")
    }

    let hasAssistantFit = benchmarks.contains(where: { !$0.assistantFitEval.isEmpty })
    if hasAssistantFit {
        lines.append("### Fae-priority Assistant Fit Eval")
        lines.append("")
        lines.append("| Model | Tool judgment | Strict instruction | Memory discipline | Tool result handling | Overall |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        for b in benchmarks where !b.assistantFitEval.isEmpty {
            func pct(_ category: String) -> Int {
                let rows = b.assistantFitEval.filter { $0.category == category }
                guard !rows.isEmpty else { return 0 }
                let correct = rows.filter(\.correct).count
                return Int(round(Double(correct) / Double(rows.count) * 100))
            }
            let overall = Int(round(Double(b.assistantFitEval.filter(\.correct).count) / Double(b.assistantFitEval.count) * 100))
            lines.append("| \(b.modelShort) | \(pct("tool_judgment"))% | \(pct("instruction_following_strict"))% | \(pct("memory_discipline"))% | \(pct("tool_result_handling"))% | \(overall)% |")
        }
        lines.append("")
    }

    let hasFreeform = benchmarks.contains(where: { !$0.freeformEval.isEmpty })
    if hasFreeform {
        lines.append("### Freeform Assistant Eval")
        lines.append("")
        lines.append("| Model | Overall | By category |")
        lines.append("|---|---:|---|")
        for b in benchmarks where !b.freeformEval.isEmpty {
            let overall = Int(round(Double(b.freeformEval.filter(\.correct).count) / Double(b.freeformEval.count) * 100))
            let byCategory = freeformEvalCategoryOrder.compactMap { category -> String? in
                let rows = b.freeformEval.filter { $0.category == category }
                guard !rows.isEmpty else { return nil }
                let correct = rows.filter(\.correct).count
                let pct = Int(round(Double(correct) / Double(rows.count) * 100))
                return "\(freeformEvalCategoryLabels[category] ?? category) \(pct)%"
            }.joined(separator: ", ")
            lines.append("| \(b.modelShort) | \(overall)% | \(byCategory) |")
        }
        lines.append("")
    }

    let hasSerialization = benchmarks.contains(where: { !$0.serializationEval.isEmpty })
    if hasSerialization {
        lines.append("### Structured Serialization Eval")
        lines.append("")
        lines.append("| Model | JSON | XML | YAML | Overall |")
        lines.append("|---|---:|---:|---:|---:|")
        for b in benchmarks where !b.serializationEval.isEmpty {
            func pct(_ format: String) -> Int {
                let rows = b.serializationEval.filter { $0.format == format }
                guard !rows.isEmpty else { return 0 }
                let correct = rows.filter(\.correct).count
                return Int(round(Double(correct) / Double(rows.count) * 100))
            }
            let overall = Int(round(Double(b.serializationEval.filter(\.correct).count) / Double(b.serializationEval.count) * 100))
            lines.append("| \(b.modelShort) | \(pct("json"))% | \(pct("xml"))% | \(pct("yaml"))% | \(overall)% |")
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
    doTools: Bool,
    doIntelligence: Bool,
    doFaeCapabilities: Bool,
    doAssistantFit: Bool,
    doFreeform: Bool,
    doSerialization: Bool,
    qwenCalibrated: Bool = false,
    contexts: Set<String> = []
) async throws -> ModelBenchmarkResult {
    print("\n" + String(repeating: "=", count: 70))
    print("  \(shortName) (\(modelID))")
    print(String(repeating: "=", count: 70))

    let engine = BenchmarkEngine(modelID: modelID, shortName: shortName, qwenCalibrated: qwenCalibrated)
    try await engine.load()

    var result = ModelBenchmarkResult(
        modelID: modelID,
        modelShort: shortName,
        idleRAMMB: 0,
        throughputNoThink: [],
        throughputThinkOn: [],
        noThinkCompliance: [],
        toolCalling: [],
        intelligenceEval: [],
        faeCapabilityEval: [],
        assistantFitEval: [],
        freeformEval: [],
        serializationEval: []
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
        result.throughputNoThink = try await engine.runContextSweep(thinkMode: "no_think", contexts: contexts)

        print("\n  Throughput (thinking ON):")
        result.throughputThinkOn = try await engine.runContextSweep(thinkMode: "think_on", contexts: contexts)
    }

    // /no_think compliance
    if doNoThink {
        print("\n  /no_think compliance:")
        result.noThinkCompliance = try await engine.runNoThinkTest()
    }

    // Tool calling
    if doTools {
        print("\n  Tool calling (temp=0.0):")
        result.toolCalling = try await engine.runToolCallingTest(temperature: 0.0)
    }

    // MMLU-style mini eval
    if doIntelligence {
        print("\n  General intelligence (MMLU-style mini MCQ):")
        result.intelligenceEval = try await engine.runIntelligenceEval()
    }

    // Fae-specific capability eval
    if doFaeCapabilities {
        print("\n  Fae-specific capability eval:")
        result.faeCapabilityEval = try await engine.runFaeCapabilityEval()
    }

    // Fae-priority assistant-fit eval
    if doAssistantFit {
        print("\n  Fae-priority assistant-fit eval:")
        result.assistantFitEval = try await engine.runAssistantFitEval()
    }

    if doFreeform {
        print("\n  Freeform assistant eval:")
        result.freeformEval = try await engine.runFreeformEval()
    }

    // Structured serialization eval
    if doSerialization {
        print("\n  Structured serialization eval:")
        result.serializationEval = try await engine.runSerializationEval()
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
    let doIntelligence = args.doIntelligence || args.runAllDimensions
    let doFaeCapabilities = args.doFaeCapabilities || args.runAllDimensions
    let doAssistantFit = args.doAssistantFit || args.runAllDimensions
    let doFreeform = args.doFreeform
    let doSerialization = args.doSerialization || args.runAllDimensions

    // Determine models to benchmark
    let modelList: [ModelEntry]
    if let shortName = args.modelShortName {
        if let entry = models.first(where: { $0.shortName == shortName }) {
            modelList = [entry]
        } else if let entry = models.first(where: { $0.modelID == shortName }) {
            modelList = [entry]
        } else if shortName.contains("/") {
            let derivedShortName = shortName
                .split(separator: "/")
                .last
                .map(String.init) ?? shortName
            modelList = [ModelEntry(shortName: derivedShortName, modelID: shortName)]
        } else {
            print("Unknown model: \(shortName)")
            print("Available: \(models.map(\.shortName).joined(separator: ", "))")
            print("Or pass a full Hugging Face model ID like org/model-name")
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

    let contextFilter = Set(args.contexts)

    print("FaeBenchmark — \(modelList.count) model(s)")
    print("Hardware: \(ProcessInfo.processInfo.machineArchitecture), \(systemRAMGB()) GB RAM")
    print("Backend: mlx-swift-lm (native Swift)")
    print("Dimensions: throughput=\(doThroughput), no_think=\(doNoThink), ram=\(doRAM), tools=\(doTools), intelligence=\(doIntelligence), fae_capabilities=\(doFaeCapabilities), assistant_fit=\(doAssistantFit), freeform=\(doFreeform), serialization=\(doSerialization)")
    if args.qwenCalibrated {
        print("Eval profile: temporary Qwen-calibrated prompts enabled")
    }
    if !contextFilter.isEmpty {
        print("Contexts: \(contextFilter.sorted().joined(separator: ", "))")
    }

    var benchmarks: [ModelBenchmarkResult] = []
    for entry in modelList {
        do {
            let result = try await benchmarkModel(
                modelID: entry.modelID,
                shortName: entry.shortName,
                doThroughput: doThroughput,
                doNoThink: doNoThink,
                doRAM: doRAM,
                doTools: doTools,
                doIntelligence: doIntelligence,
                doFaeCapabilities: doFaeCapabilities,
                doAssistantFit: doAssistantFit,
                doFreeform: doFreeform,
                doSerialization: doSerialization,
                qwenCalibrated: args.qwenCalibrated,
                contexts: contextFilter
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
