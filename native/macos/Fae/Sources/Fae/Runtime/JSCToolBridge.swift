import Foundation
import JavaScriptCore

/// Exposes a minimal `fae.*` API surface inside a JavaScriptCore context.
///
/// The bridge wires up three host functions:
///
/// - `fae.tool(name, argsJSON)` — execute a tool through ``ToolExecutor``; returns a
///   JS `Promise` that resolves with the tool result JSON or rejects on error.
/// - `fae.log(message)` — append a line to the script's captured log buffer.
/// - `fae.sleep(ms)` — returns a `Promise` that resolves after `ms` milliseconds.
///
/// All tool calls flow through the full security stack via ``ToolExecutor``.
/// The bridge is created fresh for each script execution and discarded afterward.
final class JSCToolBridge: @unchecked Sendable {

    // MARK: - State

    /// Captured log lines from `fae.log()`.
    private var logs: [String] = []

    /// Serial queue protecting mutable state (logs, pending callbacks).
    private let stateQueue = DispatchQueue(label: "fae.jsc.bridge.state")

    /// Pending callbacks that need to be invoked on the JSC thread to
    /// resolve/reject promises. Drained by ``drainPendingCallbacks(in:)``.
    private var pendingCallbacks: [() -> Void] = []

    /// The tool executor that all `fae.tool()` calls route through.
    private let executor: ToolExecutor

    /// The execution context passed to every tool call.
    private let executorContext: ToolExecutorContext

    /// The callbacks passed to every tool call.
    private let executorCallbacks: ToolExecutorCallbacks

    /// Budget tracker for enforcing tool-call and concurrency limits.
    /// When `nil`, no budget enforcement is applied (backward compat).
    private let budgetTracker: ScriptBudgetTracker?

    /// Structured execution log for developer harness debugging.
    /// When `nil`, no structured logging is performed (default path).
    private let executionLog: JSCExecutionLog?

    /// Script-scoped ticket manager for capability enforcement.
    /// When non-nil, each tool call verifies the ticket is still active.
    private let ticketManager: ScriptScopedTicketManager?

    /// The script run ID that this bridge is bound to.
    /// Used to look up the active capability ticket.
    private let scriptRunId: String?

    /// Count of in-flight async operations (tool calls + sleeps).
    /// When this reaches zero and there are no pending callbacks, the
    /// script's async work is complete.
    private var inflightCount: Int = 0

    // MARK: - Init

    /// Create a bridge wired to the given executor and per-script context.
    ///
    /// - Parameters:
    ///   - executor: The shared ``ToolExecutor`` actor.
    ///   - context: The ``ToolExecutorContext`` for this script execution.
    ///   - callbacks: The ``ToolExecutorCallbacks`` for this script execution.
    ///   - budgetTracker: Optional budget tracker for enforcing resource limits.
    ///   - executionLog: Optional structured log for developer harness debugging.
    ///   - ticketManager: Optional script-scoped ticket manager for capability enforcement.
    ///   - scriptRunId: The script run ID this bridge is bound to.
    init(
        executor: ToolExecutor,
        context: ToolExecutorContext,
        callbacks: ToolExecutorCallbacks,
        budgetTracker: ScriptBudgetTracker? = nil,
        executionLog: JSCExecutionLog? = nil,
        ticketManager: ScriptScopedTicketManager? = nil,
        scriptRunId: String? = nil
    ) {
        self.executor = executor
        self.executorContext = context
        self.executorCallbacks = callbacks
        self.budgetTracker = budgetTracker
        self.executionLog = executionLog
        self.ticketManager = ticketManager
        self.scriptRunId = scriptRunId
    }

    // MARK: - Log Access

    /// Returns a snapshot of all captured log lines.
    func capturedLogs() -> [String] {
        stateQueue.sync { logs }
    }

    // MARK: - Async Tracking

    /// Whether there are pending callbacks or in-flight async operations.
    var hasPendingWork: Bool {
        stateQueue.sync { !pendingCallbacks.isEmpty || inflightCount > 0 }
    }

    /// Drain all pending callbacks by invoking them. Call this on the thread
    /// that owns the JSContext (typically main or a dedicated JSC thread).
    ///
    /// - Parameter jsContext: The JSContext (unused directly but documents the
    ///   contract that callbacks will manipulate JSValues in this context).
    /// - Returns: The number of callbacks that were drained.
    @discardableResult
    func drainPendingCallbacks(in jsContext: JSContext) -> Int {
        let batch: [() -> Void] = stateQueue.sync {
            let current = pendingCallbacks
            pendingCallbacks = []
            return current
        }
        for callback in batch {
            callback()
        }
        return batch.count
    }

    // MARK: - Install

    /// Install the `fae` namespace object and its host functions into the given
    /// JSContext. Must be called before evaluating any script.
    ///
    /// - Parameter jsContext: The JavaScriptCore context to install into.
    func install(in jsContext: JSContext) {
        // Create the `fae` namespace object.
        jsContext.evaluateScript("var fae = {};")

        installLog(in: jsContext)
        installTool(in: jsContext)
        installSleep(in: jsContext)
    }

    // MARK: - fae.log(message)

    private func installLog(in jsContext: JSContext) {
        let logBlock: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            self.stateQueue.sync {
                self.logs.append(message)
            }
            self.executionLog?.log(.logMessage, message: message)
        }

        jsContext.objectForKeyedSubscript("fae")
            .setObject(logBlock, forKeyedSubscript: "log" as NSString)
    }

    // MARK: - fae.tool(name, argsJSON) → Promise

    private func installTool(in jsContext: JSContext) {
        // We create a JS function that returns a Promise. The Promise executor
        // stores resolve/reject references, dispatches the async work, and
        // enqueues the resolution callback to be drained by the run-loop driver.
        let bridge = self

        // Helper JS to create promises with externally-stored resolve/reject.
        // This avoids unsafeBitCast by using a well-known pattern.
        let toolFnSource = """
        (function() {
            fae._toolResolvers = {};
            fae._toolNextId = 0;
            fae._toolNative = null; // set below

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

        // Install the native callback that dispatches tool execution.
        let nativeBlock: @convention(block) (Int, String, String) -> Void = { [weak bridge] callId, name, argsJSON in
            guard let bridge else { return }

            bridge.executionLog?.log(.toolCallStart, message: "fae.tool('\(name)') initiated", toolName: name, metadata: ["callId": "\(callId)"])

            // Ticket gate: verify the script-scoped ticket still allows this tool.
            if let manager = bridge.ticketManager,
               let runId = bridge.scriptRunId
            {
                if !manager.allows(toolName: name, scriptRunId: runId) {
                    let ticketError = "Capability ticket does not allow tool '\(name)' (ticket expired or revoked)"
                    bridge.executionLog?.log(.budgetCheck, message: "Ticket rejected: \(ticketError)", toolName: name, success: false)
                    bridge.stateQueue.sync {
                        bridge.pendingCallbacks.append {
                            let resolvers = jsContext.objectForKeyedSubscript("fae")
                                .objectForKeyedSubscript("_toolResolvers")
                                .objectForKeyedSubscript(callId)
                            let jsError = JSValue(newErrorFromMessage: ticketError, in: jsContext)
                                ?? JSValue(undefinedIn: jsContext)
                            resolvers?.objectForKeyedSubscript("reject")
                                .call(withArguments: [jsError as Any])
                            jsContext.evaluateScript("delete fae._toolResolvers[\(callId)];")
                        }
                    }
                    return
                }
            }

            // Budget gate: check tool-call count, concurrency, cancellation, and deadline.
            if let tracker = bridge.budgetTracker,
               let budgetError = tracker.tryStartToolCall()
            {
                bridge.executionLog?.log(.budgetCheck, message: "Budget rejected: \(budgetError)", toolName: name, success: false)
                // Reject the promise immediately without dispatching async work.
                bridge.stateQueue.sync {
                    bridge.pendingCallbacks.append {
                        let resolvers = jsContext.objectForKeyedSubscript("fae")
                            .objectForKeyedSubscript("_toolResolvers")
                            .objectForKeyedSubscript(callId)
                        let jsError = JSValue(newErrorFromMessage: budgetError, in: jsContext)
                            ?? JSValue(undefinedIn: jsContext)
                        resolvers?.objectForKeyedSubscript("reject")
                            .call(withArguments: [jsError as Any])
                        jsContext.evaluateScript("delete fae._toolResolvers[\(callId)];")
                    }
                }
                return
            }

            bridge.stateQueue.sync { bridge.inflightCount += 1 }

            let arguments: [String: Any]
            if let data = argsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                arguments = parsed
            } else {
                arguments = [:]
            }

            let toolStartTime = Date()
            Task {
                let toolResult = await bridge.executeTool(name: name, arguments: arguments)
                let durationMs = Int(Date().timeIntervalSince(toolStartTime) * 1000)
                bridge.budgetTracker?.finishToolCall()

                switch toolResult {
                case .success:
                    bridge.executionLog?.log(.toolCallEnd, message: "fae.tool('\(name)') succeeded", toolName: name, success: true, durationMs: durationMs)
                case .failure(let errorMessage):
                    bridge.executionLog?.log(.toolCallEnd, message: "fae.tool('\(name)') failed: \(errorMessage)", toolName: name, success: false, durationMs: durationMs)
                }

                bridge.stateQueue.sync {
                    bridge.inflightCount -= 1
                    bridge.pendingCallbacks.append {
                        // This closure runs on the JSC thread during drain.
                        let resolvers = jsContext.objectForKeyedSubscript("fae")
                            .objectForKeyedSubscript("_toolResolvers")
                            .objectForKeyedSubscript(callId)

                        switch toolResult {
                        case .success(let json):
                            resolvers?.objectForKeyedSubscript("resolve")
                                .call(withArguments: [json])
                        case .failure(let errorMessage):
                            let jsError = JSValue(newErrorFromMessage: errorMessage, in: jsContext)
                                ?? JSValue(undefinedIn: jsContext)
                            resolvers?.objectForKeyedSubscript("reject")
                                .call(withArguments: [jsError as Any])
                        }

                        // Clean up resolver entry.
                        jsContext.evaluateScript("delete fae._toolResolvers[\(callId)];")
                    }
                }
            }
        }

        jsContext.objectForKeyedSubscript("fae")
            .setObject(nativeBlock, forKeyedSubscript: "_toolNative" as NSString)
    }

    // MARK: - fae.sleep(ms) → Promise

    private func installSleep(in jsContext: JSContext) {
        let sleepFnSource = """
        (function() {
            fae._sleepResolvers = {};
            fae._sleepNextId = 0;
            fae._sleepNative = null; // set below

            fae.sleep = function(ms) {
                var id = fae._sleepNextId++;
                return new Promise(function(resolve) {
                    fae._sleepResolvers[id] = resolve;
                    fae._sleepNative(id, ms);
                });
            };
        })();
        """
        jsContext.evaluateScript(sleepFnSource)

        let bridge = self
        let nativeSleep: @convention(block) (Int, Double) -> Void = { [weak bridge] sleepId, ms in
            guard let bridge else { return }

            bridge.executionLog?.log(.sleepStart, message: "fae.sleep(\(Int(ms))ms) initiated", metadata: ["sleepId": "\(sleepId)"])

            // Reject sleep immediately if cancelled.
            if let tracker = bridge.budgetTracker, tracker.isCancelled {
                bridge.executionLog?.log(.cancellation, message: "fae.sleep cancelled (script cancelled)")
                bridge.stateQueue.sync {
                    bridge.pendingCallbacks.append {
                        let resolver = jsContext.objectForKeyedSubscript("fae")
                            .objectForKeyedSubscript("_sleepResolvers")
                            .objectForKeyedSubscript(sleepId)
                        resolver?.call(withArguments: [])
                        jsContext.evaluateScript("delete fae._sleepResolvers[\(sleepId)];")
                    }
                }
                return
            }

            bridge.stateQueue.sync { bridge.inflightCount += 1 }

            let sleepStartTime = Date()
            Task {
                let delayNs = UInt64(max(ms, 0) * 1_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                let durationMs = Int(Date().timeIntervalSince(sleepStartTime) * 1000)

                bridge.executionLog?.log(.sleepEnd, message: "fae.sleep(\(Int(ms))ms) completed", durationMs: durationMs)

                bridge.stateQueue.sync {
                    bridge.inflightCount -= 1
                    bridge.pendingCallbacks.append {
                        let resolver = jsContext.objectForKeyedSubscript("fae")
                            .objectForKeyedSubscript("_sleepResolvers")
                            .objectForKeyedSubscript(sleepId)
                        resolver?.call(withArguments: [])
                        jsContext.evaluateScript("delete fae._sleepResolvers[\(sleepId)];")
                    }
                }
            }
        }

        jsContext.objectForKeyedSubscript("fae")
            .setObject(nativeSleep, forKeyedSubscript: "_sleepNative" as NSString)
    }

    // MARK: - Tool Execution

    private enum ToolCallResult {
        case success(String)
        case failure(String)
    }

    private func executeTool(name: String, arguments: [String: Any]) async -> ToolCallResult {
        let call = PipelineCoordinator.ToolCall(name: name, arguments: arguments)
        let result = await executor.execute(call, context: executorContext, callbacks: executorCallbacks)

        if result.result.isError {
            return .failure(result.result.output)
        }
        // Return the script envelope so JS callers get both prose and structured data.
        return .success(result.result.scriptEnvelope())
    }
}
