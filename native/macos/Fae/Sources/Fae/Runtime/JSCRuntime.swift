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

    /// Manager for script-scoped capability tickets.
    /// Injected at init; when non-nil, tickets are issued per-run and
    /// revoked on completion, failure, or cancellation.
    let ticketManager: ScriptScopedTicketManager?

    // MARK: - State

    /// The budget tracker for the currently-executing script, if any.
    /// Used by ``cancelCurrent()`` to signal cooperative cancellation.
    private var currentTracker: ScriptBudgetTracker?

    /// The script run ID for the currently-executing script, if any.
    /// Used by ``cancelCurrent()`` to revoke the script-scoped ticket.
    private var currentRunId: String?

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
    ///   - ticketManager: Optional manager for script-scoped capability tickets.
    init(
        executor: ToolExecutor,
        contextFactory: @escaping @Sendable () -> ToolExecutorContext,
        callbacksFactory: @escaping @Sendable () -> ToolExecutorCallbacks,
        ticketManager: ScriptScopedTicketManager? = nil
    ) {
        self.executor = executor
        self.contextFactory = contextFactory
        self.callbacksFactory = callbacksFactory
        self.ticketManager = ticketManager
    }

    // MARK: - Cancellation

    /// Signal cooperative cancellation of the currently-executing script.
    ///
    /// If a script is running, its budget tracker is cancelled so the drain
    /// loop exits on the next iteration. In-flight tool calls finish but no
    /// new ones are accepted. The script-scoped capability ticket is also
    /// revoked immediately.
    func cancelCurrent() {
        currentTracker?.cancel()
        if let runId = currentRunId {
            ticketManager?.revoke(scriptRunId: runId)
        }
    }

    // MARK: - Execute

    /// Execute a JavaScript tool-program script and return its result.
    ///
    /// The script runs in an isolated JSContext with the `fae.*` bridge installed.
    /// All tool calls inside the script flow through ``ToolExecutor`` and its
    /// full security stack. When a ``ticketManager`` is configured and `allowedTools`
    /// is provided, a script-scoped capability ticket is issued for the run and
    /// automatically revoked when the script completes, fails, or is cancelled.
    ///
    /// - Parameters:
    ///   - script: The JavaScript source code to evaluate.
    ///   - budget: Resource limits for this execution. Defaults to ``ScriptBudget/default``.
    ///   - executionLog: Optional structured log collector for developer harness debugging.
    ///   - allowedTools: Tool set for the script-scoped capability ticket. When `nil`
    ///     and a ``ticketManager`` is configured, no ticket is issued (backward compat).
    /// - Returns: A ``JSCScriptResult`` with the script's value, logs, and status.
    func run(
        script: String,
        budget: ScriptBudget = .default,
        executionLog: JSCExecutionLog? = nil,
        allowedTools: Set<String>? = nil,
        context: ToolExecutorContext? = nil,
        callbacks: ToolExecutorCallbacks? = nil
    ) async -> JSCScriptResult {
        let budgetTracker = ScriptBudgetTracker(budget: budget)
        currentTracker = budgetTracker

        // Generate a unique run ID for ticket scoping.
        let runId = UUID().uuidString
        currentRunId = runId

        // Issue a script-scoped ticket if a manager and allowed tools are provided.
        if let manager = ticketManager, let tools = allowedTools {
            _ = manager.issue(
                scriptRunId: runId,
                allowedTools: tools,
                ttlSeconds: budget.maxWallClockSeconds
            )
        }

        defer {
            currentTracker = nil
            currentRunId = nil
            // Revoke the script-scoped ticket on every exit path.
            ticketManager?.revoke(scriptRunId: runId)
        }

        executionLog?.log(.scriptStart, message: "Script execution started", metadata: [
            "budgetMaxToolCalls": "\(budget.maxToolCalls)",
            "budgetMaxWallClockSeconds": "\(Int(budget.maxWallClockSeconds))",
            "budgetMaxConcurrentToolCalls": "\(budget.maxConcurrentToolCalls)",
            "scriptRunId": runId,
        ])

        let bridge = JSCToolBridge(
            executor: executor,
            context: context ?? contextFactory(),
            callbacks: callbacks ?? callbacksFactory(),
            budgetTracker: budgetTracker,
            executionLog: executionLog,
            ticketManager: ticketManager,
            scriptRunId: runId
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

        // Install typed adapters (fae.calendar, fae.reminders, etc.)
        // on top of the raw fae.tool() bridge.
        JSCTypedAdapters.install(in: jsContext)

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

    // MARK: - Dry-Run Execution

    /// Execute a script in dry-run mode: record all intended tool calls
    /// without actually executing them.
    ///
    /// The script runs in a JSContext with a recording `fae.tool()` that
    /// returns synthetic success results (`"(dry-run)"`) for every call.
    /// This lets the script run to completion and expose its full plan
    /// of intended tool calls.
    ///
    /// - Parameters:
    ///   - script: The JavaScript source code to evaluate.
    ///   - budget: Resource limits for the dry-run. Defaults to ``ScriptBudget/default``.
    /// - Returns: A ``DryRunPlan`` with all recorded intended calls and the script result.
    func runDryRun(
        script: String,
        budget: ScriptBudget = .default
    ) async -> DryRunPlan {
        // Budget tracker enforces tool-call and wall-clock limits even in dry-run.
        let budgetTracker = ScriptBudgetTracker(budget: budget)
        let startTime = Date()

        // Thread-safe collector for intended tool calls.
        let collector = DryRunCallCollector()

        // Create a fresh JSContext with a recording bridge.
        let vm = JSVirtualMachine()!
        let jsContext = JSContext(virtualMachine: vm)!

        var caughtException: String?
        jsContext.exceptionHandler = { _, exception in
            if let exception {
                caughtException = exception.toString()
            }
        }

        // Install fae namespace.
        jsContext.evaluateScript("var fae = {};")

        // fae.log — same as normal.
        let logBlock: @convention(block) (String) -> Void = { [collector] message in
            collector.addLog(message)
        }
        jsContext.objectForKeyedSubscript("fae")
            .setObject(logBlock, forKeyedSubscript: "log" as NSString)

        // fae.tool — recording version that returns synthetic results.
        let toolFnSource = """
        (function() {
            fae._toolResolvers = {};
            fae._toolNextId = 0;
            fae._toolNative = null;

            fae.tool = function(name, argsJSON) {
                var id = fae._toolNextId++;
                return new Promise(function(resolve, reject) {
                    fae._toolResolvers[id] = { resolve: resolve, reject: reject };
                    fae._toolNative(id, name, typeof argsJSON === 'string' ? argsJSON : JSON.stringify(argsJSON || {}));
                });
            };
        })();
        """
        jsContext.evaluateScript(toolFnSource)

        // Pending callbacks for promise resolution.
        var pendingCallbacks: [() -> Void] = []
        let callbackQueue = DispatchQueue(label: "fae.dryrun.callbacks")

        let nativeBlock: @convention(block) (Int, String, String) -> Void = { [budgetTracker] callId, name, argsJSON in
            // Check budget before recording.
            if let budgetError = budgetTracker.tryStartToolCall() {
                callbackQueue.sync {
                    pendingCallbacks.append {
                        let resolvers = jsContext.objectForKeyedSubscript("fae")
                            .objectForKeyedSubscript("_toolResolvers")
                            .objectForKeyedSubscript(callId)
                        resolvers?.objectForKeyedSubscript("reject")
                            .call(withArguments: [budgetError as NSString])
                        jsContext.evaluateScript("delete fae._toolResolvers[\(callId)];")
                    }
                }
                return
            }
            budgetTracker.finishToolCall()

            // Record the intended call.
            collector.record(toolName: name, argumentsJSON: argsJSON)

            // Resolve the promise with a synthetic result.
            callbackQueue.sync {
                pendingCallbacks.append {
                    let resolvers = jsContext.objectForKeyedSubscript("fae")
                        .objectForKeyedSubscript("_toolResolvers")
                        .objectForKeyedSubscript(callId)
                    let dryRunEnvelope = #"{"output":"(dry-run)","isError":false,"data":{"dryRun":true}}"#
                    resolvers?.objectForKeyedSubscript("resolve")
                        .call(withArguments: [dryRunEnvelope as NSString])
                    jsContext.evaluateScript("delete fae._toolResolvers[\(callId)];")
                }
            }
        }
        jsContext.objectForKeyedSubscript("fae")
            .setObject(nativeBlock, forKeyedSubscript: "_toolNative" as NSString)

        // fae.sleep — instant resolution in dry-run mode.
        let sleepFnSource = """
        (function() {
            fae._sleepResolvers = {};
            fae._sleepNextId = 0;
            fae._sleepNative = null;

            fae.sleep = function(ms) {
                var id = fae._sleepNextId++;
                return new Promise(function(resolve) {
                    fae._sleepResolvers[id] = resolve;
                    fae._sleepNative(id);
                });
            };
        })();
        """
        jsContext.evaluateScript(sleepFnSource)

        let sleepBlock: @convention(block) (Int) -> Void = { sleepId in
            callbackQueue.sync {
                pendingCallbacks.append {
                    let resolver = jsContext.objectForKeyedSubscript("fae")
                        .objectForKeyedSubscript("_sleepResolvers")
                        .objectForKeyedSubscript(sleepId)
                    resolver?.call(withArguments: [])
                    jsContext.evaluateScript("delete fae._sleepResolvers[\(sleepId)];")
                }
            }
        }
        jsContext.objectForKeyedSubscript("fae")
            .setObject(sleepBlock, forKeyedSubscript: "_sleepNative" as NSString)

        // Typed adapters (fae.calendar, fae.reminders, etc.)
        JSCTypedAdapters.install(in: jsContext)

        // Wrap and evaluate the script.
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
        jsContext.evaluateScript(wrappedScript)

        if let exception = caughtException {
            return DryRunPlan(
                intendedCalls: collector.calls,
                scriptResult: .failure(error: exception, logs: collector.logs)
            )
        }

        // Drive the drain loop.
        var iterations = 0
        let maxIterations = Self.maxDrainIterations
        while iterations < maxIterations {
            iterations += 1

            // Wall-clock budget check.
            if Date().timeIntervalSince(startTime) > budget.maxWallClockSeconds {
                return DryRunPlan(
                    intendedCalls: collector.calls,
                    scriptResult: .budgetExceeded(
                        reason: "Dry-run wall-clock budget exceeded (\(Int(budget.maxWallClockSeconds))s)",
                        logs: collector.logs
                    )
                )
            }

            let batch: [() -> Void] = callbackQueue.sync {
                let current = pendingCallbacks
                pendingCallbacks = []
                return current
            }
            for callback in batch {
                callback()
            }

            let done = jsContext.objectForKeyedSubscript("__fae_done")?.toBool() ?? false
            let hasPending = callbackQueue.sync { !pendingCallbacks.isEmpty }
            if done && !hasPending {
                break
            }

            try? await Task.sleep(nanoseconds: Self.drainPollIntervalMs * 1_000_000)
        }

        // Check for script errors.
        if let jsError = jsContext.objectForKeyedSubscript("__fae_error"),
           !jsError.isUndefined
        {
            let errorStr = jsError.toString() ?? "Unknown script error"
            return DryRunPlan(
                intendedCalls: collector.calls,
                scriptResult: .failure(error: errorStr, logs: collector.logs)
            )
        }

        if let exception = caughtException {
            return DryRunPlan(
                intendedCalls: collector.calls,
                scriptResult: .failure(error: exception, logs: collector.logs)
            )
        }

        // Extract return value.
        let resultValue: String?
        if let jsResult = jsContext.objectForKeyedSubscript("__fae_result"),
           !jsResult.isUndefined, !jsResult.isNull
        {
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

        return DryRunPlan(
            intendedCalls: collector.calls,
            scriptResult: .success(value: resultValue, logs: collector.logs)
        )
    }
}

// MARK: - Dry-Run Call Collector

/// Thread-safe collector for recording tool calls during dry-run execution.
private final class DryRunCallCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fae.dryrun.collector")
    private var _calls: [DryRunIntendedCall] = []
    private var _logs: [String] = []
    private var _nextIndex = 0

    /// Record an intended tool call.
    func record(toolName: String, argumentsJSON: String) {
        queue.sync {
            let call = DryRunIntendedCall(
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                callIndex: _nextIndex
            )
            _calls.append(call)
            _nextIndex += 1
        }
    }

    /// Add a log line.
    func addLog(_ message: String) {
        queue.sync {
            _logs.append(message)
        }
    }

    /// Snapshot of all recorded calls.
    var calls: [DryRunIntendedCall] {
        queue.sync { _calls }
    }

    /// Snapshot of all log lines.
    var logs: [String] {
        queue.sync { _logs }
    }
}
