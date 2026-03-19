import Foundation
import JavaScriptCore

/// Fresh-per-run JavaScriptCore runtime for executing tool-program scripts.
///
/// Each ``run(script:)`` call creates a brand-new `JSContext`, installs the
/// ``JSCToolBridge``, evaluates the script, drives any pending async work
/// (Promises) to completion, and then tears down the context.
///
/// The runtime is an actor to serialise concurrent run requests.
actor JSCRuntime {

    // MARK: - Dependencies

    /// The shared tool executor that all bridge calls route through.
    private let executor: ToolExecutor

    /// Factory for building per-run execution contexts.
    private let contextFactory: @Sendable () -> ToolExecutorContext

    /// Factory for building per-run callbacks.
    private let callbacksFactory: @Sendable () -> ToolExecutorCallbacks

    // MARK: - State

    /// The budget tracker for the currently-executing script, if any.
    /// Used by ``cancelCurrent()`` to signal cooperative cancellation.
    private var currentTracker: ScriptBudgetTracker?

    // MARK: - Configuration

    /// Maximum number of drain-loop iterations before the runtime gives up.
    /// Prevents infinite loops when a script's promises never settle.
    static let maxDrainIterations = 500

    /// How long (in milliseconds) to sleep between drain-loop polls.
    static let drainPollIntervalMs: UInt64 = 10

    // MARK: - Init

    /// Create a JSCRuntime wired to the given tool executor.
    ///
    /// - Parameters:
    ///   - executor: The ``ToolExecutor`` that handles all tool calls.
    ///   - contextFactory: Builds a fresh ``ToolExecutorContext`` for each script run.
    ///   - callbacksFactory: Builds ``ToolExecutorCallbacks`` for each script run.
    init(
        executor: ToolExecutor,
        contextFactory: @escaping @Sendable () -> ToolExecutorContext,
        callbacksFactory: @escaping @Sendable () -> ToolExecutorCallbacks
    ) {
        self.executor = executor
        self.contextFactory = contextFactory
        self.callbacksFactory = callbacksFactory
    }

    // MARK: - Cancellation

    /// Signal cooperative cancellation of the currently-executing script.
    ///
    /// If a script is running, its budget tracker is cancelled so the drain
    /// loop exits on the next iteration. In-flight tool calls finish but no
    /// new ones are accepted.
    func cancelCurrent() {
        currentTracker?.cancel()
    }

    // MARK: - Execute

    /// Execute a JavaScript tool-program script and return its result.
    ///
    /// The script runs in an isolated JSContext with the `fae.*` bridge installed.
    /// All tool calls inside the script flow through ``ToolExecutor`` and its
    /// full security stack.
    ///
    /// - Parameters:
    ///   - script: The JavaScript source code to evaluate.
    ///   - budget: Resource limits for this execution. Defaults to ``ScriptBudget/default``.
    ///   - executionLog: Optional structured log collector for developer harness debugging.
    /// - Returns: A ``JSCScriptResult`` with the script's value, logs, and status.
    func run(script: String, budget: ScriptBudget = .default, executionLog: JSCExecutionLog? = nil) async -> JSCScriptResult {
        let budgetTracker = ScriptBudgetTracker(budget: budget)
        currentTracker = budgetTracker
        defer { currentTracker = nil }

        executionLog?.log(.scriptStart, message: "Script execution started", metadata: [
            "budgetMaxToolCalls": "\(budget.maxToolCalls)",
            "budgetMaxWallClockSeconds": "\(Int(budget.maxWallClockSeconds))",
            "budgetMaxConcurrentToolCalls": "\(budget.maxConcurrentToolCalls)",
        ])

        let bridge = JSCToolBridge(
            executor: executor,
            context: contextFactory(),
            callbacks: callbacksFactory(),
            budgetTracker: budgetTracker,
            executionLog: executionLog
        )

        // Create a fresh JSContext + VM per run.
        let vm = JSVirtualMachine()!
        let jsContext = JSContext(virtualMachine: vm)!

        // Install exception handler to capture JS errors.
        var caughtException: String?
        jsContext.exceptionHandler = { _, exception in
            if let exception {
                caughtException = exception.toString()
            }
        }

        // Install the fae.* bridge.
        bridge.install(in: jsContext)

        // Wrap the user script in an async IIFE so top-level `await` works.
        // The IIFE's return value is stored in `__fae_result`.
        let wrappedScript = """
        var __fae_result = undefined;
        var __fae_error = undefined;
        var __fae_done = false;
        (async function() {
            try {
                __fae_result = await (async function() {
                    \(script)
                })();
            } catch(e) {
                __fae_error = e instanceof Error ? e.message : String(e);
            } finally {
                __fae_done = true;
            }
        })();
        """

        // Evaluate the wrapped script (kicks off the async IIFE).
        jsContext.evaluateScript(wrappedScript)

        // Check for immediate syntax errors.
        if let exception = caughtException {
            executionLog?.log(.jsException, message: "Syntax error: \(exception)", success: false)
            executionLog?.log(.scriptEnd, message: "Script failed (syntax error)", success: false)
            return .failure(error: exception, logs: bridge.capturedLogs())
        }

        // Drive the async run loop: drain pending callbacks and poll for
        // completion until the script's IIFE signals `__fae_done = true`.
        var iterations = 0
        while iterations < Self.maxDrainIterations {
            iterations += 1

            // Check wall-clock budget before draining.
            if budgetTracker.isExpired {
                budgetTracker.cancel()
                let reason = "Script exceeded wall-clock budget of \(Int(budget.maxWallClockSeconds))s"
                executionLog?.log(.budgetCheck, message: reason, success: false)
                executionLog?.log(.scriptEnd, message: "Script ended (budget exceeded)", success: false)
                return .budgetExceeded(
                    reason: reason,
                    logs: bridge.capturedLogs()
                )
            }

            // Check cooperative cancellation.
            if budgetTracker.isCancelled {
                executionLog?.log(.cancellation, message: "Cooperative cancellation detected")
                executionLog?.log(.scriptEnd, message: "Script ended (cancelled)", success: false)
                return .cancelled(logs: bridge.capturedLogs())
            }

            // Drain any pending promise resolution callbacks.
            bridge.drainPendingCallbacks(in: jsContext)

            // Check if the script is done.
            let done = jsContext.objectForKeyedSubscript("__fae_done")?.toBool() ?? false
            if done && !bridge.hasPendingWork {
                break
            }

            // Yield briefly to let in-flight async work complete.
            try? await Task.sleep(nanoseconds: Self.drainPollIntervalMs * 1_000_000)
        }

        // Check for cancellation (max iterations hit with pending work).
        if iterations >= Self.maxDrainIterations && bridge.hasPendingWork {
            executionLog?.log(.cancellation, message: "Max drain iterations (\(Self.maxDrainIterations)) reached with pending work")
            executionLog?.log(.scriptEnd, message: "Script ended (drain exhausted)", success: false)
            return .cancelled(logs: bridge.capturedLogs())
        }

        // Check for script-level errors.
        if let jsError = jsContext.objectForKeyedSubscript("__fae_error"),
           !jsError.isUndefined
        {
            let errorStr = jsError.toString() ?? "Unknown script error"
            executionLog?.log(.jsException, message: "Script error: \(errorStr)", success: false)
            executionLog?.log(.scriptEnd, message: "Script failed (unhandled error)", success: false)
            return .failure(error: errorStr, logs: bridge.capturedLogs())
        }

        // Also check if the exception handler caught something during drain.
        if let exception = caughtException {
            executionLog?.log(.jsException, message: "Exception during drain: \(exception)", success: false)
            executionLog?.log(.scriptEnd, message: "Script failed (exception during drain)", success: false)
            return .failure(error: exception, logs: bridge.capturedLogs())
        }

        // Extract the return value.
        let resultValue: String?
        if let jsResult = jsContext.objectForKeyedSubscript("__fae_result"),
           !jsResult.isUndefined, !jsResult.isNull
        {
            // Try JSON serialization for objects/arrays; fall back to toString().
            if jsResult.isObject,
               let jsonData = try? JSONSerialization.data(
                   withJSONObject: jsResult.toObject() as Any
               ),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                resultValue = jsonString
            } else {
                resultValue = jsResult.toString()
            }
        } else {
            resultValue = nil
        }

        executionLog?.log(.scriptEnd, message: "Script completed successfully", success: true)
        return .success(value: resultValue, logs: bridge.capturedLogs())
    }
}
