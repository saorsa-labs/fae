import CoreGraphics
import CoreImage
import Foundation
import MLXLMCommon
import MLXVLM

/// Vision-language model engine using mlx-swift-lm's MLXVLM module.
///
/// Loads Qwen3-VL models for on-device image understanding. Loaded on-demand
/// (not at startup) to conserve RAM — only instantiated when vision tools fire.
actor MLXVLMEngine: VLMEngine {
    private var container: ModelContainer?
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    func load(modelID: String) async throws {
        loadState = .loading
        NSLog("MLXVLMEngine: loading model %@", modelID)
        do {
            let config = ModelConfiguration(id: modelID)
            container = try await VLMModelFactory.shared.loadContainer(configuration: config)
            isLoaded = true
            loadState = .loaded
            NSLog("MLXVLMEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXVLMEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Attach a pre-loaded ModelContainer for shared multimodal models.
    ///
    /// When the LLM is a natively multimodal model (e.g. Qwen3.5-35B-A3B), the container
    /// is loaded once via VLMModelFactory and shared between text and vision pipelines,
    /// avoiding a duplicate ~20 GB model load.
    func attachSharedContainer(_ sharedContainer: ModelContainer) {
        container = sharedContainer
        isLoaded = true
        loadState = .loaded
        NSLog("MLXVLMEngine: attached shared container (no duplicate load)")
    }

    func warmup() async {
        guard let container else { return }
        NSLog("MLXVLMEngine: starting warmup inference...")
        do {
            // Minimal inference with a tiny placeholder image to compile Metal shaders.
            let chatMessages: [Chat.Message] = [
                .system(""),
                .user("Hi"),
            ]
            var userInput = UserInput(chat: chatMessages)
            userInput.additionalContext = ["enable_thinking": false]
            let lmInput = try await container.prepare(input: userInput)
            let params = GenerateParameters(
                maxTokens: 1,
                temperature: 0.0,
                topP: 1.0,
                repetitionPenalty: 1.0
            )
            let stream = try await container.generate(input: lmInput, parameters: params)
            for await _ in stream { break }
            NSLog("MLXVLMEngine: warmup complete")
        } catch {
            NSLog("MLXVLMEngine: warmup failed (non-fatal): %@", error.localizedDescription)
        }
    }

    /// Generate a streaming description of an image.
    func describe(
        image: CGImage,
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                guard let container = await self.container else {
                    continuation.finish(throwing: MLEngineError.notLoaded("VLM"))
                    return
                }

                do {
                    let ciImage = CIImage(cgImage: image)
                    let chatMessages: [Chat.Message] = [
                        .system("Describe what you see accurately and concisely."),
                        .user(InputSanitizer.sanitizeVLMPrompt(prompt), images: [.ciImage(ciImage)]),
                    ]
                    var userInput = UserInput(chat: chatMessages)
                    userInput.additionalContext = ["enable_thinking": !options.suppressThinking]
                    let lmInput = try await container.prepare(input: userInput)

                    let params = GenerateParameters(
                        maxTokens: options.maxTokens,
                        temperature: options.temperature,
                        topP: options.topP,
                        repetitionPenalty: options.repetitionPenalty
                    )

                    let stream = try await container.generate(
                        input: lmInput,
                        parameters: params
                    )

                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            continuation.yield(text)
                        case .info, .toolCall:
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
