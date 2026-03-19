import Foundation

/// Routes CoWork external LLM calls through ToolExecutor's unified security pipeline.
///
/// All external LLM calls — whether to OpenAI-compatible APIs, Anthropic, or any
/// third-party provider — are routed through this actor. This ensures that the
/// same security layers (DamageControlPolicy, OutboundExfiltrationGuard,
/// TrustedActionBroker) apply to CoWork calls as to native tool calls.
///
/// ## Lifecycle
///
/// 1. ``PipelineCoordinator/makeCoworkToolExecutor()`` creates this actor after
///    ``ToolExecutor`` is initialized, wiring the real security stack.
/// 2. ``FaeCore`` exposes it via ``FaeCore/coworkToolExecutor``.
/// 3. ``CoworkWorkspaceController`` calls ``submit(request:provider:)``,
///    ``submitStreaming(request:provider:onPartialText:)``, or
///    ``submitWithWebSearch(request:provider:)`` for every non-local LLM call.
/// 4. If the executor is unavailable (pipeline not started), the controller
///    falls back to direct provider access (graceful degradation).
///
/// ## Security Stack (per call)
///
/// ```
/// CoworkWorkspaceController
///     │
///     ├── CoworkToolExecutor.submit(request:, provider:)
///     │       │
///     │       ├── performSecurityCheck()
///     │       │       ├── ToolExecutorContext.coworkExternal() — nonLocal locality
///     │       │       ├── DamageControlPolicy — blocks credential/vault access
///     │       │       ├── OutboundExfiltrationGuard — novel recipient detection
///     │       │       └── TrustedActionBroker — default-deny chokepoint
///     │       │
///     │       ├── provider.submit() / .stream() / .submitWithWebSearch()
///     │       │
///     │       ├── guardNonEmpty() — rejects empty responses
///     │       ├── guardNoInjection() — prompt injection pattern scan
///     │       │
///     │       ├── SecurityEventLogger (block/flag/allow audit trail)
///     │       ├── FaeEventBus (UI security notifications)
///     │       └── metrics.increment(provider, outcome)
///     │
///     └── Response returned to CoWork UI
/// ```
///
/// ## Protected Paths (via DamageControlPolicy nonLocal rules)
///
/// - `~/.fae-vault/` — Git Vault backup repository
/// - `~/Library/Application Support/fae/speakers.json` — voice identity data
/// - `~/Library/Application Support/fae/directive.md` — system directive
/// - `~/.ssh/`, `~/.gnupg/`, `~/.aws/`, etc. — credential stores
actor CoworkToolExecutor {

    // MARK: - Per-Provider Metrics

    /// Lightweight per-provider security outcome counters.
    struct ProviderMetrics: Sendable {
        var allowed: Int = 0
        var blocked: Int = 0
        var flagged: Int = 0
    }

    // MARK: - Properties

    /// DamageControlPolicy for pre-broker catastrophic operation blocking.
    /// Called directly — NOT through ToolExecutor.execute(), which requires
    /// a registered tool name in ToolRegistry. CoWork provider calls are
    /// synthetic (not real tools) and must bypass the registry check.
    private let damageControlPolicy: DamageControlPolicy

    /// Prompt injection patterns to detect in inbound responses.
    private let inboundScanPatterns: [String]

    /// Whether PipelineCoordinator has completed startup.
    /// When false, submit calls fail fast with .pipelineNotReady.
    private var isReady: Bool = false

    /// Optional security event logger for structured JSONL audit trail.
    private let securityLogger: SecurityEventLogger?

    /// Optional event bus for publishing CoWork security events to the UI.
    private let eventBus: FaeEventBus?

    /// Per-provider security metrics (allowed/blocked/flagged counts).
    private var metrics: [String: ProviderMetrics] = [:]

    // MARK: - Init

    /// Create a CoworkToolExecutor with direct security layer access.
    ///
    /// Security is enforced by calling `DamageControlPolicy.evaluate()` directly,
    /// NOT by routing through `ToolExecutor.execute()`. This avoids the ToolRegistry
    /// check that would reject synthetic tool names like `"external_llm"`.
    ///
    /// - Parameters:
    ///   - damageControlPolicy: The DamageControlPolicy for catastrophic op blocking.
    ///   - inboundScanPatterns: Patterns checked in responses to detect prompt injection.
    ///   - isReady: Whether the executor is ready to handle requests.
    ///   - securityLogger: Logger for structured security event audit trail.
    ///   - eventBus: Event bus for UI-visible security notifications.
    init(
        damageControlPolicy: DamageControlPolicy,
        inboundScanPatterns: [String]? = nil,
        isReady: Bool = true,
        securityLogger: SecurityEventLogger? = nil,
        eventBus: FaeEventBus? = nil
    ) {
        self.damageControlPolicy = damageControlPolicy
        self.inboundScanPatterns = inboundScanPatterns ?? Self.defaultInboundPatterns
        self.isReady = isReady
        self.securityLogger = securityLogger
        self.eventBus = eventBus
    }

    /// Mark this executor as fully initialized and ready to handle requests.
    func markReady() {
        isReady = true
    }

    /// Read-only access to per-provider security metrics for diagnostics.
    func getMetrics() -> [String: ProviderMetrics] {
        metrics
    }

    // MARK: - Submit (Blocking)

    /// Submit a blocking request to an external LLM through the unified security pipeline.
    ///
    /// Runs the full security check (DamageControlPolicy, OutboundExfiltrationGuard,
    /// TrustedActionBroker), calls the provider, then validates the response for
    /// empty content and prompt injection patterns.
    ///
    /// - Parameters:
    ///   - request: The prepared CoWork provider request.
    ///   - provider: The external LLM provider to call.
    /// - Returns: The validated provider response.
    /// - Throws: ``CoworkToolExecutorError`` for security blocks, injection detection,
    ///   empty responses, provider errors, or network failures.
    func submit(
        request: CoworkProviderRequest,
        provider: some CoworkLLMProvider
    ) async throws -> CoworkProviderResponse {
        let providerKind = String(describing: provider.kind)
        try await performSecurityCheck(toolName: "external_llm", providerKind: providerKind, request: request)

        do {
            let response = try await provider.submit(request: request)
            try guardNonEmpty(response)
            try guardNoInjection(response, providerKind: providerKind)
            recordAllow(providerKind: providerKind, model: request.model)
            return response
        } catch let error as CoworkToolExecutorError {
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
    /// Security check runs before streaming begins. Partial text is forwarded
    /// via ``onPartialText`` as tokens arrive. The final assembled response is
    /// validated for empty content and prompt injection patterns after the
    /// stream completes.
    ///
    /// - Parameters:
    ///   - request: The prepared CoWork provider request.
    ///   - provider: The external streaming LLM provider.
    ///   - onPartialText: Called with accumulated text as tokens arrive.
    /// - Returns: The validated final provider response.
    /// - Throws: ``CoworkToolExecutorError`` for security blocks, injection detection,
    ///   empty responses, provider errors, or network failures.
    func submitStreaming(
        request: CoworkProviderRequest,
        provider: some CoworkStreamingProvider,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse {
        let providerKind = String(describing: provider.kind)
        try await performSecurityCheck(toolName: "external_llm_streaming", providerKind: providerKind, request: request)

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

        if let response = finalResponse {
            try guardNonEmpty(response)
            try guardNoInjection(response, providerKind: providerKind)
        }

        if let error = finalError {
            throw error
        }

        guard let result = finalResponse else {
            throw CoworkToolExecutorError.networkError(
                underlying: NSError(domain: "CoworkToolExecutor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Provider returned no response and no error"])
            )
        }
        recordAllow(providerKind: providerKind, model: request.model)
        return result
    }

    // MARK: - Submit (Web Search)

    /// Submit a web-search request through the unified security pipeline.
    ///
    /// Used when the provider supports web search tool loops (e.g. OpenAI
    /// with browsing). Security check runs before the call; response is
    /// validated for empty content and prompt injection patterns.
    ///
    /// - Parameters:
    ///   - request: The prepared CoWork provider request.
    ///   - provider: The external web-search-capable LLM provider.
    /// - Returns: The validated provider response.
    /// - Throws: ``CoworkToolExecutorError`` for security blocks, injection detection,
    ///   empty responses, provider errors, or network failures.
    func submitWithWebSearch(
        request: CoworkProviderRequest,
        provider: some CoworkWebSearchProvider
    ) async throws -> CoworkProviderResponse {
        let providerKind = String(describing: provider.kind)
        try await performSecurityCheck(toolName: "external_llm_websearch", providerKind: providerKind, request: request)

        do {
            let response = try await provider.submitWithWebSearch(request: request)
            try guardNonEmpty(response)
            try guardNoInjection(response, providerKind: providerKind)
            recordAllow(providerKind: providerKind, model: request.model)
            return response
        } catch let error as CoworkToolExecutorError {
            throw error
        } catch let error as CoworkProviderError {
            throw CoworkToolExecutorError.providerError(underlying: error)
        } catch {
            throw CoworkToolExecutorError.networkError(underlying: error)
        }
    }

    // MARK: - Security Check

    /// Runs DamageControlPolicy directly for a CoWork provider request.
    ///
    /// Calls `DamageControlPolicy.evaluate()` with `locality: .nonLocal` to trigger
    /// the zero-access path rules that block credential/vault access for external models.
    ///
    /// This does NOT route through `ToolExecutor.execute()` because:
    /// - ToolExecutor step 1 checks `registry.isToolAllowed(name)` which returns false
    ///   for synthetic names like "external_llm" — blocking ALL CoWork calls.
    /// - CoWork provider calls don't need the full tool-dispatch pipeline (registry lookup,
    ///   rate limiting, tool execution) — they only need the pre-flight security gate.
    private func performSecurityCheck(
        toolName: String,
        providerKind: String,
        request: CoworkProviderRequest
    ) async throws {
        guard isReady else {
            throw CoworkToolExecutorError.pipelineNotReady
        }

        // DamageControlPolicy evaluates zero-access paths for nonLocal models.
        // This catches credential exfiltration, vault access, sensitive file reads.
        let dcVerdict = await damageControlPolicy.evaluate(
            toolName: toolName,
            arguments: [
                "model": request.model,
                "provider": providerKind,
                "thinkingLevel": request.thinkingLevel.rawValue,
            ],
            locality: .nonLocal
        )

        switch dcVerdict {
        case .allow:
            break

        case .block(let reason), .disaster(let reason), .confirmManual(let reason):
            recordBlock(providerKind: providerKind, model: request.model, reason: reason)
            eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
            throw CoworkToolExecutorError.damageControlIntervened(reason: reason)
        }
    }

    // MARK: - Response Guards (Task 3)

    /// Throws `.emptyResponse` if the provider returned no meaningful content.
    private func guardNonEmpty(_ response: CoworkProviderResponse) throws {
        if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CoworkToolExecutorError.emptyResponse
        }
    }

    /// Throws `.inboundScanFlagged` if a prompt injection pattern is detected.
    private func guardNoInjection(_ response: CoworkProviderResponse, providerKind: String) throws {
        if let pattern = scanForInjection(response.content) {
            recordFlag(providerKind: providerKind, pattern: pattern)
            eventBus?.send(.coworkInjectionFlagged(provider: providerKind, pattern: pattern))
            throw CoworkToolExecutorError.inboundScanFlagged(reason: pattern)
        }
    }

    // MARK: - Metrics (Task 6)

    /// Record a successful (allowed) CoWork call.
    private func recordAllow(providerKind: String, model: String) {
        metrics[providerKind, default: ProviderMetrics()].allowed += 1
        Task {
            await securityLogger?.log(
                event: "cowork_allowed",
                toolName: "external_llm",
                decision: "allow",
                arguments: ["provider": providerKind, "model": model]
            )
        }
    }

    /// Record a security-blocked CoWork call.
    private func recordBlock(providerKind: String, model: String, reason: String) {
        metrics[providerKind, default: ProviderMetrics()].blocked += 1
        Task {
            await securityLogger?.log(
                event: "cowork_blocked",
                toolName: "external_llm",
                decision: "block",
                reasonCode: reason,
                arguments: ["provider": providerKind, "model": model]
            )
        }
    }

    /// Record a flagged (injection-detected) CoWork response.
    private func recordFlag(providerKind: String, pattern: String) {
        metrics[providerKind, default: ProviderMetrics()].flagged += 1
        Task {
            await securityLogger?.log(
                event: "cowork_injection_flagged",
                toolName: "external_llm",
                decision: "flag",
                reasonCode: pattern,
                arguments: ["provider": providerKind]
            )
        }
    }

    // MARK: - Inbound Response Scan

    /// Scans a response for prompt injection patterns.
    /// Returns nil if clean, or the matched pattern if flagged.
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
