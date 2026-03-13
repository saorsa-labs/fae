import AppKit
import CoreGraphics
import CoreImage
import Foundation
import MLXLMCommon
import MLXVLM

struct ModelEntry {
    let shortName: String
    let modelID: String
}

let models: [ModelEntry] = [
    ModelEntry(shortName: "qwen3-vl-4b-4bit", modelID: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit"),
    ModelEntry(shortName: "qwen3-vl-4b-8bit", modelID: "mlx-community/Qwen3-VL-4B-Instruct-8bit"),
    ModelEntry(shortName: "qwen3.5-2b", modelID: "mlx-community/Qwen3.5-2B-4bit"),
    ModelEntry(shortName: "qwen3.5-4b", modelID: "mlx-community/Qwen3.5-4B-4bit"),
    ModelEntry(shortName: "qwen3.5-9b", modelID: "mlx-community/Qwen3.5-9B-4bit"),
    ModelEntry(shortName: "qwen3.5-27b", modelID: "mlx-community/Qwen3.5-27B-4bit"),
    ModelEntry(shortName: "qwen3.5-35b-a3b", modelID: "mlx-community/Qwen3.5-35B-A3B-4bit"),
]

enum MockSceneKind: String, Codable {
    case terminalError
    case calendarDay
    case browserHeadline
    case mailDraft
    case notesList
    case xcodeWorkspace
}

struct PerceptionCase {
    let id: String
    let category: String
    let scene: MockSceneKind
    let prompt: String
    let keywordGroups: [[String]]
    let minMatchedGroups: Int
    let maxTokens: Int
}

struct PerceptionEvalResult: Codable {
    let id: String
    let category: String
    let scene: String
    let prompt: String
    let expectedKeywordGroups: [[String]]
    let matchedKeywords: [String]
    let matchedGroupCount: Int
    let minMatchedGroups: Int
    let response: String
    let correct: Bool
    let firstTokenLatencyMS: Double
    let wallTimeS: Double

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case scene
        case prompt
        case expectedKeywordGroups = "expected_keyword_groups"
        case matchedKeywords = "matched_keywords"
        case matchedGroupCount = "matched_group_count"
        case minMatchedGroups = "min_matched_groups"
        case response
        case correct
        case firstTokenLatencyMS = "first_token_latency_ms"
        case wallTimeS = "wall_time_s"
    }
}

struct ModelPerceptionBenchmarkResult: Codable {
    let modelID: String
    let modelShort: String
    let idleRAMMB: Double
    let loadSucceeded: Bool
    let loadError: String?
    let results: [PerceptionEvalResult]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelShort = "model_short"
        case idleRAMMB = "idle_ram_mb"
        case loadSucceeded = "load_succeeded"
        case loadError = "load_error"
        case results
    }
}

struct BenchmarkOutput: Codable {
    let hardware: Hardware
    let date: String
    let backend: String
    let models: [ModelPerceptionBenchmarkResult]

    struct Hardware: Codable {
        let arch: String
        let ramGB: Int

        enum CodingKeys: String, CodingKey {
            case arch
            case ramGB = "ram_gb"
        }
    }
}

struct GenerationResult {
    let text: String
    let firstTokenLatencyMS: Double
    let wallTime: Double
}

let perceptionCases: [PerceptionCase] = [
    PerceptionCase(
        id: "terminal_error",
        category: "screen_grounding",
        scene: .terminalError,
        prompt: "What build error is visible? Answer in one sentence.",
        keywordGroups: [["cannot find", "not found"], ["foo"], ["scope"]],
        minMatchedGroups: 2,
        maxTokens: 80
    ),
    PerceptionCase(
        id: "calendar_summary",
        category: "screen_grounding",
        scene: .calendarDay,
        prompt: "Summarize today's calendar in one sentence.",
        keywordGroups: [["design"], ["lunch", "sam"], ["dentist"]],
        minMatchedGroups: 2,
        maxTokens: 96
    ),
    PerceptionCase(
        id: "browser_headline",
        category: "screen_summary",
        scene: .browserHeadline,
        prompt: "What is the main headline and what is it about?",
        keywordGroups: [["apple"], ["battery", "macbook"], ["compile", "developers"]],
        minMatchedGroups: 2,
        maxTokens: 96
    ),
    PerceptionCase(
        id: "mail_draft",
        category: "screen_detail",
        scene: .mailDraft,
        prompt: "Who is this email to, and what meeting time is proposed?",
        keywordGroups: [["alex@example.com", "alex"], ["thursday"], ["3 pm", "3pm", "3:00"]],
        minMatchedGroups: 2,
        maxTokens: 96
    ),
    PerceptionCase(
        id: "notes_summary",
        category: "screen_summary",
        scene: .notesList,
        prompt: "Give a brief summary of the visible to-do list.",
        keywordGroups: [["renew passport", "passport"], ["book dentist", "dentist"], ["ship beta", "beta"]],
        minMatchedGroups: 2,
        maxTokens: 96
    ),
    PerceptionCase(
        id: "workspace_identification",
        category: "screen_context",
        scene: .xcodeWorkspace,
        prompt: "What kind of work is on screen? Mention the app or file if you can.",
        keywordGroups: [["xcode"], ["pipelinecoordinator.swift", "pipeline coordinator"], ["swift", "coding", "development"]],
        minMatchedGroups: 2,
        maxTokens: 96
    ),
]

actor BenchmarkVLMEngine {
    private var container: ModelContainer?

    func load(modelID: String) async throws {
        let config = ModelConfiguration(id: modelID)
        container = try await VLMModelFactory.shared.loadContainer(configuration: config)
    }

    func generate(image: CGImage, prompt: String, maxTokens: Int) async throws -> GenerationResult {
        guard let container else {
            throw NSError(domain: "FaePerceptionBenchmark", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "VLM model not loaded"
            ])
        }

        let ciImage = CIImage(cgImage: image)
        let chatMessages: [Chat.Message] = [
            .system("/no_think\nDescribe what you see accurately, concisely, and without extra filler."),
            .user(prompt, images: [.ciImage(ciImage)]),
        ]

        var userInput = UserInput(chat: chatMessages)
        userInput.additionalContext = ["enable_thinking": false]
        let input = try await container.prepare(input: userInput)
        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.0,
            topP: 1.0,
            repetitionPenalty: 1.0
        )

        let started = Date()
        var firstTokenLatencyMS: Double?
        var text = ""
        let stream = try await container.generate(input: input, parameters: params)
        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                if firstTokenLatencyMS == nil {
                    firstTokenLatencyMS = Date().timeIntervalSince(started) * 1000
                }
                text += chunk
            case .info, .toolCall:
                break
            }
        }

        let wallTime = Date().timeIntervalSince(started)
        return GenerationResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            firstTokenLatencyMS: ((firstTokenLatencyMS ?? wallTime * 1000) * 10).rounded() / 10,
            wallTime: (wallTime * 100).rounded() / 100
        )
    }
}

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

@MainActor
func makeSceneImage(_ scene: MockSceneKind) -> CGImage {
    let size = NSSize(width: 1440, height: 900)
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    drawWindowFrame(in: NSRect(x: 80, y: 80, width: 1280, height: 740), title: titleForScene(scene))

    switch scene {
    case .terminalError:
        drawTerminalScene()
    case .calendarDay:
        drawCalendarScene()
    case .browserHeadline:
        drawBrowserScene()
    case .mailDraft:
        drawMailScene()
    case .notesList:
        drawNotesScene()
    case .xcodeWorkspace:
        drawWorkspaceScene()
    }

    image.unlockFocus()
    let rect = NSRect(origin: .zero, size: size)
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        ?? NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width),
            pixelsHigh: Int(rect.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!.cgImage!
}

@MainActor
func drawWindowFrame(in rect: NSRect, title: String) {
    NSColor.white.setFill()
    let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
    path.fill()

    NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
    path.lineWidth = 1
    path.stroke()

    let topBar = NSRect(x: rect.minX, y: rect.maxY - 52, width: rect.width, height: 52)
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    NSBezierPath(roundedRect: topBar, xRadius: 18, yRadius: 18).fill()

    drawTrafficLight(x: rect.minX + 22, y: rect.maxY - 34, color: .systemRed)
    drawTrafficLight(x: rect.minX + 44, y: rect.maxY - 34, color: .systemYellow)
    drawTrafficLight(x: rect.minX + 66, y: rect.maxY - 34, color: .systemGreen)

    drawText(
        title,
        at: NSPoint(x: rect.minX + 96, y: rect.maxY - 38),
        font: .systemFont(ofSize: 15, weight: .semibold),
        color: .darkGray
    )
}

@MainActor
func drawTrafficLight(x: CGFloat, y: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 12, height: 12)).fill()
}

@MainActor
func drawPanel(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
}

@MainActor
func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    text.draw(at: point, withAttributes: attrs)
}

@MainActor
func drawWrappedText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    NSString(string: text).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
}

@MainActor
func titleForScene(_ scene: MockSceneKind) -> String {
    switch scene {
    case .terminalError: return "Terminal — swift build"
    case .calendarDay: return "Calendar — Today"
    case .browserHeadline: return "Safari — Apple News"
    case .mailDraft: return "Mail — Draft"
    case .notesList: return "Notes — Weekly tasks"
    case .xcodeWorkspace: return "Xcode — Fae"
    }
}

@MainActor
func drawTerminalScene() {
    let rect = NSRect(x: 120, y: 120, width: 1200, height: 660)
    drawPanel(rect, color: NSColor(calibratedWhite: 0.08, alpha: 1))
    drawText("$ swift build", at: NSPoint(x: 150, y: 710), font: .monospacedSystemFont(ofSize: 22, weight: .regular), color: .systemGreen)
    drawText("Compiling PipelineCoordinator.swift", at: NSPoint(x: 150, y: 670), font: .monospacedSystemFont(ofSize: 22, weight: .regular), color: .white)
    drawText("error: cannot find 'foo' in scope", at: NSPoint(x: 150, y: 620), font: .monospacedSystemFont(ofSize: 26, weight: .semibold), color: .systemRed)
    drawText("PipelineCoordinator.swift:42:13", at: NSPoint(x: 150, y: 580), font: .monospacedSystemFont(ofSize: 22, weight: .regular), color: .systemOrange)
}

@MainActor
func drawCalendarScene() {
    let left = NSRect(x: 130, y: 140, width: 250, height: 600)
    let main = NSRect(x: 410, y: 140, width: 870, height: 600)
    drawPanel(left, color: NSColor(calibratedWhite: 0.96, alpha: 1))
    drawPanel(main, color: NSColor(calibratedWhite: 0.98, alpha: 1))
    drawText("Thursday 12 March", at: NSPoint(x: 450, y: 700), font: .systemFont(ofSize: 28, weight: .bold), color: .black)
    drawText("09:00  Design Review", at: NSPoint(x: 460, y: 610), font: .systemFont(ofSize: 24, weight: .medium), color: .systemBlue)
    drawText("13:00  Lunch with Sam", at: NSPoint(x: 460, y: 540), font: .systemFont(ofSize: 24, weight: .medium), color: .systemOrange)
    drawText("16:30  Dentist", at: NSPoint(x: 460, y: 470), font: .systemFont(ofSize: 24, weight: .medium), color: .systemPink)
}

@MainActor
func drawBrowserScene() {
    let body = NSRect(x: 120, y: 130, width: 1200, height: 620)
    drawPanel(body, color: NSColor.white)
    drawPanel(NSRect(x: 160, y: 650, width: 1120, height: 50), color: NSColor(calibratedWhite: 0.96, alpha: 1))
    drawText("apple.example/news/macbook-battery", at: NSPoint(x: 190, y: 665), font: .systemFont(ofSize: 18, weight: .regular), color: .darkGray)
    drawWrappedText(
        "Apple announces new MacBook battery improvements",
        in: NSRect(x: 180, y: 510, width: 980, height: 120),
        font: .systemFont(ofSize: 40, weight: .bold),
        color: .black
    )
    drawWrappedText(
        "Developers report noticeably faster compile times after the update.",
        in: NSRect(x: 180, y: 420, width: 980, height: 90),
        font: .systemFont(ofSize: 24, weight: .regular),
        color: .darkGray
    )
}

@MainActor
func drawMailScene() {
    let sidebar = NSRect(x: 120, y: 130, width: 220, height: 620)
    let body = NSRect(x: 360, y: 130, width: 960, height: 620)
    drawPanel(sidebar, color: NSColor(calibratedWhite: 0.96, alpha: 1))
    drawPanel(body, color: NSColor.white)
    drawText("To: alex@example.com", at: NSPoint(x: 400, y: 670), font: .systemFont(ofSize: 24, weight: .medium), color: .black)
    drawText("Subject: Project update", at: NSPoint(x: 400, y: 630), font: .systemFont(ofSize: 24, weight: .medium), color: .black)
    drawWrappedText(
        "Could we meet on Thursday at 3 pm to review the release plan?",
        in: NSRect(x: 400, y: 500, width: 820, height: 120),
        font: .systemFont(ofSize: 28, weight: .regular),
        color: .darkGray
    )
}

@MainActor
func drawNotesScene() {
    let body = NSRect(x: 150, y: 150, width: 1140, height: 580)
    drawPanel(body, color: NSColor(calibratedRed: 1, green: 0.97, blue: 0.83, alpha: 1))
    drawText("This week", at: NSPoint(x: 190, y: 660), font: .systemFont(ofSize: 32, weight: .bold), color: .black)
    drawText("• renew passport", at: NSPoint(x: 200, y: 580), font: .systemFont(ofSize: 28, weight: .regular), color: .black)
    drawText("• book dentist appointment", at: NSPoint(x: 200, y: 520), font: .systemFont(ofSize: 28, weight: .regular), color: .black)
    drawText("• ship beta build to testers", at: NSPoint(x: 200, y: 460), font: .systemFont(ofSize: 28, weight: .regular), color: .black)
    drawText("• reply to Alex", at: NSPoint(x: 200, y: 400), font: .systemFont(ofSize: 28, weight: .regular), color: .black)
}

@MainActor
func drawWorkspaceScene() {
    let sidebar = NSRect(x: 120, y: 130, width: 260, height: 620)
    let editor = NSRect(x: 400, y: 130, width: 620, height: 620)
    let inspector = NSRect(x: 1040, y: 130, width: 280, height: 620)
    drawPanel(sidebar, color: NSColor(calibratedWhite: 0.95, alpha: 1))
    drawPanel(editor, color: NSColor.white)
    drawPanel(inspector, color: NSColor(calibratedWhite: 0.97, alpha: 1))
    drawText("Fae", at: NSPoint(x: 160, y: 680), font: .systemFont(ofSize: 24, weight: .bold), color: .black)
    drawText("PipelineCoordinator.swift", at: NSPoint(x: 430, y: 680), font: .systemFont(ofSize: 24, weight: .semibold), color: .black)
    drawText("func visibleToolNamesForTurn(", at: NSPoint(x: 440, y: 610), font: .monospacedSystemFont(ofSize: 22, weight: .regular), color: .systemBlue)
    drawText("let likely = inferLikelyTools(from: userText)", at: NSPoint(x: 440, y: 570), font: .monospacedSystemFont(ofSize: 22, weight: .regular), color: .black)
    drawText("return Array(Set(likely)).sorted()", at: NSPoint(x: 440, y: 530), font: .monospacedSystemFont(ofSize: 22, weight: .regular), color: .black)
}

func scoreResponse(_ response: String, for test: PerceptionCase) -> (matchedKeywords: [String], matchedGroups: Int, correct: Bool) {
    let lower = response.lowercased()
    var matchedKeywords: [String] = []
    var matchedGroups = 0

    for group in test.keywordGroups {
        if let hit = group.first(where: { lower.contains($0.lowercased()) }) {
            matchedGroups += 1
            matchedKeywords.append(hit)
        }
    }

    return (
        matchedKeywords: matchedKeywords,
        matchedGroups: matchedGroups,
        correct: matchedGroups >= test.minMatchedGroups
    )
}

func model(named shortName: String) -> ModelEntry? {
    models.first(where: { $0.shortName == shortName })
}

func printUsage() {
    print("""
    FaePerceptionBenchmark — image grounding benchmark for multimodal Qwen models

    Usage:
      swift run FaePerceptionBenchmark --model qwen3.5-4b
      swift run FaePerceptionBenchmark --all
      swift run FaePerceptionBenchmark --model qwen3.5-9b --output results.json
    """)
}

@main
struct FaePerceptionBenchmark {
    static func main() async throws {
        var selectedModels: [ModelEntry] = []
        var outputPath: String?

        var i = 1
        while i < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i]
            switch arg {
            case "--model":
                i += 1
                guard i < CommandLine.arguments.count,
                      let entry = model(named: CommandLine.arguments[i])
                else {
                    print("Unknown model")
                    printUsage()
                    return
                }
                selectedModels = [entry]
            case "--all":
                selectedModels = models
            case "--output":
                i += 1
                guard i < CommandLine.arguments.count else {
                    printUsage()
                    return
                }
                outputPath = CommandLine.arguments[i]
            case "--help", "-h":
                printUsage()
                return
            default:
                print("Unknown argument: \(arg)")
                printUsage()
                return
            }
            i += 1
        }

        if selectedModels.isEmpty {
            selectedModels = [
                model(named: "qwen3.5-4b")!,
                model(named: "qwen3.5-9b")!,
            ]
        }

        print("FaePerceptionBenchmark — \(selectedModels.count) model(s)")
        print("Hardware: arm64, \(systemRAMGB()) GB RAM")
        print("Backend: mlx-swift-lm (MLXVLM)")

        var modelResults: [ModelPerceptionBenchmarkResult] = []

        for entry in selectedModels {
            print("\n======================================================================")
            print("  \(entry.shortName) (\(entry.modelID))")
            print("======================================================================")
            let engine = BenchmarkVLMEngine()
            do {
                print("  Loading VLM...")
                try await engine.load(modelID: entry.modelID)
                let idleRAMMB = (currentRAMMB() * 10).rounded() / 10
                print("  Idle RAM: \(Int(idleRAMMB)) MB")

                var results: [PerceptionEvalResult] = []
                for test in perceptionCases {
                    print("    \(test.id): \(test.prompt.prefix(44))...", terminator: "")
                    fflush(stdout)
                    let image = await makeSceneImage(test.scene)
                    let generated = try await engine.generate(
                        image: image,
                        prompt: test.prompt,
                        maxTokens: test.maxTokens
                    )
                    let scored = scoreResponse(generated.text, for: test)
                    print(" \(scored.correct ? "OK" : "MISS") groups=\(scored.matchedGroups)/\(test.keywordGroups.count)")
                    results.append(
                        PerceptionEvalResult(
                            id: test.id,
                            category: test.category,
                            scene: test.scene.rawValue,
                            prompt: test.prompt,
                            expectedKeywordGroups: test.keywordGroups,
                            matchedKeywords: scored.matchedKeywords,
                            matchedGroupCount: scored.matchedGroups,
                            minMatchedGroups: test.minMatchedGroups,
                            response: generated.text,
                            correct: scored.correct,
                            firstTokenLatencyMS: generated.firstTokenLatencyMS,
                            wallTimeS: generated.wallTime
                        )
                    )
                }

                modelResults.append(
                    ModelPerceptionBenchmarkResult(
                        modelID: entry.modelID,
                        modelShort: entry.shortName,
                        idleRAMMB: idleRAMMB,
                        loadSucceeded: true,
                        loadError: nil,
                        results: results
                    )
                )
            } catch {
                print("  Load failed: \(error.localizedDescription)")
                modelResults.append(
                    ModelPerceptionBenchmarkResult(
                        modelID: entry.modelID,
                        modelShort: entry.shortName,
                        idleRAMMB: 0,
                        loadSucceeded: false,
                        loadError: error.localizedDescription,
                        results: []
                    )
                )
            }
        }

        let output = BenchmarkOutput(
            hardware: .init(arch: "arm64", ramGB: systemRAMGB()),
            date: ISO8601DateFormatter().string(from: Date()),
            backend: "mlx-swift-lm (MLXVLM)",
            models: modelResults
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        let json = String(decoding: data, as: UTF8.self)

        if let outputPath {
            try data.write(to: URL(fileURLWithPath: outputPath))
            print("\nJSON results saved to: \(outputPath)")
        }

        print("\n======================================================================")
        print("SUMMARY")
        print("======================================================================")
        for model in modelResults {
            if !model.loadSucceeded {
                print("- \(model.modelShort): load failed (\(model.loadError ?? "unknown error"))")
                continue
            }
            let correct = model.results.filter(\.correct).count
            let total = model.results.count
            print("- \(model.modelShort): \(correct)/\(total) perception cases, idle RAM \(Int(model.idleRAMMB)) MB")
        }

        if outputPath == nil {
            print("\n\(json)")
        }
    }
}
