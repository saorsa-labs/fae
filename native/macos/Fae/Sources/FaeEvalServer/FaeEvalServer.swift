// FaeEvalServer — OpenAI-compatible HTTP server using Fae's real MLXLLMEngine.
//
// Bridges the Python eval harness to the exact same MLX Swift inference stack
// that Fae uses in production. No Python MLX, no Ollama — same engine, same
// chat templates, same tool call parsing, same quantizations.
//
// Usage:
//   swift run FaeEvalServer                          # auto-select model by RAM
//   swift run FaeEvalServer --model qwen3.5-27b      # specific model
//   swift run FaeEvalServer --port 8234              # custom port
//   swift run FaeEvalServer --model-id mlx-community/Qwen3.5-27B-4bit  # raw HF ID
//
// Then point the eval harness at http://127.0.0.1:8234

import CoreGraphics
import CoreImage
import Foundation
import FaeInference
import MLXLLM
import MLXVLM
import MLXLMCommon
import Network

// MARK: - Model Registry

enum ModelKind { case llm, vlm }

struct ModelEntry {
    let shortName: String
    let modelID: String
    let kind: ModelKind

    init(shortName: String, modelID: String, kind: ModelKind = .llm) {
        self.shortName = shortName
        self.modelID = modelID
        self.kind = kind
    }
}

let modelRegistry: [ModelEntry] = [
    // LLM models (text-only, via MLXLLMEngine)
    ModelEntry(shortName: "qwen3.5-0.8b", modelID: "mlx-community/Qwen3.5-0.8B-4bit"),
    ModelEntry(shortName: "qwen3.5-2b", modelID: "mlx-community/Qwen3.5-2B-OptiQ-4bit"),
    ModelEntry(shortName: "qwen3.5-4b", modelID: "mlx-community/Qwen3.5-4B-4bit"),
    ModelEntry(shortName: "qwen3.5-9b", modelID: "Brooooooklyn/Qwen3.5-9B-unsloth-mlx"),
    ModelEntry(shortName: "qwen3.5-27b", modelID: "mlx-community/Qwen3.5-27B-4bit"),
    ModelEntry(shortName: "qwen3.5-35b-a3b", modelID: "mlx-community/Qwen3.5-35B-A3B-4bit"),
    ModelEntry(shortName: "qwen3.5-27b-opus-distilled", modelID: "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"),
    ModelEntry(shortName: "qwen3-0.6b", modelID: "mlx-community/Qwen3-0.6B-4bit"),
    ModelEntry(shortName: "qwen3-4b", modelID: "mlx-community/Qwen3-4B-4bit"),
    ModelEntry(shortName: "qwen3-8b", modelID: "mlx-community/Qwen3-8B-4bit"),

    // VLM models (vision + text, via MLXVLM VLMModelFactory)
    ModelEntry(shortName: "smolvlm-256m", modelID: "mlx-community/SmolVLM2-256M-Video-Instruct-mlx", kind: .vlm),
    ModelEntry(shortName: "smolvlm-500m", modelID: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx", kind: .vlm),
    ModelEntry(shortName: "smolvlm-2.2b", modelID: "mlx-community/SmolVLM2-2.2B-Instruct-mlx", kind: .vlm),
    ModelEntry(shortName: "qwen3-vl-4b", modelID: "mlx-community/Qwen3-VL-4B-Instruct-8bit", kind: .vlm),
]

// MARK: - Auto Model Selection (mirrors FaeConfig)

func autoSelectModel() -> ModelEntry {
    let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
    if ramGB >= 32 {
        return modelRegistry.first { $0.shortName == "qwen3.5-35b-a3b" }!
    } else if ramGB >= 24 {
        return modelRegistry.first { $0.shortName == "qwen3.5-9b" }!
    } else if ramGB >= 16 {
        return modelRegistry.first { $0.shortName == "qwen3.5-4b" }!
    } else {
        return modelRegistry.first { $0.shortName == "qwen3.5-2b" }!
    }
}

func resolveModel(_ name: String) -> ModelEntry? {
    // Try exact short name match
    if let entry = modelRegistry.first(where: { $0.shortName == name }) {
        return entry
    }
    // Try as raw HF model ID
    return ModelEntry(shortName: name, modelID: name)
}

// MARK: - OpenAI Types

struct ChatRequest: Decodable {
    let model: String?
    let messages: [ChatMessage]
    let temperature: Double?
    let max_tokens: Int?
    let tools: [AnyCodable]?
    let stream: Bool?
}

struct ChatMessage: Decodable {
    let role: String
    let content: String?
    let tool_call_id: String?
    let name: String?
    let image_base64: String?  // Base64-encoded image for VLM eval
}

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }
}

// MARK: - HTTP Server (Network.framework)

actor EvalServer {
    let llmEngine = MLXLLMEngine()
    let modelID: String
    let modelName: String
    let modelKind: ModelKind
    let port: UInt16
    private var listener: NWListener?
    private var vlmContainer: ModelContainer?

    init(modelID: String, modelName: String, kind: ModelKind, port: UInt16) {
        self.modelID = modelID
        self.modelName = modelName
        self.modelKind = kind
        self.port = port
    }

    func start() async throws {
        print("[FaeEvalServer] Loading \(modelName) (\(modelID)) [\(modelKind == .vlm ? "VLM" : "LLM")]...")

        switch modelKind {
        case .llm:
            try await llmEngine.load(modelID: modelID)
            await llmEngine.warmup()
        case .vlm:
            let config = ModelConfiguration(id: modelID)
            vlmContainer = try await VLMModelFactory.shared.loadContainer(
                configuration: config,
                progressHandler: { progress in
                    if progress.fractionCompleted > 0 && progress.fractionCompleted < 1 {
                        print("[FaeEvalServer] Downloading: \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            )
            // Warmup VLM with minimal inference
            if let container = vlmContainer {
                let chatMessages: [Chat.Message] = [.system(""), .user("Hi")]
                var userInput = UserInput(chat: chatMessages)
                userInput.additionalContext = ["enable_thinking": false]
                let lmInput = try await container.prepare(input: userInput)
                let params = GenerateParameters(maxTokens: 1, temperature: 0.0, topP: 1.0, repetitionPenalty: nil)
                let stream = try await container.generate(input: lmInput, parameters: params)
                for await _ in stream { break }
            }
        }

        print("[FaeEvalServer] Model loaded and warm.")

        // Start HTTP listener
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[FaeEvalServer] Listening on http://127.0.0.1:\(self.port)")
                print("[FaeEvalServer] OpenAI-compatible: POST /v1/chat/completions")
                print("[FaeEvalServer] Model: \(self.modelName) (\(self.modelID))")
                let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
                print("[FaeEvalServer] Hardware: \(ramGB)GB RAM")
            case .failed(let error):
                print("[FaeEvalServer] Listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global())
            Task { await self.handleConnection(connection) }
        }

        listener.start(queue: .global())
    }

    private func receiveAll(_ connection: NWConnection) async -> Data? {
        var buffer = Data()
        while true {
            let chunk = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { content, _, isComplete, error in
                    cont.resume(returning: content)
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)

            // Check if we have the full HTTP request: headers + Content-Length body
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                if let headers = String(data: headerData, encoding: .utf8) {
                    let contentLength = headers.split(separator: "\r\n")
                        .first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
                    let bodyStart = headerEnd.upperBound

                    if let cl = contentLength {
                        if buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart) >= cl {
                            break // Got full body
                        }
                        // Need more data — continue reading
                    } else {
                        break // No Content-Length (GET request etc.)
                    }
                } else {
                    break
                }
            }

            // Safety: don't read forever
            if buffer.count > 10_000_000 { break }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func handleConnection(_ connection: NWConnection) async {
        guard let data = await receiveAll(connection),
              let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        // Split headers from body at \r\n\r\n
        let headerBodySplit = request.components(separatedBy: "\r\n\r\n")
        let headerSection = headerBodySplit[0]
        let body = headerBodySplit.count > 1 ? headerBodySplit.dropFirst().joined(separator: "\r\n\r\n") : ""

        // Parse request line
        let headerLines = headerSection.split(separator: "\r\n")
        guard let requestLine = headerLines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        let response: String
        switch (method, path) {
        case ("GET", "/health"):
            response = jsonResponse(200, body: """
                {"status":"ok","model":"\(modelName)","model_id":"\(modelID)","kind":"\(modelKind == .vlm ? "vlm" : "llm")"}
                """)

        case ("GET", "/v1/models"):
            response = jsonResponse(200, body: """
                {"object":"list","data":[{"id":"\(modelID)","object":"model","owned_by":"local-mlx"}]}
                """)

        case ("POST", "/v1/chat/completions"):
            response = await handleChatCompletion(body: body)

        case ("OPTIONS", _):
            response = corsResponse()

        default:
            response = jsonResponse(404, body: "{\"error\":\"not found\"}")
        }

        let responseData = Data(response.utf8)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleChatCompletion(body: String) async -> String {
        guard let bodyData = body.data(using: .utf8),
              let req = try? JSONDecoder().decode(ChatRequest.self, from: bodyData) else {
            return jsonResponse(400, body: "{\"error\":\"invalid request body\"}")
        }

        if req.stream == true {
            return jsonResponse(400, body: "{\"error\":\"streaming not supported, use stream: false\"}")
        }

        // Route to VLM or LLM handler
        if modelKind == .vlm {
            return await handleVLMCompletion(req)
        }

        // --- LLM path ---
        let messages = req.messages.map { msg -> LLMMessage in
            let role: LLMMessage.Role = switch msg.role {
            case "system": .system
            case "assistant": .assistant
            case "tool": .tool
            default: .user
            }
            return LLMMessage(
                role: role,
                content: msg.content ?? "",
                toolCallID: msg.tool_call_id,
                name: msg.name
            )
        }

        var systemPrompt = "You are a helpful assistant."
        var chatMessages = messages
        if let first = chatMessages.first, first.role == .system {
            systemPrompt = first.content
            chatMessages = Array(chatMessages.dropFirst())
        }

        var toolSpecs: [[String: any Sendable]]? = nil
        if let tools = req.tools {
            toolSpecs = tools.map { tool -> [String: any Sendable] in
                guard let dict = tool.value as? [String: Any] else { return [:] }
                return convertToSendable(dict)
            }
        }

        let options = GenerationOptions(
            temperature: Float(req.temperature ?? 0.0),
            maxTokens: req.max_tokens ?? 2048,
            suppressThinking: true,
            tools: toolSpecs
        )

        let start = CFAbsoluteTimeGetCurrent()
        let stream = await llmEngine.generate(
            messages: chatMessages,
            systemPrompt: systemPrompt,
            options: options
        )

        var fullText = ""
        var promptTokens = 0
        var genTokens = 0
        var toolCalls: [[String: Any]] = []
        var finishReason = "stop"

        do {
            for try await event in stream {
                switch event {
                case .text(let text):
                    fullText += text
                case .info(let info):
                    promptTokens = info.promptTokenCount
                    genTokens = info.generationTokenCount
                    if info.generationTokenCount >= (req.max_tokens ?? 2048) {
                        finishReason = "length"
                    }
                case .toolCall(let call):
                    toolCalls.append([
                        "id": "call_\(UUID().uuidString.prefix(8))",
                        "type": "function",
                        "function": [
                            "name": call.function.name,
                            "arguments": call.function.arguments,
                        ] as [String: Any],
                    ])
                }
            }
        } catch {
            return jsonResponse(500, body: """
                {"error":"generation failed: \(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))"}
                """)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Build OpenAI-compatible response
        let id = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let created = Int(Date().timeIntervalSince1970)

        if !toolCalls.isEmpty {
            finishReason = "tool_calls"
        }

        // Build message JSON
        var messageFields = "\"role\":\"assistant\""
        if !fullText.isEmpty {
            let escapedText = fullText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            messageFields += ",\"content\":\"\(escapedText)\""
        } else {
            messageFields += ",\"content\":null"
        }

        if !toolCalls.isEmpty {
            let tcJSON = toolCallsToJSON(toolCalls)
            messageFields += ",\"tool_calls\":\(tcJSON)"
        }

        let tps = elapsed > 0 ? Double(genTokens) / elapsed : 0

        let responseBody = """
        {
            "id":"\(id)",
            "object":"chat.completion",
            "created":\(created),
            "model":"\(modelID)",
            "choices":[{
                "index":0,
                "message":{\(messageFields)},
                "finish_reason":"\(finishReason)"
            }],
            "usage":{
                "prompt_tokens":\(promptTokens),
                "completion_tokens":\(genTokens),
                "total_tokens":\(promptTokens + genTokens)
            },
            "fae_eval":{
                "wall_time_ms":\(Int(elapsed * 1000)),
                "tokens_per_second":\(String(format: "%.1f", tps)),
                "engine":"mlx-swift-lm"
            }
        }
        """

        return jsonResponse(200, body: responseBody)
    }

    // MARK: - Helpers

    private func jsonResponse(_ status: Int, body: String) -> String {
        let statusText = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : "Internal Server Error"
        let bodyData = body.utf8
        return """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Authorization\r
        Connection: close\r
        \r
        \(body)
        """
    }

    private func corsResponse() -> String {
        return """
        HTTP/1.1 204 No Content\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Authorization\r
        Content-Length: 0\r
        Connection: close\r
        \r\n
        """
    }

    private func toolCallsToJSON(_ calls: [[String: Any]]) -> String {
        var parts: [String] = []
        for call in calls {
            let id = call["id"] as? String ?? ""
            let type = call["type"] as? String ?? "function"
            let fn = call["function"] as? [String: Any] ?? [:]
            let name = fn["name"] as? String ?? ""
            let args = fn["arguments"] as? String ?? "{}"
            let escapedArgs = args
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("""
            {"id":"\(id)","type":"\(type)","function":{"name":"\(name)","arguments":"\(escapedArgs)"}}
            """)
        }
        return "[\(parts.joined(separator: ","))]"
    }

    // MARK: - VLM Completion

    private func handleVLMCompletion(_ req: ChatRequest) async -> String {
        guard let container = vlmContainer else {
            return jsonResponse(500, body: "{\"error\":\"VLM container not loaded\"}")
        }

        // Build Chat.Message array for MLXVLM
        var systemPrompt = "Describe what you see accurately and concisely."
        var userPrompt = ""
        var images: [UserInput.Image] = []

        for msg in req.messages {
            if msg.role == "system" {
                systemPrompt = msg.content ?? systemPrompt
            } else if msg.role == "user" {
                userPrompt = msg.content ?? ""
                // Check for base64 image in image_url field
                if let imageB64 = msg.image_base64,
                   let imageData = Data(base64Encoded: imageB64),
                   let ciImage = CIImage(data: imageData) {
                    images.append(.ciImage(ciImage))
                }
            }
        }

        // If no image provided, create a minimal placeholder
        // (allows text-only VLM eval to still work)
        var chatMessages: [Chat.Message] = [.system(systemPrompt)]
        if images.isEmpty {
            chatMessages.append(.user(userPrompt))
        } else {
            chatMessages.append(.user(userPrompt, images: images))
        }

        var userInput = UserInput(chat: chatMessages)
        userInput.additionalContext = ["enable_thinking": false]

        let start = CFAbsoluteTimeGetCurrent()
        var fullText = ""
        var genTokens = 0

        do {
            let lmInput = try await container.prepare(input: userInput)
            let params = GenerateParameters(
                maxTokens: req.max_tokens ?? 512,
                temperature: Float(req.temperature ?? 0.0),
                topP: 1.0,
                repetitionPenalty: nil
            )
            let stream = try await container.generate(input: lmInput, parameters: params)
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    fullText += text
                    genTokens += 1
                case .info, .toolCall:
                    break
                }
            }
        } catch {
            return jsonResponse(500, body: """
                {"error":"VLM generation failed: \(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))"}
                """)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let tps = elapsed > 0 ? Double(genTokens) / elapsed : 0

        let escapedText = fullText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let id = "chatcmpl-\(UUID().uuidString.prefix(12))"
        return jsonResponse(200, body: """
        {
            "id":"\(id)",
            "object":"chat.completion",
            "created":\(Int(Date().timeIntervalSince1970)),
            "model":"\(modelID)",
            "choices":[{
                "index":0,
                "message":{"role":"assistant","content":"\(escapedText)"},
                "finish_reason":"stop"
            }],
            "usage":{"prompt_tokens":0,"completion_tokens":\(genTokens),"total_tokens":\(genTokens)},
            "fae_eval":{
                "wall_time_ms":\(Int(elapsed * 1000)),
                "tokens_per_second":\(String(format: "%.1f", tps)),
                "engine":"mlx-swift-vlm"
            }
        }
        """)
    }

    private func convertToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            if let str = value as? String { result[key] = str }
            else if let num = value as? Double { result[key] = num }
            else if let num = value as? Int { result[key] = num }
            else if let bool = value as? Bool { result[key] = bool }
            else if let arr = value as? [Any] { result[key] = arr.map { convertAnySendable($0) } as [any Sendable] }
            else if let sub = value as? [String: Any] { result[key] = convertToSendable(sub) }
        }
        return result
    }

    private func convertAnySendable(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let num = value as? Double { return num }
        if let num = value as? Int { return num }
        if let bool = value as? Bool { return bool }
        if let dict = value as? [String: Any] { return convertToSendable(dict) }
        if let arr = value as? [Any] { return arr.map { convertAnySendable($0) } as [any Sendable] }
        return String(describing: value)
    }
}

// MARK: - CLI

@main
struct FaeEvalServerCLI {
    static func main() async throws {
        let args = CommandLine.arguments
        var modelArg: String?
        var modelIDArg: String?
        var portArg: UInt16 = 8234

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--model":
                i += 1; if i < args.count { modelArg = args[i] }
            case "--model-id":
                i += 1; if i < args.count { modelIDArg = args[i] }
            case "--port":
                i += 1; if i < args.count { portArg = UInt16(args[i]) ?? 8234 }
            case "--help", "-h":
                printUsage(); return
            default:
                break
            }
            i += 1
        }

        // Resolve model
        let entry: ModelEntry
        if let rawID = modelIDArg {
            entry = ModelEntry(shortName: rawID.split(separator: "/").last.map(String.init) ?? rawID, modelID: rawID)
        } else if let name = modelArg, let resolved = resolveModel(name) {
            entry = resolved
        } else {
            entry = autoSelectModel()
            print("[FaeEvalServer] Auto-selected: \(entry.shortName) (based on \(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024))GB RAM)")
        }

        let server = EvalServer(modelID: entry.modelID, modelName: entry.shortName, kind: entry.kind, port: portArg)
        try await server.start()

        // Keep running
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            // Block forever — server runs until killed
        }
    }

    static func printUsage() {
        let llmModels = modelRegistry.filter { $0.kind == .llm }
        let vlmModels = modelRegistry.filter { $0.kind == .vlm }
        print("""
        FaeEvalServer — OpenAI-compatible server using Fae's MLX engines

        Usage:
          swift run FaeEvalServer [options]

        Options:
          --model <name>     Model short name
          --model-id <id>    Raw HuggingFace model ID
          --port <port>      HTTP port (default: 8234)
          --help             Show this help

        LLM Models (text, via MLXLLMEngine):
        \(llmModels.map { "  \($0.shortName.padding(toLength: 32, withPad: " ", startingAt: 0)) \($0.modelID)" }.joined(separator: "\n"))

        VLM Models (vision, via MLXVLM — same as production Fae):
        \(vlmModels.map { "  \($0.shortName.padding(toLength: 32, withPad: " ", startingAt: 0)) \($0.modelID)" }.joined(separator: "\n"))

        Auto-selection (--model not specified):
          ≥64GB → qwen3.5-35b-a3b    ≥32GB → qwen3.5-35b-a3b
          ≥16GB → qwen3.5-4b          <16GB → qwen3.5-0.8b

        Examples:
          just serve qwen3.5-27b       # LLM eval
          just serve smolvlm-256m      # VLM eval (SmolVLM2 256M)
          just serve qwen3-vl-4b       # VLM eval (Qwen3-VL)
        """)
    }
}
