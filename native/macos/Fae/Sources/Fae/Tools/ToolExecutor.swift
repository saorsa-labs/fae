import Foundation

/// Standalone actor that encapsulates the tool execution pipeline.
///
/// Simplified from the original 14-layer security stack to a direct flow:
///
/// 1. Registry lookup + rescue mode + tool mode filtering
/// 2. Proactive allowlist + TillDone gate + computer-use step limit
/// 3. DamageControlPolicy evaluate (bash patterns, path rules)
///    - Block → hard deny
///    - Disaster → narrate + countdown (barge-in cancel)
///    - ConfirmManual → narrate + countdown
///    - Allow → proceed
/// 4. Pre-state capture, plugin hooks, timeout-wrapped execution
/// 5. Post-execution: analytics, security log, receipt, narration
///
/// Voice identity is the security model — verified owner gets full access.
/// DamageControlPolicy remains as the safety net for catastrophic operations.

/// Protocol for tool executor functionality, enabling test doubles.
///
/// Conformed to by the real `ToolExecutor` actor and test-only mock
/// executors.
protocol ToolExecutorProtocol: Actor {
    func execute(
        _ call: ToolCall,
        context: ToolExecutorContext,
        callbacks: ToolExecutorCallbacks
    ) async -> ToolExecutorResult
}

actor ToolExecutor: ToolExecutorProtocol {

    // MARK: - Dependencies

    let registry: ToolRegistry
    let damageControlPolicy: DamageControlPolicy
    let securityLogger: any SecurityEventLogging
    let workflowTraceStore: WorkflowTraceStore?
    let toolAnalytics: (any ToolAnalyticsRecording)?
    weak var delegate: (any ToolExecutorDelegate)?
    nonisolated(unsafe) var debugConsole: DebugConsoleController?

    /// Plugin hook runner for PreToolUse / PostToolUse hooks.
    var pluginHookRunner: (any PluginHookRunning)?

    /// Action receipt store for undo/reversibility. Set after init by FaeCore.
    var receiptStore: ReceiptStore?

    /// The long-lived daemon ToolHost session (B-Swift Layer 2). Layer 3b routes
    /// `read` through it, confined to the default workspace. Non-optional: one
    /// instance per executor/pipeline. When the production caller
    /// (`PipelineCoordinator`) does not inject one, it is built from
    /// `daemonIntendedForToolhostRouting` (which mirrors
    /// `FaeConfig.llm.useDaemonEngine`) so the no-daemon fallback policy is
    /// config-driven, not a silent default. An absent daemon then degrades to
    /// a CONFINED local read (intended) or legacy local read (opted out) inside
    /// `DaemonToolRouting`.
    let daemonToolHostSession: DaemonToolHostSession

    /// B-Swift Phase C/#5 test seam: the routed-read executor. Defaults to the
    /// real `DaemonToolRouting.routeRead(call:session:plan:)`. Tests inject a
    /// canned or stalling closure to assert hooks/audit/timeout WITHOUT a real
    /// daemon. Production is unchanged (the default delegates to the real
    /// router). Set via `setRoutedReadExecutorForTesting`.
    private var routedReadExecutor: @Sendable (
        ToolCall, DaemonToolHostSession, DaemonToolRouting.ReadRoutePlan
    ) async -> ToolResult = { call, session, plan in
        await DaemonToolRouting.routeRead(call: call, session: session, plan: plan)
    }

    /// B-Swift Phase C/#5 test seam: override the routed-read timeout (seconds).
    /// Nil → use `toolTimeoutSeconds(for:)` (production = 30s for `read`). Tests
    /// set a short value so a stalling injected executor closure trips the
    /// timeout without a 30s wait.
    private var routedReadTimeoutOverride: TimeInterval?

    // MARK: - Constants

    /// Maximum computer-use action steps (click/type_text/scroll) per turn.
    static let maxComputerUseSteps = 10

    private static let defaultToolTimeoutSeconds: TimeInterval = 30
    private static let extendedVisionToolTimeoutSeconds: TimeInterval = 180

    // MARK: - Init

    init(
        registry: ToolRegistry,
        damageControlPolicy: DamageControlPolicy,
        securityLogger: any SecurityEventLogging,
        workflowTraceStore: WorkflowTraceStore? = nil,
        toolAnalytics: (any ToolAnalyticsRecording)? = nil,
        delegate: (any ToolExecutorDelegate)? = nil,
        debugConsole: DebugConsoleController? = nil,
        daemonIntendedForToolhostRouting: Bool
    ) {
        self.registry = registry
        self.damageControlPolicy = damageControlPolicy
        self.securityLogger = securityLogger
        self.workflowTraceStore = workflowTraceStore
        self.toolAnalytics = toolAnalytics
        self.delegate = delegate
        self.debugConsole = debugConsole
        // Build a session from the EXPLICIT config-derived flag. There is NO
        // silent default: `daemonIntendedForToolhostRouting` is unlabeled on
        // purpose so every construction site must state its intent (production
        // passes `runtimeConfig.llm.useDaemonEngine`; tests/harness pass `false`
        // to preserve legacy local tool behavior). This prevents a harness from
        // accidentally opting into the confined local fallback (which would
        // reject absolute paths the harness legitimately uses).
        self.daemonToolHostSession =
            DaemonToolHostSession(daemonIntended: daemonIntendedForToolhostRouting)
    }

    /// Session-injecting initializer (tests). The injected session carries its
    /// own `daemonIntended`, so the fallback branch is governed by the session,
    /// not a separate flag here. Use this for routing tests that inject a temp
    /// workspace provider + an explicit intent.
    init(
        registry: ToolRegistry,
        damageControlPolicy: DamageControlPolicy,
        securityLogger: any SecurityEventLogging,
        workflowTraceStore: WorkflowTraceStore? = nil,
        toolAnalytics: (any ToolAnalyticsRecording)? = nil,
        delegate: (any ToolExecutorDelegate)? = nil,
        debugConsole: DebugConsoleController? = nil,
        daemonToolHostSession: DaemonToolHostSession
    ) {
        self.registry = registry
        self.damageControlPolicy = damageControlPolicy
        self.securityLogger = securityLogger
        self.workflowTraceStore = workflowTraceStore
        self.toolAnalytics = toolAnalytics
        self.delegate = delegate
        self.debugConsole = debugConsole
        self.daemonToolHostSession = daemonToolHostSession
    }

    /// Wire the delegate after init (since `self` is not available during actor init).
    func setDelegate(_ delegate: (any ToolExecutorDelegate)?) {
        self.delegate = delegate
    }

    /// Forward the debug console from the owning coordinator.
    func setDebugConsole(_ console: DebugConsoleController?) {
        debugConsole = console
    }

    /// Wire plugin hook runner for PreToolUse / PostToolUse hooks.
    func setPluginHookRunner(_ runner: (any PluginHookRunning)?) {
        pluginHookRunner = runner
    }

    /// Wire the action receipt store for undo/reversibility tracking.
    func setReceiptStore(_ store: ReceiptStore) {
        receiptStore = store
    }

    // MARK: - Execute

    /// Execute a single tool call through the simplified pipeline.
    ///
    /// - Parameters:
    ///   - call: The parsed tool call from the LLM.
    ///   - context: All per-call runtime state (built by the caller).
    ///   - callbacks: Closures to push side effects back to the caller.
    /// - Returns: The tool result plus execution metadata.
    func execute(
        _ call: ToolCall,
        context: ToolExecutorContext,
        callbacks: ToolExecutorCallbacks
    ) async -> ToolExecutorResult {
        // Record the tool call, then delegate to the inner pipeline.
        // The result trace is recorded once at this single exit point.
        await traceToolCall(call: call, context: context)
        let startTime = Date()
        let outcome = await executeInner(call, context: context, callbacks: callbacks)
        let totalLatencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        await traceToolResult(
            call: call,
            context: context,
            result: outcome.result,
            approved: outcome.approvedByUser,
            latencyMs: totalLatencyMs
        )
        return ToolExecutorResult(
            result: outcome.result,
            approvedByUser: outcome.approvedByUser,
            damageControlIntervened: outcome.damageControlIntervened,
            latencyMs: totalLatencyMs
        )
    }

    /// Inner execution — simplified pipeline.
    /// Trace recording is handled by the caller (`execute`).
    private func executeInner(
        _ call: ToolCall,
        context: ToolExecutorContext,
        callbacks: ToolExecutorCallbacks
    ) async -> ToolExecutorResult {

        // ── 1. Tool mode / privacy enforcement ──────────────────────────
        debugLog(debugConsole, .toolCall, "Execute request: \(call.name) mode=\(context.toolMode) privacy=\(context.privacyMode)")
        guard registry.isToolAllowed(call.name, mode: context.toolMode, privacyMode: context.privacyMode) else {
            debugLog(debugConsole, .toolResult, "Blocked by mode/privacy: \(call.name) mode=\(context.toolMode) privacy=\(context.privacyMode)")
            if context.toolMode == "assistant" {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .faeToolModeUpgradeRequested,
                        object: nil,
                        userInfo: ["reason": "toolMode=assistant"]
                    )
                }
            }
            return ToolExecutorResult(
                result: .error("Tool '\(call.name)' is not available in read-only mode. The user can switch to 'Everything (with approval)' to enable this tool."),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: nil
            )
        }

        // ── 2. Proactive allowlist ──────────────────────────────────────
        if let proactiveContext = context.proactiveContext,
           !proactiveContext.allowedTools.contains(call.name)
        {
            debugLog(debugConsole, .toolResult, "Blocked by proactive allowlist: \(call.name) task=\(proactiveContext.taskId)")
            return ToolExecutorResult(
                result: .error("Tool '\(call.name)' is not allowed for proactive task '\(proactiveContext.taskId)'"),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: nil
            )
        }

        // ── 3. TillDone hard gate ───────────────────────────────────────
        if call.name != "till_done",
           context.proactiveContext == nil,
           await TillDoneManager.shared.isListActive
        {
            let hasInprogress = await TillDoneManager.shared.currentTask != nil
            let allComplete = await TillDoneManager.shared.allDone
            if !hasInprogress && !allComplete {
                let hasTasks = await TillDoneManager.shared.hasActiveTasks
                let msg: String
                if !hasTasks {
                    msg = "All TillDone tasks are done or skipped. Use till_done report to generate the summary, or till_done add to add more tasks."
                } else {
                    msg = "No task is in progress. Use till_done start to mark a task as inprogress before doing any work."
                }
                debugLog(debugConsole, .toolResult, "TillDone gate blocked \(call.name): \(msg)")
                return ToolExecutorResult(
                    result: .error(msg),
                    approvedByUser: nil,
                    damageControlIntervened: false,
                        latencyMs: nil
                )
            }
        }

        // ── 4. Computer-use step limit ──────────────────────────────────
        let actionTools: Set<String> = ["click", "type_text", "scroll"]
        if actionTools.contains(call.name) {
            let stepCount = await callbacks.onComputerUseStep()
            if stepCount > Self.maxComputerUseSteps {
                return ToolExecutorResult(
                    result: .error("Computer use step limit reached (\(Self.maxComputerUseSteps) per turn). Ask the user before continuing."),
                    approvedByUser: nil,
                    damageControlIntervened: false,
                        latencyMs: nil
                )
            }
        }

        // ── 5. Vision auto-enable ───────────────────────────────────────
        let visionTools: Set<String> = ["screenshot", "camera", "read_screen",
                                         "click", "type_text", "scroll", "find_element"]
        if visionTools.contains(call.name), !context.visionEnabled {
            await callbacks.onVisionAutoEnabled()
            debugLog(debugConsole, .pipeline, "Vision auto-enabled: user approved a vision tool")
        }

        // ── 6. Tool lookup ──────────────────────────────────────────────
        let vlmProvider = await delegate?.toolExecutorVLMProvider()
        guard let tool = registry.tool(named: call.name, vlmProvider: vlmProvider) else {
            return ToolExecutorResult(
                result: .error("Unknown tool: \(call.name)"),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: nil
            )
        }

        // ── 6b. Daemon routing (B-Swift Layer 3b + Phase C/#5) ──────────
        // Route safe portable tools (ONLY `read` in 3b) to the governed daemon
        // ToolHost, confined to the default workspace. This runs AFTER the
        // deterministic gates (1-5) and BEFORE DamageControl (7), so a
        // daemon-routed read is governed by the daemon (path/damage/egress + its
        // own tool.confirm) and never double-approved in Swift.
        //
        // Phase C / follow-up #5 (LOCKED 2026-06-30): decide the route FIRST
        // (`planReadRoute` — no side effect), then:
        //  - `.legacyLocal` (opted-out + no daemon) → fall through to the FULL
        //    local pipeline (DamageControl, hooks, audit, receipts) unchanged;
        //  - `.daemonReachable` / `.confinedLocalFallback` → run the routed-read
        //    branch (`executeRoutedRead`), which mirrors the local pipeline's
        //    PreToolUse hooks + timeout + PostToolUse hooks + audit/analytics,
        //    skipping ONLY DamageControl (the daemon governs) and receipts (no
        //    mutation). This closes the policy bypass: a user-configured read
        //    hook now applies to routed reads too, and the 30s executor timeout
        //    + SecurityEventLogger/ToolAnalytics rows fire (the daemon's
        //    `audit.jsonl` is a complement, not a substitute). `read` is the
        //    precedent-setter — Layer 4 routes write/edit/bash through this seam.
        if DaemonToolRouting.routedTools.contains(call.name) {
            let plan = await DaemonToolRouting.planReadRoute(session: daemonToolHostSession)
            if plan != .legacyLocal {
                return await executeRoutedRead(call: call, plan: plan, context: context)
            }
            // .legacyLocal → fall through to the local pipeline (legacy
            // pre-routing local read via the full pipeline, unconfined).
        }

        // ── 7. DamageControlPolicy ──────────────────────────────────────
        var workflowDamageControlIntervened = false
        let dcVerdict = await damageControlPolicy.evaluate(
            toolName: call.name,
            arguments: call.arguments,
            locality: context.modelLocality
        )
        switch dcVerdict {
        case .allow:
            break

        case .block(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_block",
                toolName: call.name,
                decision: "deny",
                reasonCode: "damageControlBlock",
                approved: nil,
                success: nil,
                error: nil,
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC block: \(call.name) — \(reason)")
            return ToolExecutorResult(
                result: .error("Blocked by damage-control policy: \(reason)"),
                approvedByUser: nil,
                damageControlIntervened: true,
                latencyMs: nil
            )

        case .disaster(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_disaster",
                toolName: call.name,
                decision: "confirm",
                reasonCode: "damageControlDisaster",
                approved: nil,
                success: nil,
                error: nil,
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC disaster: \(call.name) — \(reason)")
            // Narrate the danger + countdown. User can barge-in to cancel.
            let shouldProceed = await delegate?.toolExecutorCountdownBeforeIrreversible(
                "This looks dangerous: \(reason). Proceeding in 5 seconds. Say stop to cancel."
            ) ?? false
            if !shouldProceed {
                return ToolExecutorResult(
                    result: .error("Action cancelled: \(reason)"),
                    approvedByUser: false,
                    damageControlIntervened: true,
                    latencyMs: nil
                )
            }

        case .confirmManual(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_confirm_manual",
                toolName: call.name,
                decision: "confirm",
                reasonCode: "damageControlConfirmManual",
                approved: nil,
                success: nil,
                error: nil,
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC confirm manual: \(call.name) — \(reason)")
            // Narrate + countdown for manual confirmation.
            let shouldProceed = await delegate?.toolExecutorCountdownBeforeIrreversible(
                "\(reason). Proceeding in 5 seconds. Say stop to cancel."
            ) ?? false
            if !shouldProceed {
                return ToolExecutorResult(
                    result: .error("Action cancelled: \(reason)"),
                    approvedByUser: false,
                    damageControlIntervened: true,
                    latencyMs: nil
                )
            }
        }

        // ── 8. Argument augmentation (shared helper) ────────────────────
        let executionArguments = computeExecutionArguments(for: call, context: context)

        // ── 9. Plugin PreToolUse hooks (shared helper) ─────────────────
        if let blocked = await runPreToolUseHooks(toolName: call.name, arguments: executionArguments) {
            return blocked
        }

        // ── 10. Pre-state capture (BEFORE execution) ────────────────────
        let preState = receiptStore?.capturePreStateForTool(toolName: call.name, arguments: call.arguments)

        // ── 11. Irreversible countdown ──────────────────────────────────
        // For high-impact irreversible actions (mail send, agent delegation),
        // present a 5-second countdown so the user can barge in to cancel.
        // Skip for proactive tasks (no user present).
        if context.proactiveContext == nil,
           Self.requiresCountdown(toolName: call.name, arguments: call.arguments)
        {
            let countdownText = Self.buildCountdownText(toolName: call.name, arguments: call.arguments)
            let shouldProceed = await delegate?.toolExecutorCountdownBeforeIrreversible(countdownText) ?? true
            if !shouldProceed {
                return ToolExecutorResult(
                    result: .error("Action cancelled by user during countdown."),
                    approvedByUser: false,
                    damageControlIntervened: false,
                    latencyMs: nil
                )
            }
        }

        // ── 12. Execute with timeout ────────────────────────────────────
        let timeoutSeconds = Self.toolTimeoutSeconds(for: call.name)
        let startTime = Date()
        let result: ToolResult
        do {
            result = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await tool.execute(input: executionArguments)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .error("Tool timed out after \(Int(timeoutSeconds))s")
                }
                guard let r = try await group.next() else {
                    group.cancelAll()
                    return .error("Tool execution did not return a result")
                }
                group.cancelAll()
                return r
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Tool threw error: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            await recordToolOutcome(
                toolName: call.name,
                arguments: call.arguments,
                success: false,
                error: error.localizedDescription,
                startTime: startTime)
            return ToolExecutorResult(
                result: .error("Tool error: \(error.localizedDescription)"),
                approvedByUser: nil,
                damageControlIntervened: workflowDamageControlIntervened,
                latencyMs: nil
            )
        }

        // ── 13. Plugin PostToolUse hooks (shared helper) ────────────────
        await runPostToolUseHooks(toolName: call.name, output: result.output)

        // ── 14. Post-execution analytics + logging (shared helper) ──────
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        await recordToolOutcome(
            toolName: call.name,
            arguments: call.arguments,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            startTime: startTime)

        // ── 15. Action receipt ──────────────────────────────────────────
        var narrationReceiptId: String?
        if !result.isError, let store = receiptStore {
            narrationReceiptId = await store.createReceipt(
                toolName: call.name,
                arguments: call.arguments,
                preState: preState,
                speakerId: context.speakerId,
                sessionId: nil,
                turnId: context.workflowTurnID
            )
        }

        // ── 16. Post-action narration ───────────────────────────────────
        let reversibility = ActionReversibility.classify(toolName: call.name, arguments: call.arguments)
        if !result.isError,
           reversibility != .notApplicable,
           context.proactiveContext == nil
        {
            if let narrationText = Self.buildNarrationText(toolName: call.name, arguments: call.arguments) {
                await delegate?.toolExecutorNarrateAction(narrationText, receiptId: narrationReceiptId)
            }
        }

        return ToolExecutorResult(
            result: result,
            approvedByUser: nil,
            damageControlIntervened: workflowDamageControlIntervened,
            latencyMs: nil
        )
    }

    // MARK: - B-Swift Phase C / follow-up #5: routed-read executor branch

    /// Execute a routed `read` (`.daemonReachable` or `.confinedLocalFallback`)
    /// through the shared pipeline shape: PreToolUse hooks → timeout-wrapped
    /// routed execute → PostToolUse hooks → audit/analytics. Skips ONLY
    /// DamageControl (the daemon governs) and receipts (no mutation).
    ///
    /// Race rule (advisor C3): the `plan` was fixed BEFORE any side effect
    /// (`planReadRoute`), so the route is deterministic — no fall-through to the
    /// legacy `ReadTool` after DamageControl was skipped. The routed executor's
    /// own fail-closed semantics apply (fail CLOSED before root approval;
    /// confined local fallback only AFTER the daemon-approved root).
    private func executeRoutedRead(
        call: ToolCall,
        plan: DaemonToolRouting.ReadRoutePlan,
        context: ToolExecutorContext
    ) async -> ToolExecutorResult {
        // Augment args with execution-time context (mirrors local step 8) so
        // PreToolUse hooks see the same input on both paths. For `read` this is
        // currently a no-op; the seam exists for Layer 4 (write/edit/bash)
        // precedent (Phase C/#5, code-review S1).
        let executionArguments = computeExecutionArguments(for: call, context: context)

        // ── PreToolUse hooks (BEFORE any daemon/root/provision side effect).
        if let blocked = await runPreToolUseHooks(
            toolName: call.name, arguments: executionArguments)
        {
            return blocked
        }

        // ── Timeout-wrapped routed execute (mirrors step 12).
        let timeoutSeconds = routedReadTimeoutOverride ?? Self.toolTimeoutSeconds(for: call.name)
        let startTime = Date()
        let result: ToolResult
        do {
            // Capture the closure + session values before the task group so the
            // child task crosses isolation with Sendable captures only.
            let executor = routedReadExecutor
            let session = daemonToolHostSession
            result = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    await executor(call, session, plan)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .error("Tool timed out after \(Int(timeoutSeconds))s")
                }
                guard let r = try await group.next() else {
                    group.cancelAll()
                    return .error("Tool execution did not return a result")
                }
                group.cancelAll()
                return r
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Routed read threw: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            await recordToolOutcome(
                toolName: call.name,
                arguments: call.arguments,
                success: false,
                error: error.localizedDescription,
                startTime: startTime)
            return ToolExecutorResult(
                result: .error("Tool error: \(error.localizedDescription)"),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: latencyMs
            )
        }

        // ── PostToolUse hooks.
        await runPostToolUseHooks(toolName: call.name, output: result.output)

        // ── Analytics + audit (mirrors step 14). Receipts SKIPPED (no mutation).
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        await recordToolOutcome(
            toolName: call.name,
            arguments: call.arguments,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            startTime: startTime)

        return ToolExecutorResult(
            result: result,
            approvedByUser: nil,
            damageControlIntervened: false,
            latencyMs: latencyMs
        )
    }

    #if FAE_TEST_SEAMS
    /// Test seam setter (Phase C/#5): override the routed-read executor.
    /// GUARDED: `FAE_TEST_SEAMS` is defined only in `.debug` (Package.swift
    /// `swiftSettings` `.when(configuration: .debug)`), so these setters are
    /// compiled OUT of release builds — no production binary can override
    /// routed-read confinement/timeout (red-team F4).
    func setRoutedReadExecutorForTesting(
        _ fn: @Sendable @escaping (
            ToolCall, DaemonToolHostSession, DaemonToolRouting.ReadRoutePlan
        ) async -> ToolResult
    ) {
        routedReadExecutor = fn
    }

    /// Test seam setter (Phase C/#5): override the routed-read timeout.
    func setRoutedReadTimeoutForTesting(_ seconds: TimeInterval?) {
        routedReadTimeoutOverride = seconds
    }
    #endif

    // MARK: - Shared tool-execution helpers (local + routed pipeline)

    /// Augment tool arguments with execution-time context (e.g. voice-identity
    /// enrollment). Shared by the local pipeline (step 8) and the routed-read
    /// branch so PreToolUse hooks see identical input on both paths (Phase C/#5,
    /// Layer 4 precedent — code-review S1).
    private func computeExecutionArguments(
        for call: ToolCall, context: ToolExecutorContext
    ) -> [String: Any] {
        var args = call.arguments
        if call.name == "voice_identity",
           let action = args["action"] as? String,
           action == "collect_sample"
        {
            args["enrollment_active"] = context.firstOwnerEnrollmentActive
        }
        return args
    }

    /// Run PreToolUse plugin hooks. Returns a blocking `ToolExecutorResult` if a
    /// hook blocks (the caller returns it immediately); nil to proceed. Shared
    /// by the local pipeline (step 9) and the routed-read branch so BOTH honor
    /// user-configured read hooks (Phase C/#5 — closes the routed-read bypass).
    private func runPreToolUseHooks(
        toolName: String, arguments: [String: Any]
    ) async -> ToolExecutorResult? {
        guard let hookRunner = pluginHookRunner,
              await hookRunner.hasHooks(for: .preToolUse)
        else { return nil }
        let hookInput = HookInput.preToolUse(toolName: toolName, toolInput: arguments)
        let hookResponse = await hookRunner.runHooks(event: .preToolUse, input: hookInput)
        guard hookResponse.shouldBlock else { return nil }
        let blockMsg = hookResponse.systemMessage ?? "Blocked by plugin hook"
        debugLog(debugConsole, .toolResult, "Plugin hook blocked \(toolName): \(blockMsg)")
        return ToolExecutorResult(
            result: .error(blockMsg),
            approvedByUser: nil,
            damageControlIntervened: false,
            latencyMs: nil
        )
    }

    /// Run PostToolUse plugin hooks (informational; no return). Shared by the
    /// local pipeline (step 13) and the routed-read branch.
    private func runPostToolUseHooks(
        toolName: String, output: String
    ) async {
        guard let hookRunner = pluginHookRunner,
              await hookRunner.hasHooks(for: .postToolUse)
        else { return }
        let hookInput = HookInput.postToolUse(
            toolName: toolName, toolOutput: String(output.prefix(2000)))
        let hookResponse = await hookRunner.runHooks(event: .postToolUse, input: hookInput)
        if let msg = hookResponse.systemMessage, !msg.isEmpty {
            debugLog(debugConsole, .toolResult, "Plugin PostToolUse hook message for \(toolName): \(msg)")
        }
    }

    /// Record a tool outcome to ToolAnalytics + SecurityEventLogger (mirrors step
    /// 14). Shared by the local pipeline and the routed-read branch so BOTH emit
    /// a Swift audit row + analytics event (Phase C/#5: daemon `audit.jsonl` is
    /// a complement, not a substitute). Returns the measured latency in ms.
    @discardableResult
    private func recordToolOutcome(
        toolName: String,
        arguments: [String: Any],
        success: Bool,
        error: String?,
        startTime: Date,
        decision: String = "allow",
        reasonCode: String? = nil
    ) async -> Int {
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        if let analytics = toolAnalytics {
            await analytics.record(
                toolName: toolName, success: success, latencyMs: latencyMs,
                approved: nil, error: error)
        }
        await securityLogger.log(
            event: "tool_result", toolName: toolName, decision: decision,
            reasonCode: reasonCode, approved: nil, success: success,
            error: error, arguments: arguments)
        return latencyMs
    }

    // MARK: - Workflow Trace Recording

    static func serializeArguments(_ args: [String: Any]) -> String {
        ToolRoutingHelpers.serializeArguments(args)
    }

    /// Record a `tool_call` step in the workflow trace.
    private func traceToolCall(
        call: ToolCall,
        context: ToolExecutorContext
    ) async {
        guard let store = workflowTraceStore,
              let runID = context.workflowRunID
        else { return }
        do {
            try await store.appendStep(
                runId: runID,
                toolCallId: context.traceToolCallID,
                stepType: .toolCall,
                toolName: call.name,
                sanitizedInputJSON: Self.serializeArguments(call.arguments),
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
        } catch {
            NSLog("ToolExecutor: workflow tool-call trace error: %@", error.localizedDescription)
        }
    }

    /// Record a `tool_result` step in the workflow trace.
    private func traceToolResult(
        call: ToolCall,
        context: ToolExecutorContext,
        result: ToolResult,
        approved: Bool?,
        latencyMs: Int?
    ) async {
        guard let store = workflowTraceStore,
              let runID = context.workflowRunID
        else { return }
        do {
            try await store.appendStep(
                runId: runID,
                toolCallId: context.traceToolCallID,
                stepType: .toolResult,
                toolName: call.name,
                sanitizedInputJSON: nil,
                outputPreview: result.output,
                success: !result.isError,
                approved: approved,
                latencyMs: latencyMs
            )
        } catch {
            NSLog("ToolExecutor: workflow tool-result trace error: %@", error.localizedDescription)
        }
    }

    // MARK: - Static Helpers

    /// Per-tool timeout: vision tools get an extended budget.
    static func toolTimeoutSeconds(for toolName: String) -> TimeInterval {
        switch toolName {
        case "screenshot", "camera", "read_screen":
            return extendedVisionToolTimeoutSeconds
        default:
            return defaultToolTimeoutSeconds
        }
    }

    /// Self-config actions that are read-only and should bypass approval.
    private static let selfConfigReadActions: Set<String> = [
        "get_settings", "get_directive", "get_instructions",
    ]

    /// Whether a self_config call is a read-only action.
    static func isSelfConfigReadAction(arguments: [String: Any]) -> Bool {
        guard let action = (arguments["action"] as? String)?.lowercased() else { return false }
        return selfConfigReadActions.contains(action)
    }

    /// Whether a tool invocation requires user approval, accounting for
    /// tool-specific overrides (self_config reads, calendar/reminders creates).
    static func toolRequiresApproval(
        toolName: String,
        arguments: [String: Any],
        defaultRequiresApproval: Bool
    ) -> Bool {
        if toolName == "self_config" {
            return !isSelfConfigReadAction(arguments: arguments)
        }
        if toolName == "calendar" {
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            if action == "create" {
                return true
            }
        }
        if toolName == "reminders" {
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            if action == "create" || action == "complete" {
                return true
            }
        }
        return defaultRequiresApproval
    }

    /// Build a plain-language confirmation prompt with concrete action context.
    static func buildApprovalDescription(
        toolName: String, reason: String, arguments: [String: Any]
    ) -> String {
        let summary: String
        switch toolName {
        case "bash":
            if let command = arguments["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.count > 140 ? String(trimmed.prefix(140)) + "..." : trimmed
                summary = "I can run this command: \(preview)."
            } else {
                summary = "I can run a shell command for this step."
            }

        case "write":
            if let path = arguments["path"] as? String {
                summary = "I can write to \(path)."
            } else {
                summary = "I can write file content for this step."
            }

        case "edit":
            if let path = arguments["path"] as? String {
                summary = "I can edit \(path)."
            } else {
                summary = "I can edit a file for this step."
            }

        case "self_config":
            let action = (arguments["action"] as? String)?.lowercased() ?? ""
            if selfConfigReadActions.contains(action) {
                summary = "I can check your current settings."
            } else if action == "adjust_setting" {
                let key = arguments["key"] as? String ?? "a setting"
                summary = "I can update \(key)."
            } else if action.contains("directive") || action.contains("instructions") {
                switch action {
                case "set_directive", "set_instructions":
                    summary = "I can replace your persistent directive."
                case "append_directive", "append_instructions":
                    summary = "I can append to your persistent directive."
                case "clear_directive", "clear_instructions":
                    summary = "I can clear your persistent directive."
                default:
                    summary = "I can update your persistent directive."
                }
            } else {
                summary = "I can update your Fae settings."
            }

        case "run_skill":
            let skillName = arguments["name"] as? String ?? "a skill"
            summary = "I can run \(skillName) now."

        case "manage_skill":
            let action = arguments["action"] as? String ?? "modify"
            summary = "I can \(action) a skill in your local skills library."

        case "delegate_agent":
            let provider = arguments["provider"] as? String ?? "an external agent"
            let mode = arguments["mode"] as? String ?? "read_only"
            summary = "I can delegate this task to \(provider) in \(mode) mode."

        case "scheduler_create":
            summary = "I can create a scheduled task that runs automatically later."

        case "scheduler_update":
            summary = "I can update a scheduled task."

        case "scheduler_delete":
            summary = "I can delete this scheduled task."

        default:
            summary = "I can use \(toolName) for this step."
        }

        return "\(summary) Say yes or no, or press the Yes/No button."
    }

    /// Whether a skill name is safe for filesystem use (alphanumeric, hyphens, underscores).
    static func isSafeSkillName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..") || trimmed.contains("~") { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Narration + Countdown Helpers

    /// Build a short human-readable narration for a completed tool action.
    ///
    /// Returns `nil` if no natural narration phrase is available for this tool.
    /// Narration is only called for write-class tools (reversibility != .notApplicable).
    static func buildNarrationText(toolName: String, arguments: [String: Any]) -> String? {
        switch toolName {
        case "write":
            if let path = arguments["path"] as? String {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return "I've saved that to \(filename)."
            }
            return "I've written that file."

        case "edit":
            if let path = arguments["path"] as? String {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return "I've updated \(filename)."
            }
            return "I've made that edit."

        case "bash":
            if let command = arguments["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("mkdir ") { return "I've created that folder." }
                if trimmed.hasPrefix("cp ")    { return "I've copied that file." }
                if trimmed.hasPrefix("mv ")    { return "I've moved that file." }
                if trimmed.hasPrefix("touch ") { return "Done." }
                if trimmed.hasPrefix("echo ")  { return "I've written that." }
            }
            return nil

        case "calendar":
            let action = arguments["action"] as? String ?? ""
            if action == "create" { return "I've added that to your calendar." }
            if action == "update" { return "I've updated that calendar event." }
            if action == "delete" { return "I've removed that calendar event." }
            return nil

        case "reminders":
            let action = arguments["action"] as? String ?? ""
            if action == "create" { return "I've added that reminder." }
            if action == "update" { return "I've updated that reminder." }
            if action == "complete" { return "I've marked that reminder done." }
            if action == "delete" { return "I've deleted that reminder." }
            return nil

        case "contacts":
            let action = arguments["action"] as? String ?? ""
            if action == "create" { return "I've added that contact." }
            if action == "update" { return "I've updated that contact." }
            if action == "delete" { return "I've deleted that contact." }
            return nil

        case "notes":
            let action = arguments["action"] as? String ?? ""
            if action == "create" { return "I've created that note." }
            if action == "update" { return "I've updated that note." }
            if action == "delete" { return "I've deleted that note." }
            return nil

        case "self_config":
            let op = arguments["operation"] as? String ?? ""
            if op == "set" { return "I've updated that setting." }
            if op == "set_directive" || op == "append_directive" { return "I've updated your directive." }
            if op == "clear_directive" { return "I've cleared your directive." }
            return nil

        case "scheduler_create":
            return "I've scheduled that task."
        case "scheduler_update":
            return "I've updated that scheduled task."
        case "scheduler_delete":
            return "I've removed that scheduled task."

        case "manage_skill":
            let action = arguments["action"] as? String ?? ""
            if action == "install" || action == "enable" { return "Skill ready." }
            if action == "disable" || action == "uninstall" { return "Done." }
            return nil

        case "voice_identity":
            let action = arguments["action"] as? String ?? ""
            if action == "enroll" { return "I've enrolled that voice profile." }
            if action == "delete" { return "I've removed that voice profile." }
            return nil

        case "channel_setup":
            return "Channel configured."

        case "plugin_manage":
            return "Done."

        default:
            return nil
        }
    }

    /// Tools that require a countdown announcement before execution.
    ///
    /// Only high-impact irreversible actions that the user should have a
    /// chance to cancel: mail sends, agent delegation.
    static func requiresCountdown(toolName: String, arguments: [String: Any]) -> Bool {
        switch toolName {
        case "mail":
            let action = arguments["action"] as? String ?? ""
            return action == "send" || action == "reply" || action == "forward"

        case "delegate_agent", "agent_session":
            return true

        default:
            return false
        }
    }

    /// Build the countdown announcement text for an irreversible action.
    static func buildCountdownText(toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "mail":
            let action = arguments["action"] as? String ?? "send"
            if action == "reply" {
                return "Sending that reply in 5 seconds. Say stop to cancel."
            } else if action == "forward" {
                return "Forwarding that in 5 seconds. Say stop to cancel."
            }
            return "Sending that email in 5 seconds. Say stop to cancel."

        case "delegate_agent":
            return "Starting that task in 5 seconds. Say stop to cancel."

        case "agent_session":
            return "Opening that agent session in 5 seconds. Say stop to cancel."

        default:
            return "Proceeding in 5 seconds. Say stop to cancel."
        }
    }
}
