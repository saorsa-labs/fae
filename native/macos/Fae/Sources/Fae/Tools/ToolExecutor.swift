import Foundation

/// Standalone actor that encapsulates the full tool execution security stack.
///
/// Extracted from `PipelineCoordinator.executeTool()` so that both the existing
/// pipeline tool-call path and the new JSC tool-program runtime can share the
/// same governance enforcement:
///
/// 1. Tool mode / privacy filtering
/// 2. Proactive allowlist check
/// 3. TillDone hard gate
/// 4. Computer-use step limit
/// 5. Vision auto-enable
/// 6. Tool lookup + rate limiting
/// 7. DamageControl → OutboundGuard → Broker policy chain
/// 8. Approval overlay
/// 9. Timeout-wrapped execution
/// 10. Analytics + audit logging

/// Protocol for tool executor functionality, enabling test doubles.
///
/// Conformed to by the real `ToolExecutor` actor and the test-only
/// `MockToolExecutor` actor used in CoworkToolExecutor tests.
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
    let actionBroker: any TrustedActionBroker
    let damageControlPolicy: DamageControlPolicy
    let rateLimiter: ToolRateLimiter
    let securityLogger: SecurityEventLogger
    let outboundGuard: OutboundExfiltrationGuard
    let approvalManager: ApprovalManager?
    let workflowTraceStore: WorkflowTraceStore?
    let toolAnalytics: ToolAnalytics?
    weak var delegate: (any ToolExecutorDelegate)?
    nonisolated(unsafe) var debugConsole: DebugConsoleController?

    /// Plugin hook runner for PreToolUse / PostToolUse hooks.
    var pluginHookRunner: PluginHookRunner?

    /// Action receipt store for undo/reversibility. Set after init by FaeCore.
    var receiptStore: ReceiptStore?

    // MARK: - Constants

    /// Maximum computer-use action steps (click/type_text/scroll) per turn.
    static let maxComputerUseSteps = 10

    private static let defaultToolTimeoutSeconds: TimeInterval = 30
    private static let extendedVisionToolTimeoutSeconds: TimeInterval = 180

    // MARK: - Init

    init(
        registry: ToolRegistry,
        actionBroker: any TrustedActionBroker,
        damageControlPolicy: DamageControlPolicy,
        rateLimiter: ToolRateLimiter,
        securityLogger: SecurityEventLogger,
        outboundGuard: OutboundExfiltrationGuard,
        approvalManager: ApprovalManager? = nil,
        workflowTraceStore: WorkflowTraceStore? = nil,
        toolAnalytics: ToolAnalytics? = nil,
        delegate: (any ToolExecutorDelegate)? = nil,
        debugConsole: DebugConsoleController? = nil
    ) {
        self.registry = registry
        self.actionBroker = actionBroker
        self.damageControlPolicy = damageControlPolicy
        self.rateLimiter = rateLimiter
        self.securityLogger = securityLogger
        self.outboundGuard = outboundGuard
        self.approvalManager = approvalManager
        self.workflowTraceStore = workflowTraceStore
        self.toolAnalytics = toolAnalytics
        self.delegate = delegate
        self.debugConsole = debugConsole
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
    func setPluginHookRunner(_ runner: PluginHookRunner?) {
        pluginHookRunner = runner
    }

    /// Wire the action receipt store for undo/reversibility tracking.
    func setReceiptStore(_ store: ReceiptStore) {
        receiptStore = store
    }

    // MARK: - Execute

    /// Execute a single tool call through the full security stack.
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

    /// Inner execution — all security layers, approval, and tool invocation.
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

        let selfConfigRead = Self.isSelfConfigReadAction(arguments: call.arguments)
        let effectiveRequiresApproval = Self.toolRequiresApproval(
            toolName: call.name,
            arguments: call.arguments,
            defaultRequiresApproval: tool.requiresApproval
        )
        let effectiveRiskLevel: ToolRiskLevel = (call.name == "self_config" && selfConfigRead) ? .low : tool.riskLevel

        // ── 7. Rate limiting ────────────────────────────────────────────
        if let limitError = await rateLimiter.checkLimit(
            tool: call.name,
            riskLevel: effectiveRiskLevel
        ) {
            debugLog(debugConsole, .toolResult, "Rate limited: \(call.name) reason=\(limitError)")
            return ToolExecutorResult(
                result: .error(limitError),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: nil
            )
        }

        // ── 8. Build ActionIntent ───────────────────────────────────────
        let intent = ActionIntent(
            source: context.actionSource,
            toolName: call.name,
            riskLevel: effectiveRiskLevel,
            requiresApproval: effectiveRequiresApproval,
            isOwner: context.isOwner,
            livenessScore: context.livenessScore,
            speakerId: context.speakerId,
            explicitUserAuthorization: context.explicitUserAuthorization,
            hasCapabilityTicket: context.hasCapabilityTicketForTool,
            argumentSummary: Self.buildApprovalDescription(
                toolName: call.name,
                reason: "confirmation required",
                arguments: call.arguments
            ),
            schedulerTaskId: context.proactiveContext?.taskId,
            schedulerAllowedTools: context.proactiveContext?.allowedTools ?? [],
            schedulerConsentGranted: context.proactiveContext?.consentGranted ?? false
        )

        let brokerDecisionStartedAt = Date()
        var workflowDamageControlIntervened = false

        // ── 9. Damage Control — Layer 0 (pre-broker) ───────────────────
        let dcVerdict = await damageControlPolicy.evaluate(
            toolName: call.name,
            arguments: call.arguments,
            locality: context.modelLocality
        )
        var dcManualDecision: BrokerDecision?
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
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC disaster: \(call.name) — \(reason)")
            dcManualDecision = .confirm(
                prompt: ConfirmationPrompt(message: reason),
                reason: DecisionReason(code: .damageControlDisaster, message: reason),
                manualOnly: true,
                isDisasterLevel: true
            )

        case .confirmManual(let reason):
            workflowDamageControlIntervened = true
            await securityLogger.log(
                event: "dc_confirm_manual",
                toolName: call.name,
                decision: "confirm",
                reasonCode: "damageControlConfirmManual",
                arguments: call.arguments
            )
            debugLog(debugConsole, .approval, "DC confirm manual: \(call.name) — \(reason)")
            dcManualDecision = .confirm(
                prompt: ConfirmationPrompt(message: reason),
                reason: DecisionReason(code: .damageControlConfirmManual, message: reason),
                manualOnly: true,
                isDisasterLevel: false
            )
        }

        // ── 10. Outbound Guard + Broker ─────────────────────────────────
        let brokerDecision: BrokerDecision
        if let dcVerdict = dcManualDecision {
            brokerDecision = dcVerdict
        } else if let outboundDecision = await outboundGuard.evaluate(
            toolName: call.name,
            arguments: call.arguments
        ) {
            switch outboundDecision {
            case .confirm(let message):
                brokerDecision = .confirm(
                    prompt: ConfirmationPrompt(message: message),
                    reason: DecisionReason(
                        code: .outboundRecipientNovelty,
                        message: message
                    )
                )
            case .deny(let message):
                brokerDecision = .deny(
                    reason: DecisionReason(
                        code: .outboundPayloadRisk,
                        message: message
                    )
                )
            }
        } else {
            brokerDecision = await actionBroker.evaluate(intent)
        }

        let brokerDecisionString: String
        let brokerReasonCode: String?
        switch brokerDecision {
        case .allow(let reason):
            brokerDecisionString = "allow"
            brokerReasonCode = reason.code.rawValue
        case .allowWithTransform(_, let reason):
            brokerDecisionString = "allow_with_transform"
            brokerReasonCode = reason.code.rawValue
        case .confirm(_, let reason, _, _):
            brokerDecisionString = "confirm"
            brokerReasonCode = reason.code.rawValue
        case .deny(let reason):
            brokerDecisionString = "deny"
            brokerReasonCode = reason.code.rawValue
        }

        debugLog(debugConsole, .approval, "Broker decision for \(call.name): \(brokerDecisionString) reason=\(brokerReasonCode ?? "none")")

        await securityLogger.log(
            event: "broker_decision",
            toolName: call.name,
            decision: brokerDecisionString,
            reasonCode: brokerReasonCode,
            arguments: call.arguments
        )

        // ── 11. Shadow mode bypass ──────────────────────────────────────
        var effectiveDecision = brokerDecision
        if FaeEnvironment.defaults.bool(forKey: "fae.security.shadowMode") {
            switch brokerDecision {
            case .confirm(_, let reason, _, _), .deny(let reason):
                await securityLogger.log(
                    event: "shadow_decision",
                    toolName: call.name,
                    decision: brokerDecisionString,
                    reasonCode: reason.code.rawValue,
                    approved: nil,
                    success: true,
                    error: "Shadow mode bypassed enforcement",
                    arguments: call.arguments
                )
                effectiveDecision = .allow(reason: reason)
            default:
                break
            }
        }

        // ── 12. Approval gate ───────────────────────────────────────────
        var approvedByUser = false
        switch effectiveDecision {
        case .allow:
            break

        case .allowWithTransform(let transform, _):
            if let transformError = await applySafetyTransform(
                transform,
                toolName: call.name,
                arguments: call.arguments
            ) {
                return ToolExecutorResult(
                    result: .error(transformError),
                    approvedByUser: nil,
                    damageControlIntervened: workflowDamageControlIntervened,
                        latencyMs: nil
                )
            }

        case .confirm(let prompt, _, let manualOnly, let isDisasterLevel):
            // Voice identity auto-approval: when the speaker is the verified
            // owner and the operation is not disaster-level or manual-only,
            // auto-approve. Voice identity IS the security model — asking
            // "say yes" after already verifying the speaker's voice is redundant
            // and breaks the voice-first UX (echo suppression blocks the response).
            if context.isOwner && !manualOnly && !isDisasterLevel {
                debugLog(debugConsole, .approval, "Auto-approved \(call.name) for verified owner (voice identity)")
                approvedByUser = true
                await securityLogger.log(
                    event: "tool_auto_approved_owner",
                    toolName: call.name,
                    decision: "confirm",
                    reasonCode: brokerReasonCode,
                    approved: true,
                    success: true,
                    error: nil,
                    arguments: call.arguments
                )
            } else if let manager = approvalManager {
                debugLog(debugConsole, .approval, "Requesting approval for \(call.name): \(prompt.message) manualOnly=\(manualOnly)")
                await callbacks.onApprovalPending(true, manualOnly)
                async let approvalDecision = manager.requestApproval(
                    toolName: call.name,
                    description: prompt.message,
                    manualOnly: manualOnly,
                    isDisasterLevel: isDisasterLevel
                )
                if !manualOnly {
                    await delegate?.toolExecutorSpeakDirect(prompt.message)
                }
                let approved = await approvalDecision
                await callbacks.onApprovalPending(false, false)
                approvedByUser = approved
                debugLog(debugConsole, .approval, "Approval result for \(call.name): \(approved)")
                if !approved {
                    let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                    if let analytics = toolAnalytics {
                        await analytics.record(
                            toolName: call.name,
                            success: false,
                            latencyMs: latencyMs,
                            approved: false,
                            error: "Tool execution denied by user"
                        )
                    }
                    await securityLogger.log(
                        event: "tool_denied",
                        toolName: call.name,
                        decision: "confirm",
                        reasonCode: brokerReasonCode,
                        approved: false,
                        success: false,
                        error: "Tool execution denied by user",
                        arguments: call.arguments
                    )
                    return ToolExecutorResult(
                        result: .error("Tool execution denied by user."),
                        approvedByUser: false,
                        damageControlIntervened: workflowDamageControlIntervened,
                            latencyMs: nil
                    )
                }
            } else {
                let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                if let analytics = toolAnalytics {
                    await analytics.record(
                        toolName: call.name,
                        success: false,
                        latencyMs: latencyMs,
                        approved: nil,
                        error: "Tool requires approval, but no approval manager is available"
                    )
                }
                await securityLogger.log(
                    event: "tool_denied",
                    toolName: call.name,
                    decision: "confirm",
                    reasonCode: brokerReasonCode,
                    approved: nil,
                    success: false,
                    error: "No approval manager available",
                    arguments: call.arguments
                )
                return ToolExecutorResult(
                    result: .error("Tool requires approval, but no approval manager is available."),
                    approvedByUser: nil,
                    damageControlIntervened: workflowDamageControlIntervened,
                        latencyMs: nil
                )
            }

        case .deny(let reason):
            debugLog(debugConsole, .toolResult, "Denied by broker: \(call.name) reason=\(reason.code.rawValue)")
            let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
            if let analytics = toolAnalytics {
                await analytics.record(
                    toolName: call.name,
                    success: false,
                    latencyMs: latencyMs,
                    approved: nil,
                    error: "Denied by broker: \(reason.code.rawValue)"
                )
            }
            await securityLogger.log(
                event: "tool_denied",
                toolName: call.name,
                decision: "deny",
                reasonCode: reason.code.rawValue,
                approved: nil,
                success: false,
                error: reason.message,
                arguments: call.arguments
            )
            return ToolExecutorResult(
                result: .error(reason.message),
                approvedByUser: nil,
                damageControlIntervened: workflowDamageControlIntervened,
                latencyMs: nil
            )
        }

        // ── 13. Argument augmentation ───────────────────────────────────
        var executionArguments = call.arguments
        if call.name == "run_skill", let ticketId = context.capabilityTicket?.id {
            executionArguments["capability_ticket"] = ticketId
        }
        if call.name == "voice_identity",
           let action = executionArguments["action"] as? String,
           action == "collect_sample"
        {
            executionArguments["enrollment_active"] = context.firstOwnerEnrollmentActive
        }

        // ── 13b. Plugin PreToolUse hooks ──────────────────────────────
        if let hookRunner = pluginHookRunner, await hookRunner.hasHooks(for: .preToolUse) {
            let hookInput = HookInput.preToolUse(
                toolName: call.name,
                toolInput: executionArguments
            )
            let hookResponse = await hookRunner.runHooks(event: .preToolUse, input: hookInput)
            if hookResponse.shouldBlock {
                let blockMsg = hookResponse.systemMessage ?? "Blocked by plugin hook"
                debugLog(debugConsole, .toolResult, "Plugin hook blocked \(call.name): \(blockMsg)")
                return ToolExecutorResult(
                    result: .error(blockMsg),
                    approvedByUser: nil,
                    damageControlIntervened: false,
                    latencyMs: nil
                )
            }
        }

        // ── 13c. Pre-state capture (BEFORE execution) ────────────────────
        // Capture the file state now, before the tool mutates it.
        // This must happen before step 14 — after execution the original content is gone.
        let preState = receiptStore?.capturePreStateForTool(toolName: call.name, arguments: call.arguments)

        // ── 13d. Irreversible countdown ───────────────────────────────────
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

        // ── 14. Execute with timeout ────────────────────────────────────
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
            if let analytics = toolAnalytics {
                await analytics.record(
                    toolName: call.name,
                    success: false,
                    latencyMs: latencyMs,
                    approved: approvedByUser ? true : nil,
                    error: error.localizedDescription
                )
            }
            await securityLogger.log(
                event: "tool_result",
                toolName: call.name,
                decision: brokerDecisionString,
                reasonCode: brokerReasonCode,
                approved: approvedByUser ? true : nil,
                success: false,
                error: error.localizedDescription,
                arguments: call.arguments
            )
            return ToolExecutorResult(
                result: .error("Tool error: \(error.localizedDescription)"),
                approvedByUser: approvedByUser ? true : nil,
                damageControlIntervened: workflowDamageControlIntervened,
                latencyMs: nil
            )
        }

        // ── 14b. Plugin PostToolUse hooks ─────────────────────────────
        if let hookRunner = pluginHookRunner, await hookRunner.hasHooks(for: .postToolUse) {
            let hookInput = HookInput.postToolUse(
                toolName: call.name,
                toolOutput: String(result.output.prefix(2000))
            )
            let hookResponse = await hookRunner.runHooks(event: .postToolUse, input: hookInput)
            if let msg = hookResponse.systemMessage, !msg.isEmpty {
                debugLog(debugConsole, .toolResult, "Plugin PostToolUse hook message for \(call.name): \(msg)")
            }
        }

        // ── 15. Post-execution analytics + logging ──────────────────────
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        if let analytics = toolAnalytics {
            await analytics.record(
                toolName: call.name,
                success: !result.isError,
                latencyMs: latencyMs,
                approved: approvedByUser ? true : nil,
                error: result.isError ? result.output : nil
            )
        }

        await securityLogger.log(
            event: "tool_result",
            toolName: call.name,
            decision: brokerDecisionString,
            reasonCode: brokerReasonCode,
            approved: approvedByUser ? true : nil,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            arguments: call.arguments
        )

        if !result.isError {
            await outboundGuard.recordSuccessfulSend(toolName: call.name, arguments: call.arguments)
        }

        // ── 16. Action receipt ────────────────────────────────────────────
        // Pre-state (preState) was captured at step 13c, before the tool executed —
        // it reflects the original file content, not the post-mutation content.
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

        // ── 17. Post-action narration ─────────────────────────────────────
        // Only narrate write-class tools. Read-only tools (reversibility =
        // .notApplicable) are silent. Narration is interruptible — barge-in
        // during narration offers undo of the tagged receipt.
        // Skip narration for proactive tasks (no user present to hear it).
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
            approvedByUser: approvedByUser ? true : nil,
            damageControlIntervened: workflowDamageControlIntervened,
                latencyMs: nil
        )
    }

    // MARK: - Workflow Trace Recording

    private static func serializeArguments(_ args: [String: Any]) -> String {
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

    // MARK: - Safety Transform

    /// Apply deterministic safety wrappers before executing a tool.
    private func applySafetyTransform(
        _ transform: SafetyTransform,
        toolName: String,
        arguments: [String: Any]
    ) async -> String? {
        switch transform {
        case .none:
            return nil

        case .checkpointBeforeMutation:
            if ["write", "edit"].contains(toolName) {
                guard let path = arguments["path"] as? String else {
                    return "Safety checkpoint failed: missing path argument"
                }

                switch PathPolicy.validateWritePath(path) {
                case .blocked(let reason):
                    return reason
                case .allowed(let canonical):
                    let checkpointId = ReversibilityEngine.createCheckpoint(
                        for: canonical,
                        reason: "\(toolName) transform"
                    )
                    if checkpointId == nil {
                        return "Safety checkpoint failed: could not create reversible snapshot"
                    }

                    await securityLogger.log(
                        event: "safety_transform",
                        toolName: toolName,
                        decision: "checkpointBeforeMutation",
                        reasonCode: nil,
                        approved: nil,
                        success: true,
                        error: nil,
                        arguments: ["path": canonical, "checkpoint_id": checkpointId ?? ""]
                    )
                    return nil
                }
            }

            if toolName == "manage_skill",
               let action = arguments["action"] as? String,
               action == "delete",
               let name = arguments["name"] as? String,
               Self.isSafeSkillName(name)
            {
                let path = SkillManager.skillsDirectory.appendingPathComponent(name).path
                let checkpointId = ReversibilityEngine.createCheckpoint(
                    for: path,
                    reason: "manage_skill delete transform"
                )
                if checkpointId == nil {
                    return "Safety checkpoint failed: could not snapshot skill before delete"
                }
                await securityLogger.log(
                    event: "safety_transform",
                    toolName: toolName,
                    decision: "checkpointBeforeMutation",
                    reasonCode: nil,
                    approved: nil,
                    success: true,
                    error: nil,
                    arguments: ["path": path, "checkpoint_id": checkpointId ?? ""]
                )
            }

            return nil
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

    /// Build a self_config-specific approval summary.
    private static func selfConfigApprovalSummary(arguments: [String: Any]) -> String {
        let action = (arguments["action"] as? String)?.lowercased() ?? ""
        if selfConfigReadActions.contains(action) {
            return "I can check your current settings."
        }

        if action == "adjust_setting" {
            let key = arguments["key"] as? String ?? "a setting"
            return "I can update \(key)."
        }

        if action.contains("directive") || action.contains("instructions") {
            switch action {
            case "set_directive", "set_instructions":
                return "I can replace your persistent directive."
            case "append_directive", "append_instructions":
                return "I can append to your persistent directive."
            case "clear_directive", "clear_instructions":
                return "I can clear your persistent directive."
            default:
                return "I can update your persistent directive."
            }
        }

        return "I can update your Fae settings."
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
                let preview = trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
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
            summary = selfConfigApprovalSummary(arguments: arguments)

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
            // Only reversible bash commands get narration.
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
            // Irreversible tools (mail, delegate_agent, agent_session, run_skill,
            // click/type_text/scroll) don't use narration — mail gets a countdown,
            // delegation tools get a countdown, computer-use is silent.
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
            // Sending, replying, and forwarding are irreversible.
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
