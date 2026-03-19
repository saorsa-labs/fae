import Foundation

/// Routes CoWork external LLM calls through ToolExecutor's unified security pipeline.
///
/// All external LLM calls — whether to OpenAI-compatible APIs, Anthropic, or any
/// third-party provider — are routed through this actor. This ensures that the
/// same security layers (DamageControlPolicy, OutboundExfiltrationGuard,
/// TrustedActionBroker) apply to CoWork calls as to native tool calls.
///
/// The actor is created by PipelineCoordinator after ToolExecutor is initialized,
/// and is exposed via FaeCore for use by CoworkWorkspaceController.
///
/// ## Architecture
///
/// ```
/// CoworkWorkspaceController
///     │
///     ├── CoworkToolExecutor.submit(request:, provider:)
///     │       │
///     │       ├── Build ToolExecutorContext (modelLocality: .nonLocal)
///     │       │
///     │       ├── ToolExecutor.execute() ← security stack
///     │       │       ├── DamageControlPolicy — blocks credential access
///     │       │       ├── OutboundExfiltrationGuard — novel recipient detection
///     │       │       └── TrustedActionBroker — default-deny chokepoint
///     │       │
///     │       └── provider.submit() ← actual HTTP call
///     │
///     └── Inbound scan on response
/// ```
actor CoworkToolExecutor {

    // MARK: - Properties

    /// Reference to the shared ToolExecutor security pipeline.
    /// Set during init by PipelineCoordinator; exposed via FaeCore.coworkToolExecutor.
    private let toolExecutor: any ToolExecutorProtocol

    /// Prompt injection patterns to detect in inbound responses.
    /// These are detected via simple substring/pattern matching — not ML.
    private let inboundScanPatterns: [String]

    // MARK: - Init

    /// Create a CoworkToolExecutor with the shared security pipeline.
    ///
    /// - Parameters:
    ///   - toolExecutor: The ToolExecutor instance created by PipelineCoordinator.
    ///     Must be the same instance used by the voice pipeline.
    ///   - inboundScanPatterns: Patterns checked in responses to detect prompt
    ///     injection attempts. If nil, uses the default set.
    init(
        toolExecutor: any ToolExecutorProtocol,
        inboundScanPatterns: [String]? = nil
    ) {
        self.toolExecutor = toolExecutor
        self.inboundScanPatterns = inboundScanPatterns ?? Self.defaultInboundPatterns
    }

    // MARK: - Submit (Blocking)

    /// Submit a request to an external LLM through the unified security pipeline.
    ///
    /// 1. Builds a ToolExecutorContext with modelLocality = .nonLocal
    /// 2. Executes through ToolExecutor (security stack runs)
    /// 3. On allow: calls provider.submit()
    /// 4. Runs inbound scan on response
    /// 5. Returns response or error
    func submit(
        request: CoworkProviderRequest,
        provider: some CoworkLLMProvider
    ) async throws -> CoworkProviderResponse {
        // Security check through unified pipeline
        let context = buildContext(for: request)
        let callbacks = buildCallbacks()

        let call = PipelineCoordinator.ToolCall(
            name: "external_llm",
            arguments: [
                "model": request.model,
                "provider": String(describing: provider.kind),
                "thinkingLevel": request.thinkingLevel.rawValue,
            ]
        )

        let outcome = await toolExecutor.execute(call, context: context, callbacks: callbacks)

        // Check damageControlIntervened first — it takes precedence over generic isError
        if outcome.damageControlIntervened {
            throw CoworkToolExecutorError.damageControlIntervened(
                reason: outcome.result.output
            )
        }

        // If security blocked, propagate the error
        if outcome.result.isError {
            throw CoworkToolExecutorError.securityBlocked(reason: outcome.result.output)
        }

        // Execute the actual provider call
        do {
            let response = try await provider.submit(request: request)

            // Inbound scan on response
            if let scanError = scanForInjection(response.content) {
                throw CoworkToolExecutorError.inboundScanFlagged(reason: scanError)
            }

            return response
        } catch let error as CoworkToolExecutorError {
            // Re-throw CoworkToolExecutorError variants unchanged (e.g. inboundScanFlagged)
            throw error
        } catch let error as CoworkProviderError {
            throw CoworkToolExecutorError.providerError(underlying: error)
        } catch {
            throw CoworkToolExecutorError.networkError(underlying: error)
        }
    }

    // MARK: - Submit (Streaming)

    /// Submit a streaming request through the unified security pipeline.
    ///
    /// Security runs on the outer request; the streaming response is scanned
    /// on completion.
    func submitStreaming(
        request: CoworkProviderRequest,
        provider: some CoworkStreamingProvider,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse {
        let context = buildContext(for: request)
        let callbacks = buildCallbacks()

        let call = PipelineCoordinator.ToolCall(
            name: "external_llm_streaming",
            arguments: [
                "model": request.model,
                "provider": String(describing: provider.kind),
                "thinkingLevel": request.thinkingLevel.rawValue,
            ]
        )

        let outcome = await toolExecutor.execute(call, context: context, callbacks: callbacks)

        if outcome.damageControlIntervened {
            throw CoworkToolExecutorError.damageControlIntervened(
                reason: outcome.result.output
            )
        }

        if outcome.result.isError {
            throw CoworkToolExecutorError.securityBlocked(reason: outcome.result.output)
        }

        var finalResponse: CoworkProviderResponse?
        var finalError: Error?

        do {
            let response = try await provider.stream(request: request) { partialText in
                await onPartialText(partialText)
            }
            finalResponse = response
        } catch let error as CoworkProviderError {
            finalError = CoworkToolExecutorError.providerError(underlying: error)
        } catch let error as CoworkToolExecutorError {
            finalError = error
        } catch {
            finalError = CoworkToolExecutorError.networkError(underlying: error)
        }

        // Scan the final accumulated response
        if let response = finalResponse {
            if let scanError = scanForInjection(response.content) {
                throw CoworkToolExecutorError.inboundScanFlagged(reason: scanError)
            }
        }

        if let error = finalError {
            throw error
        }

        return finalResponse!
    }

    // MARK: - Submit (Web Search)

    /// Submit a web-search request through the unified security pipeline.
    ///
    /// The web-search loop is trusted to run internally; the final response
    /// is scanned before returning to the caller.
    func submitWithWebSearch(
        request: CoworkProviderRequest,
        provider: some CoworkWebSearchProvider
    ) async throws -> CoworkProviderResponse {
        let context = buildContext(for: request)
        let callbacks = buildCallbacks()

        let call = PipelineCoordinator.ToolCall(
            name: "external_llm_websearch",
            arguments: [
                "model": request.model,
                "provider": String(describing: provider.kind),
                "thinkingLevel": request.thinkingLevel.rawValue,
            ]
        )

        let outcome = await toolExecutor.execute(call, context: context, callbacks: callbacks)

        if outcome.damageControlIntervened {
            throw CoworkToolExecutorError.damageControlIntervened(
                reason: outcome.result.output
            )
        }

        if outcome.result.isError {
            throw CoworkToolExecutorError.securityBlocked(reason: outcome.result.output)
        }

        do {
            let response = try await provider.submitWithWebSearch(request: request)

            if let scanError = scanForInjection(response.content) {
                throw CoworkToolExecutorError.inboundScanFlagged(reason: scanError)
            }

            return response
        } catch let error as CoworkToolExecutorError {
            throw error
        } catch let error as CoworkProviderError {
            throw CoworkToolExecutorError.providerError(underlying: error)
        } catch {
            throw CoworkToolExecutorError.networkError(underlying: error)
        }
    }

    // MARK: - Context Building

    /// Builds the ToolExecutorContext for a Cowork request.
    ///
    /// modelLocality is always .nonLocal for external providers — this triggers
    /// DamageControlPolicy's nonLocalOnly zeroAccessPaths rules.
    private func buildContext(for request: CoworkProviderRequest) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "full",
            privacyMode: "shareable",
            modelLocality: .nonLocal,
            capabilityTicket: nil,
            hasCapabilityTicketForTool: false,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            actionSource: .relay,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
    }

    /// Builds no-op callbacks for CoworkToolExecutor.
    ///
    /// Approval callbacks are handled by the security stack (TrustedActionBroker)
    /// — CoworkToolExecutor does not run the interactive approval overlay.
    /// The caller (CoworkWorkspaceController) handles UI feedback separately.
    private func buildCallbacks() -> ToolExecutorCallbacks {
        ToolExecutorCallbacks(
            onApprovalPending: { _, _ in },
            onVisionAutoEnabled: { },
            onComputerUseStep: { 0 }
        )
    }

    // MARK: - Inbound Response Scan

    /// Scans a response for prompt injection patterns.
    ///
    /// Detects common prompt injection attempts in LLM responses.
    /// Returns nil if clean, or an error description if flagged.
    private func scanForInjection(_ content: String) -> String? {
        let lowercased = content.lowercased()
        for pattern in inboundScanPatterns {
            if lowercased.contains(pattern.lowercased()) {
                return "detected pattern: \(pattern)"
            }
        }
        return nil
    }

    // MARK: - Default Patterns

    /// Default prompt injection patterns.
    ///
    /// Covers common prompt injection templates. Users can extend via init.
    private static let defaultInboundPatterns: [String] = [
        "ignore previous instructions",
        "disregard all prior",
        "you are now",
        "forget all previous",
        "new instructions:",
        "previous instructions are",
        "instructions override",
        "assistant is now",
        "you now have",
        "disregard the above",
    ]
}
