import Foundation

/// Developer harness for running JSC tool-program scripts outside the live
/// LLM pipeline.
///
/// Provides a simplified entry point for testing, debugging, and validating
/// tool programs against mocked or safe tools. Captures structured execution
/// logs and produces a ``HarnessResult`` with the full execution timeline.
///
/// ## Usage
///
/// ```swift
/// let harness = JSCDeveloperHarness(tools: [
///     MockTool(name: "read", response: #"{"content":"hello"}"#)
/// ])
/// let result = await harness.run(script: """
///     var content = await fae.tool('read', '{"path":"/tmp/test"}');
///     fae.log('Read: ' + content);
///     return 'done';
/// """)
/// print(result.timeline)     // Human-readable execution trace
/// print(result.scriptResult) // JSCScriptResult
/// ```
///
/// The harness is intentionally **not** an actor — each ``run(script:)`` call
/// creates a fresh ``JSCRuntime`` with its own isolated actor, so concurrent
/// harness calls are safe.
struct JSCDeveloperHarness {

    /// Tools available to scripts run through this harness.
    let tools: [any Tool]

    /// The default budget for scripts. Overridable per-run.
    let defaultBudget: ScriptBudget

    /// Tool mode for the executor context.
    let toolMode: String

    // MARK: - Init

    /// Create a developer harness with the given tools and configuration.
    ///
    /// - Parameters:
    ///   - tools: Tools available to scripts. Use ``MockTool`` for testing.
    ///   - defaultBudget: Default budget. Defaults to ``ScriptBudget/default``.
    ///   - toolMode: Tool mode for the executor context. Defaults to `"full"`.
    init(
        tools: [any Tool] = [],
        defaultBudget: ScriptBudget = .default,
        toolMode: String = "full"
    ) {
        self.tools = tools
        self.defaultBudget = defaultBudget
        self.toolMode = toolMode
    }

    // MARK: - Execute

    /// Run a JavaScript tool-program script and return a detailed harness result.
    ///
    /// Creates a fresh ``JSCRuntime`` per call with full execution logging
    /// enabled. The result includes the script outcome, structured execution
    /// log entries, and a formatted timeline string for debugging.
    ///
    /// - Parameters:
    ///   - script: The JavaScript source code to evaluate.
    ///   - budget: Resource limits for this execution. Defaults to the harness's
    ///     ``defaultBudget``.
    /// - Returns: A ``HarnessResult`` with the complete execution trace.
    func run(script: String, budget: ScriptBudget? = nil) async -> HarnessResult {
        let effectiveBudget = budget ?? defaultBudget
        let executionLog = JSCExecutionLog()

        let registry = ToolRegistry(tools: tools)
        let executor = ToolExecutor(
            registry: registry,
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared
        )

        let runtime = JSCRuntime(
            executor: executor,
            contextFactory: { [toolMode] in
                ToolExecutorContext(
                    toolMode: toolMode,
                    privacyMode: "local_preferred",
                    modelLocality: .local,
                    explicitUserAuthorization: false,
                    isOwner: true,
                    livenessScore: nil,
                    speakerId: nil,
                    actionSource: .voice,
                    proactiveContext: nil,
                    visionEnabled: false,
                    firstOwnerEnrollmentActive: false,
                    workflowTurnID: nil,
                    traceToolCallID: nil,
                    workflowRunID: nil
                )
            },
            callbacksFactory: {
                .noop
            }
        )

        let startTime = Date()
        let scriptResult = await runtime.run(
            script: script,
            budget: effectiveBudget,
            executionLog: executionLog
        )
        let totalDurationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return HarnessResult(
            scriptResult: scriptResult,
            executionLog: executionLog,
            totalDurationMs: totalDurationMs
        )
    }
}

// MARK: - HarnessResult

extension JSCDeveloperHarness {

    /// Complete result of a harness execution, including the script outcome
    /// and the full structured execution log.
    struct HarnessResult: Sendable {

        /// The script's outcome (success/failure/cancelled/budgetExceeded).
        let scriptResult: JSCScriptResult

        /// The structured execution log with per-step entries.
        let executionLog: JSCExecutionLog

        /// Total wall-clock duration of the execution in milliseconds.
        let totalDurationMs: Int

        /// Convenience: the formatted timeline string for debugging.
        var timeline: String {
            executionLog.formatTimeline()
        }

        /// Convenience: all log entries.
        var logEntries: [JSCExecutionLogEntry] {
            executionLog.snapshot()
        }

        /// Convenience: number of tool calls initiated during execution.
        var toolCallCount: Int {
            executionLog.toolCalls.count
        }

        /// Convenience: whether any errors occurred.
        var hasErrors: Bool {
            executionLog.hasErrors
        }
    }
}

// MARK: - MockTool

/// A simple mock tool for use with ``JSCDeveloperHarness``.
///
/// Returns a fixed JSON response string, or an error if configured to fail.
/// Useful for testing scripts that depend on specific tool output.
struct MockTool: Tool, Sendable {

    let name: String
    let description: String
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    /// The fixed response to return on success.
    let response: String

    /// If `true`, the tool returns an error instead of the response.
    let shouldFail: Bool

    /// Create a mock tool that returns a fixed response.
    ///
    /// - Parameters:
    ///   - name: The tool name (must match what the script calls).
    ///   - description: Tool description. Defaults to `"mock tool"`.
    ///   - response: The JSON string to return. Defaults to `"{}"`.
    ///   - shouldFail: If `true`, returns an error. Defaults to `false`.
    init(
        name: String,
        description: String = "mock tool",
        response: String = "{}",
        shouldFail: Bool = false
    ) {
        self.name = name
        self.description = description
        self.response = response
        self.shouldFail = shouldFail
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        if shouldFail {
            return .error("MockTool[\(name)]: intentional failure")
        }
        return .success(response)
    }
}
