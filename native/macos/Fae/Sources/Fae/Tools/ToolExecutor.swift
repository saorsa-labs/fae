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

    /// B-Swift Phase F7a: injected routed-write executor. Production delegates
    /// to `DaemonToolRouting.routeWrite`; tests inject a canned outcome so the
    /// timeout/hooks/receipt steps run without a live daemon. Returns the
    /// `WriteExecutionOutcome` (not a pre-mapped `ToolResult`) so the receipt
    /// can be built from the outcome's fd-anchored pre-state material.
    private var routedWriteExecutor: @Sendable (
        ToolCall, DaemonToolHostSession, DaemonToolRouting.WriteRoutePlan
    ) async -> DaemonToolRouting.WriteExecutionOutcome = { call, session, plan in
        await DaemonToolRouting.routeWrite(call: call, session: session, plan: plan)
    }

    /// B-Swift Phase F7a test seam: override the routed-write timeout.
    private var routedWriteTimeoutOverride: TimeInterval?

    /// B-Swift Phase F7b: routed-edit executor closure (returns the outcome,
    /// not a ToolResult, so the fd-anchored receipt pre-state material can be
    /// built from the outcome — mirrors routedWriteExecutor).
    private var routedEditExecutor: @Sendable (
        ToolCall, DaemonToolHostSession, DaemonToolRouting.EditRoutePlan
    ) async -> DaemonToolRouting.EditExecutionOutcome = { call, session, plan in
        await DaemonToolRouting.routeEdit(call: call, session: session, plan: plan)
    }

    /// B-Swift Phase F7b test seam: override the routed-edit timeout.
    private var routedEditTimeoutOverride: TimeInterval?

    /// B-Swift Phase F8: routed-bash executor closure (returns the outcome, not
    /// a ToolResult, so the coarse receipt pre-state material can be built from
    /// the outcome — mirrors routedWriteExecutor/routedEditExecutor).
    private var routedBashExecutor: @Sendable (
        ToolCall, DaemonToolHostSession, DaemonToolRouting.BashRoutePlan, DaemonToolOrigin
    ) async -> DaemonToolRouting.BashExecutionOutcome = { call, session, plan, origin in
        await DaemonToolRouting.routeBash(
            call: call, session: session, plan: plan, origin: origin)
    }

    /// B-Swift Phase F8 test seam: override the routed-bash timeout.
    private var routedBashTimeoutOverride: TimeInterval?

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

    // MARK: - Security override (Wave 2, human-gated sandbox override)

    /// Presents the hardware-click-only authorize card and returns the human's
    /// decision (security-override Wave 2, L2/L12). This is the ONLY producer of an
    /// `.allow` decision reachable from tool execution. Default FAILS CLOSED
    /// (`.deny`) — with no card wired, a security block stays a block (Invariant F).
    /// Production wires it to `SecurityOverridePanel` (whose Allow buttons are the
    /// only callers of the underlying `SecurityOverridePrompt.approve(_:)`); it
    /// MUST NOT be wired to any legacy approval route (VoiceCommandParser, TestServer
    /// `/approve`, `respondToApproval()`), since a model can drive those.
    private var securityOverridePresenter:
        @Sendable (SecurityDenial, String) async -> SecurityOverrideDecision = { _, _ in .deny }

    /// The standing sandbox-override grant store (L8/L9). `nil` ⇒ no auto-apply and
    /// no persistence (every override is single-use, re-prompted each time).
    private var grantStore: GrantStore?

    /// Wire the authorize-card presenter (production: `SecurityOverridePanel`).
    func setSecurityOverridePresenter(
        _ presenter: @escaping @Sendable (SecurityDenial, String) async -> SecurityOverrideDecision
    ) {
        securityOverridePresenter = presenter
    }

    /// Wire the standing grant store (production: `GrantStore()`).
    func setGrantStore(_ store: GrantStore?) {
        grantStore = store
    }

    /// The truthful daemon origin for a tool call's context (L1 — also closes gap
    /// #38). Conservative: only a genuine interactive owner turn (a normal
    /// `<tool_call>` with no proactive context and not a script block) earns
    /// `owner_interactive`; every autonomous lane names its real non-interactive
    /// origin so the daemon jails it AND refuses any sandbox override on its behalf.
    /// `static` + pure so the derivation is hermetically testable.
    static func daemonToolOrigin(for context: ToolExecutorContext) -> DaemonToolOrigin {
        if context.isScriptBlock { return .scriptBlock }
        if context.proactiveContext != nil {
            return context.actionSource == .scheduler ? .scheduler : .proactive
        }
        if context.actionSource == .scheduler { return .scheduler }
        return .ownerInteractive
    }

    /// Build the typed `SecurityDenial` for a DamageControl `.block`, if the block
    /// was a protected zero-access PATH (not an ordinary bash-pattern block). `nil`
    /// ⇒ not a security-path denial (no card, generic message).
    private func securityDenial(
        for call: ToolCall, context: ToolExecutorContext, reason: String
    ) async -> SecurityDenial? {
        guard let target = await damageControlPolicy.securityDenialTarget(
            toolName: call.name, arguments: call.arguments, locality: context.modelLocality)
        else { return nil }
        return SecurityDenial(
            reason: reason,
            target: target,
            tier: SecurityTier.classify(absolutePath: target))
    }

    /// Resolve a human-gated override for an overridable security denial (L2/L9).
    /// Returns a minted per-call override to re-submit with, or `nil` (deny).
    ///
    /// Fail-closed layering: only an interactive owner turn can override (L1/L9 —
    /// no human is present on an autonomous turn). A standing grant for the EXACT
    /// canonical target auto-applies WITHOUT a prompt (L9); otherwise the
    /// hardware-only card is presented and, on Allow, a persistent/expiring grant
    /// is stored (a `once` grant is single-use).
    private func resolveSecurityOverride(
        denial: SecurityDenial, command: String, context: ToolExecutorContext
    ) async -> DaemonSecurityOverride? {
        guard denial.overridable else { return nil }
        let origin = Self.daemonToolOrigin(for: context)
        guard origin.isInteractive else { return nil }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        // L9 auto-apply: a live standing grant authorizes this exact target silently.
        if let store = grantStore {
            let grant = await store.lookup(canonicalTarget: denial.target, nowMs: nowMs)
            if let auto = GrantStore.autoApplyOverride(
                grant: grant, denial: denial, origin: origin, nowMs: nowMs) {
                return auto
            }
        }
        // Otherwise present the hardware-only authorize card.
        let decision = await securityOverridePresenter(denial, command)
        guard case .allow(let kind) = decision else { return nil }
        if kind != .once, let store = grantStore {
            try? await store.record(
                canonicalTarget: denial.target, tier: denial.tier, kind: kind, nowMs: nowMs)
        }
        return DaemonSecurityOverride.mint(
            target: denial.target, tier: denial.tier, kind: kind, nowMs: nowMs)
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

        // ── 0. Guest / relay origin — text-only, no tool execution ──────
        // Voice identity is the security model: only the verified owner may
        // run tools. Owner-authorized automated turns (scheduler / proactive)
        // run with `isOwner == true`, so they pass. Remote channel senders and
        // local guests are text-only. Hiding tool schemas at prompt assembly is
        // NOT sufficient — a prompt-injected guest turn (a channel / x0x /
        // collaborate message body) can still elicit a tool call, so we deny at
        // the execution boundary, independent of `toolMode`, for both the
        // `<tool_call>` and `<tool_program>` paths (both build this context and
        // route through here). The `.relay` check is defense-in-depth: a relay
        // turn is always non-owner today, but this keeps the invariant explicit
        // if that ever drifts. Pre-enrollment exposes no tool schemas, so this
        // never blocks the voice-enrollment path.
        if !context.isOwner || context.actionSource == .relay {
            await securityLogger.log(
                event: "guest_tool_denied",
                toolName: call.name,
                decision: "deny",
                reasonCode: "guestOrRelayOrigin",
                approved: nil,
                success: nil,
                error: nil,
                arguments: call.arguments
            )
            debugLog(
                debugConsole, .toolResult,
                "Blocked guest/relay tool call: \(call.name) isOwner=\(context.isOwner) source=\(context.actionSource.rawValue)")
            return ToolExecutorResult(
                result: .error("Tool '\(call.name)' is not available. Messages from remote channels and guests are text-only — only the primary user can run tools."),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: nil
            )
        }

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
        //    precedent-setter — Layer 4 routes write/edit/bash through this seam.
        if DaemonToolRouting.routedTools.contains(call.name) {
            // Branch per tool: read and write have distinct route plans (write
            // has NO local fallback — mutations are irreversible, fail closed).
            switch call.name {
            case "read":
                let plan = await DaemonToolRouting.planReadRoute(session: daemonToolHostSession)
                if plan != .legacyLocal {
                    return await executeRoutedRead(call: call, plan: plan, context: context)
                }
                // .legacyLocal → fall through to the local pipeline.
            case "write":
                let plan = await DaemonToolRouting.planWriteRoute(session: daemonToolHostSession)
                if plan != .legacyLocal {
                    return await executeRoutedWrite(call: call, plan: plan, context: context)
                }
                // .legacyLocal → fall through to the local pipeline.
            case "edit":
                let plan = await DaemonToolRouting.planEditRoute(session: daemonToolHostSession)
                if plan != .legacyLocal {
                    return await executeRoutedEdit(call: call, plan: plan, context: context)
                }
                // .legacyLocal → fall through to the local pipeline.
            case "bash":
                let plan = await DaemonToolRouting.planBashRoute(session: daemonToolHostSession)
                if plan != .legacyLocal {
                    return await executeRoutedBash(call: call, plan: plan, context: context)
                }
                // .legacyLocal → fall through to the local pipeline.
            default:
                // Future routed tools (edit/bash, F7b/F8) land here.
                break
            }
        }

        // ── 7. DamageControlPolicy ──────────────────────────────────────
        // F8: extracted into `runDamageControlGate` so routed bash runs the
        // SAME DamageControl logic (it must — the daemon doesn't confine bash
        // FS reach; see ACTIVE_WORK.md). write/edit/read skip DamageControl via
        // their own routed branches and never reach this line.
        let damageControlGate = await runDamageControlGate(call: call, context: context)
        if let damageControlBlocked = damageControlGate.blocked {
            return damageControlBlocked
        }
        let workflowDamageControlIntervened = damageControlGate.intervened

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

    // MARK: - DamageControl gate (shared by local pipeline + routed bash)

    /// F8: shared DamageControl evaluation. Runs `damageControlPolicy.evaluate`
    /// + the 4-case verdict handling (allow / block / disaster-countdown /
    /// confirmManual-countdown) + security logging + the delegate countdown.
    /// Extracted so the LOCAL pipeline (step 7) and routed `bash` run the SAME
    /// logic — bash MUST run DamageControl even when routed (the daemon doesn't
    /// confine bash FS reach; see ACTIVE_WORK.md + F7/F8 doc §F8). write/edit/
    /// read skip DamageControl via their own routed branches and don't call this.
    ///
    /// Returns `(blocked: nil, intervened: false)` if allowed; `(nil, true)` if
    /// disaster/confirmManual countdown PROCEEDS; `(result, true)` if blocked or
    /// the countdown cancelled (the caller returns `blocked`).
    private func runDamageControlGate(
        call: ToolCall,
        context: ToolExecutorContext
    ) async -> (blocked: ToolExecutorResult?, intervened: Bool, securityDenial: SecurityDenial?) {
        let dcVerdict = await damageControlPolicy.evaluate(
            toolName: call.name,
            arguments: call.arguments,
            locality: context.modelLocality
        )
        switch dcVerdict {
        case .allow:
            return (nil, false, nil)

        case .block(let reason):
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
            // Part A (L12): a protected/secret PATH block surfaces a clear spoken
            // line ("I can't read ~/.secrets …") instead of an opaque failure. A
            // non-path (bash-pattern) block keeps the generic message.
            let denial = await securityDenial(for: call, context: context, reason: reason)
            let message = denial?.spokenMessage ?? "Blocked by damage-control policy: \(reason)"
            return (ToolExecutorResult(
                result: .error(message),
                approvedByUser: nil,
                damageControlIntervened: true,
                latencyMs: nil), true, denial)

        case .disaster(let reason):
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
                return (ToolExecutorResult(
                    result: .error("Action cancelled: \(reason)"),
                    approvedByUser: false,
                    damageControlIntervened: true,
                    latencyMs: nil), true, nil)
            }
            return (nil, true, nil)  // countdown elapsed → proceed

        case .confirmManual(let reason):
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
                return (ToolExecutorResult(
                    result: .error("Action cancelled: \(reason)"),
                    approvedByUser: false,
                    damageControlIntervened: true,
                    latencyMs: nil), true, nil)
            }
            return (nil, true, nil)  // countdown elapsed → proceed
        }
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

        // ── Friendly error copy for the conversation (B-Swift #9). The raw
        // technical string was already sent to audit/analytics above
        // (`recordToolOutcome`); this ONLY reframes the conversation-facing
        // `output` in Fae's voice. Success results pass through untouched.
        let conversationResult: ToolResult = result.isError
            ? ToolResult(
                output: Self.friendlyRoutedReadError(for: result.output),
                isError: true)
            : result

        return ToolExecutorResult(
            result: conversationResult,
            approvedByUser: nil,
            damageControlIntervened: false,
            latencyMs: latencyMs
        )
    }

    // MARK: - B-Swift Phase F7a: routed-write executor branch

    /// Execute a routed `write` (`.daemonReachable` or
    /// `.daemonUnavailableFailClosed`) through the pipeline shape, with the
    /// mutation steps the routed-read branch skips (advisor F7a plan):
    /// - PreToolUse hooks → **pre-state capture BEFORE the daemon execute**
    ///   → timeout-wrapped routed write → PostToolUse hooks → audit/analytics
    ///   → **receipt on success** → **post-action narration with the receipt id**.
    ///
    /// DamageControl is skipped (the daemon governs write confinement — its
    /// write/edit rules are path/confinement rules; catastrophe/.disaster is
    /// bash-only, deferred to F8). Approval is upstream
    /// (`Pipeline/ToolRoutingHelpers.swift:84`), not an executor step — the
    /// daemon's per-call `tool.confirm` card is the per-call boundary.
    ///
    /// Race rule (mirrors the routed-read C3 rule): the `plan` was fixed BEFORE
    /// any side effect (`planWriteRoute`), so there is no fall-through to the
    /// legacy `WriteTool` after DamageControl was skipped. A daemon drop fails
    /// CLOSED — never a local write fallback.
    private func executeRoutedWrite(
        call: ToolCall,
        plan: DaemonToolRouting.WriteRoutePlan,
        context: ToolExecutorContext
    ) async -> ToolExecutorResult {
        let executionArguments = computeExecutionArguments(for: call, context: context)

        // ── PreToolUse hooks (BEFORE any daemon/root side effect).
        if let blocked = await runPreToolUseHooks(
            toolName: call.name, arguments: executionArguments)
        {
            return blocked
        }

        // NOTE (advisor F7a): pre-state for the receipt is NOT captured here.
        // It is captured INSIDE `executeSerializedRoutedWrite` (under the
        // operation lock, after root approval, via an fd-anchored read off the
        // daemon-approved root) and flows back through the outcome. A
        // path-based capture here would use a relative path, run outside the
        // lock, and follow symlinks/hardlinks — reopening the TOCTOU class
        // F7a closed and racing concurrent writes. The outcome carries the
        // safe pre-state material; the receipt is built from it below.

        // ── Timeout-wrapped routed write. The executor returns the outcome
        //   (not a ToolResult) so the receipt material is preserved.
        let timeoutSeconds = routedWriteTimeoutOverride ?? Self.toolTimeoutSeconds(for: call.name)
        let startTime = Date()
        let outcome: DaemonToolRouting.WriteExecutionOutcome
        do {
            let executor = routedWriteExecutor
            let session = daemonToolHostSession
            outcome = try await withThrowingTaskGroup(of: DaemonToolRouting.WriteExecutionOutcome.self) { group in
                group.addTask {
                    await executor(call, session, plan)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .failClosed("Tool timed out after \(Int(timeoutSeconds))s")
                }
                guard let o = try await group.next() else {
                    group.cancelAll()
                    return DaemonToolRouting.WriteExecutionOutcome.failClosed(
                        "Tool execution did not return a result")
                }
                group.cancelAll()
                return o
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Routed write threw: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            await recordToolOutcome(
                toolName: call.name,
                arguments: call.arguments,
                success: false,
                error: error.localizedDescription,
                startTime: startTime)
            return ToolExecutorResult(
                result: .error(Self.friendlyRoutedWriteError(for: "Tool error: \(error.localizedDescription)")),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: latencyMs
            )
        }

        // ── Map the outcome to the conversation result (raw strings; reframed
        //   below for the user).
        let result = DaemonToolRouting.mapWriteOutcome(outcome)

        // ── PostToolUse hooks.
        await runPostToolUseHooks(toolName: call.name, output: result.output)

        // ── Analytics + audit (mirrors step 14).
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        await recordToolOutcome(
            toolName: call.name,
            arguments: call.arguments,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            startTime: startTime)

        // ── Receipt on success, built from the outcome's fd-anchored pre-state
        //   material (NOT a path-based capture). The daemon write already ran;
        //   this records what it overwrote, for undo. The PATH is preserved even
        //   when the blob is nil (new-file creation, or a >50MB existing file we
        //   skipped) — undo for a created file deletes it, so it needs the path
        //   (mirrors the local `captureFilePreState` `(blob:nil, path:)` shape).
        var narrationReceiptId: String?
        if !result.isError, let store = receiptStore,
           case .routed(_, let preStateContent, let absoluteTargetPath) = outcome
        {
            let preState = absoluteTargetPath.map {
                ReceiptStore.PreStateCaptureResult(blob: preStateContent, path: $0)
            }
            narrationReceiptId = await store.createReceipt(
                toolName: call.name,
                arguments: call.arguments,
                preState: preState,
                speakerId: context.speakerId,
                sessionId: nil,
                turnId: context.workflowTurnID)
        }

        // ── Post-action narration with the receipt id (mirrors local step 16).
        let reversibility = ActionReversibility.classify(toolName: call.name, arguments: call.arguments)
        if !result.isError,
           reversibility != .notApplicable,
           context.proactiveContext == nil,
           let narrationText = Self.buildNarrationText(toolName: call.name, arguments: call.arguments)
        {
            await delegate?.toolExecutorNarrateAction(narrationText, receiptId: narrationReceiptId)
        }

        // ── Friendly error copy for the conversation (raw already in audit).
        let conversationResult: ToolResult = result.isError
            ? ToolResult(
                output: Self.friendlyRoutedWriteError(for: result.output),
                isError: true)
            : result

        return ToolExecutorResult(
            result: conversationResult,
            approvedByUser: nil,
            damageControlIntervened: false,
            latencyMs: latencyMs
        )
    }

    /// F7b: routed `edit` execution. Mirrors `executeRoutedWrite` (PreToolUse
    /// hooks → timeout-wrapped routed edit → PostToolUse hooks → audit/analytics
    /// → receipt from the outcome's fd-anchored pre-state → narration). Same
    /// DamageControl SKIP as write (edit's rules are confinement-only; the
    /// daemon governs confinement; catastrophe is bash-only → F8). Approval is
    /// upstream (`ToolRoutingHelpers.swift:84`), not an executor step. Schema
    /// translation (`old_string`→`old_text`) happens at the daemon seam inside
    /// `executeSerializedRoutedEdit` — `call.arguments` keeps Swift-native keys.
    private func executeRoutedEdit(
        call: ToolCall,
        plan: DaemonToolRouting.EditRoutePlan,
        context: ToolExecutorContext
    ) async -> ToolExecutorResult {
        let executionArguments = computeExecutionArguments(for: call, context: context)

        // ── PreToolUse hooks (BEFORE any daemon/root side effect).
        if let blocked = await runPreToolUseHooks(
            toolName: call.name, arguments: executionArguments)
        {
            return blocked
        }

        // NOTE (advisor F7a, applied to edit): pre-state for the receipt is NOT
        // captured here. It is captured INSIDE `executeSerializedRoutedEdit`
        // (under the operation lock, after root approval, via an fd-anchored
        // read off the daemon-approved root) and flows back through the outcome.
        // For edit the old content IS the undo target (essential).

        // ── Timeout-wrapped routed edit.
        let timeoutSeconds = routedEditTimeoutOverride ?? Self.toolTimeoutSeconds(for: call.name)
        let startTime = Date()
        let outcome: DaemonToolRouting.EditExecutionOutcome
        do {
            let executor = routedEditExecutor
            let session = daemonToolHostSession
            outcome = try await withThrowingTaskGroup(of: DaemonToolRouting.EditExecutionOutcome.self) { group in
                group.addTask {
                    await executor(call, session, plan)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .failClosed("Tool timed out after \(Int(timeoutSeconds))s")
                }
                guard let o = try await group.next() else {
                    group.cancelAll()
                    return DaemonToolRouting.EditExecutionOutcome.failClosed(
                        "Tool execution did not return a result")
                }
                group.cancelAll()
                return o
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Routed edit threw: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            await recordToolOutcome(
                toolName: call.name,
                arguments: call.arguments,
                success: false,
                error: error.localizedDescription,
                startTime: startTime)
            return ToolExecutorResult(
                result: .error(Self.friendlyRoutedEditError(for: "Tool error: \(error.localizedDescription)")),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: latencyMs
            )
        }

        let result = DaemonToolRouting.mapEditOutcome(outcome)

        // ── PostToolUse hooks.
        await runPostToolUseHooks(toolName: call.name, output: result.output)

        // ── Analytics + audit (mirrors step 14).
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        await recordToolOutcome(
            toolName: call.name,
            arguments: call.arguments,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            startTime: startTime)

        // ── Receipt on success, built from the outcome's fd-anchored pre-state
        //   (the old file content — the essential undo material for an edit).
        var narrationReceiptId: String?
        if !result.isError, let store = receiptStore,
           case .routed(_, let preStateContent, let absoluteTargetPath) = outcome
        {
            let preState = absoluteTargetPath.map {
                ReceiptStore.PreStateCaptureResult(blob: preStateContent, path: $0)
            }
            narrationReceiptId = await store.createReceipt(
                toolName: call.name,
                arguments: call.arguments,
                preState: preState,
                speakerId: context.speakerId,
                sessionId: nil,
                turnId: context.workflowTurnID)
        }

        // ── Post-action narration with the receipt id (mirrors local step 16).
        let reversibility = ActionReversibility.classify(toolName: call.name, arguments: call.arguments)
        if !result.isError,
           reversibility != .notApplicable,
           context.proactiveContext == nil,
           let narrationText = Self.buildNarrationText(toolName: call.name, arguments: call.arguments)
        {
            await delegate?.toolExecutorNarrateAction(narrationText, receiptId: narrationReceiptId)
        }

        // ── Friendly error copy for the conversation (raw already in audit).
        let conversationResult: ToolResult = result.isError
            ? ToolResult(
                output: Self.friendlyRoutedEditError(for: result.output),
                isError: true)
            : result

        return ToolExecutorResult(
            result: conversationResult,
            approvedByUser: nil,
            damageControlIntervened: false,
            latencyMs: latencyMs
        )
    }

    /// Map a technical routed-read error string to Fae-voice conversation copy
    /// (B-Swift #9). The raw technical string is preserved for audit/analytics
    /// (logged via `recordToolOutcome` BEFORE this runs); this only reframes
    /// what the user sees in the conversation. Falls back to the original string
    /// for unmapped errors (never swallows an error).
    ///
    /// Principle: tell the user WHAT went wrong in plain terms and hint at the
    /// fix, without leaking internals (absolute paths, errno, daemon wire
    /// details). The daemon-down and cancellation cases are distinguished from
    /// confinement/policy denials so the user understands the cause.
    static func friendlyRoutedReadError(for technical: String) -> String {
        // Confinement / policy denials (the path wasn't safe to read).
        if technical.contains("escapes the workspace")
            || technical.contains("path traversal")
            || technical.contains("Absolute paths are not supported")
            || technical.contains("must name a file, not the workspace root")
            || technical.contains("must not end with a path separator")
            || technical.contains("read path is empty")
            || technical.contains("contains a NUL byte") {
            return "I can only read files inside the workspace. That path is outside it or isn't a valid workspace path."
        }
        if technical.contains("symbolic link") || technical.contains("symlink") {
            return "That file is a symbolic link, which I don't follow for reads — it could point outside the workspace."
        }
        if technical.contains("multiple hard links") || technical.contains("hard link") {
            return "That file has multiple hard links, so I can't be sure it stays inside the workspace — I won't read it."
        }
        if technical.contains("regular files only")
            || technical.contains("Not a regular file")
            || technical.contains("non-regular") {
            return "That isn't a regular file (it may be a directory, socket, or device) — I can only read regular files."
        }
        // Not-found (may surface after the root handshake — see #10).
        if technical.contains("not found")
            || technical.contains("File not found")
            || technical.contains("file not found") {
            return "I couldn't find that file in the workspace."
        }
        // Daemon / runtime failures (not the user's fault).
        if technical.contains("Daemon unavailable")
            || technical.contains("before the workspace root was approved") {
            return "The file backend isn't available right now, so I couldn't open the workspace. Please try again shortly."
        }
        if technical.contains("Daemon read") || technical.contains("returned no content") {
            return "The file backend reported a problem reading that file. Please try again, or check the file is accessible."
        }
        if technical.contains("was cancelled") || technical.contains("cancelled") {
            return "That read was cancelled."
        }
        if technical.contains("timed out") {
            return "That read took too long and was stopped. The file may be very large or the backend busy."
        }
        if technical.contains("not UTF-8") || technical.contains("is not UTF-8") {
            return "That file isn't UTF-8 text, so I can't display it as text."
        }
        if technical.contains("routing misconfigured") {
            return "I hit an internal setup problem with the read tool. Please report this."
        }
        // Fallback: an unmapped/compound error. Surface a generic message
        // rather than risk leaking an internal path/errno/wire detail in the
        // conversation (the audit log already has the raw string via
        // recordToolOutcome, logged BEFORE this reframing). Known
        // recovery-relevant errors are all mapped above, so a generic copy does
        // not cost the model useful signal (red-team M2).
        return "I couldn't read that file right now. The details are in the log."
    }

    /// Map a technical routed-write error string to Fae-voice conversation copy
    /// (F7a). Mirrors `friendlyRoutedReadError`'s principle: the raw technical
    /// string is preserved for audit/analytics (`recordToolOutcome` runs BEFORE
    /// this reframing); this only reframes what the user sees. Writes are
    /// irreversible, so outage/errors fail closed — the copy reflects that the
    /// write did NOT happen (never implies partial success).
    static func friendlyRoutedWriteError(for technical: String) -> String {
        // Confinement / policy denials (the path wasn't safe to write).
        if technical.contains("escapes the workspace")
            || technical.contains("path traversal")
            || technical.contains("Absolute paths are not supported")
            || technical.contains("must name a file, not the workspace root")
            || technical.contains("write path is empty")
            || technical.contains("contains a NUL byte") {
            return "I can only write files inside the workspace. That path is outside it or isn't a valid workspace path, so nothing was written."
        }
        // Daemon unavailable / outage — fail closed (no local write).
        if technical.contains("Daemon unavailable")
            || technical.contains("routing is intended")
            || technical.contains("before the workspace root was approved") {
            return "The file backend isn't available right now, so I didn't write anything. Please try again shortly."
        }
        if technical.contains("Daemon write") {
            return "The file backend reported a problem writing that file, so nothing was written. Please try again."
        }
        if technical.contains("was cancelled") || technical.contains("cancelled") {
            return "That write was cancelled before it ran."
        }
        if technical.contains("timed out") {
            return "That write took too long and was stopped. Nothing was written."
        }
        if technical.contains("routing misconfigured") {
            return "I hit an internal setup problem with the write tool. Nothing was written. Please report this."
        }
        // Generic fallback (audit has the raw string). Never imply partial
        // success for an unmapped write error.
        return "I couldn't write that file right now, so nothing was written. The details are in the log."
    }

    /// Map a technical routed-edit error string to Fae-voice conversation copy
    /// (F7b, mirrors `friendlyRoutedWriteError`). The raw technical string is
    /// preserved for audit/analytics; only the conversation copy is softened.
    /// Adds edit-logical cases (not-found / ambiguous) that have no write
    /// analogue — these are normal edit failures, not backend problems.
    static func friendlyRoutedEditError(for technical: String) -> String {
        // Edit-logical errors (the daemon read the file but the edit can't
        // apply): old_text not found, or ambiguous (>1 match). Normal edit
        // failures — give actionable copy, NOT a "backend problem" message.
        if technical.contains("not found")
            || technical.contains("must be unique")
            || technical.contains("matches") {
            return "I couldn't apply that edit — the text to replace wasn't found exactly once in the file, so nothing was changed."
        }
        // Empty old_string (pre-rejected in Swift; defensive for the daemon path).
        if technical.contains("old_string must be non-empty")
            || technical.contains("old_text must be non-empty") {
            return "I need a non-empty `old_string` to know what to replace. Nothing was changed."
        }
        // Missing args.
        if technical.contains("Missing required parameter") {
            return "I need a valid path, old_string, and new_string to edit a file. Nothing was changed."
        }
        // Confinement / policy denials (the path wasn't safe to edit).
        if technical.contains("escapes the workspace")
            || technical.contains("path traversal")
            || technical.contains("Absolute paths are not supported")
            || technical.contains("must name a file, not the workspace root")
            || technical.contains("path is empty")
            || technical.contains("contains a NUL byte") {
            return "I can only edit files inside the workspace. That path is outside it or isn't a valid workspace path, so nothing was changed."
        }
        // Daemon unavailable / outage — fail closed (no local edit).
        if technical.contains("Daemon unavailable")
            || technical.contains("routing is intended")
            || technical.contains("before the workspace root was approved") {
            return "The file backend isn't available right now, so I didn't change anything. Please try again shortly."
        }
        if technical.contains("Daemon edit") {
            return "The file backend reported a problem editing that file, so nothing was changed. Please try again."
        }
        if technical.contains("was cancelled") || technical.contains("cancelled") {
            return "That edit was cancelled before it ran."
        }
        if technical.contains("timed out") {
            return "That edit took too long and was stopped. Nothing was changed."
        }
        if technical.contains("routing misconfigured") {
            return "I hit an internal setup problem with the edit tool. Nothing was changed. Please report this."
        }
        // Generic fallback (audit has the raw string). Never imply partial
        // success for an unmapped edit error.
        return "I couldn't edit that file right now, so nothing was changed. The details are in the log."
    }

    /// F8: routed `bash` execution. The KEY difference from routed write/edit:
    /// **DamageControl runs FIRST** (the daemon doesn't confine bash FS reach —
    // no OS sandbox; see ACTIVE_WORK.md). The full bash branch (zeroAccessPaths
    // + noDeletePaths + bashRules) is non-redundant and must run before any
    // daemon/root side effect. Then: PreToolUse hooks → timeout-wrapped routed
    // bash → PostToolUse hooks → audit/analytics → coarse receipt (Decision 1
    // = a) → narration. Approval is upstream. Fail-closed on outage (no local
    // bash fallback — mutations irreversible). The daemon's own `damage.rs`
    // adds defense-in-depth (system/workspace scope) on top of the Swift rules.
    /// Re-submit an owner-authorized bash carrying the human-gated daemon override
    /// (security-override Wave 2, the "Allow" tail of deny → card → re-submit).
    /// DamageControl is intentionally SKIPPED here — the human just authorized this
    /// exact target on the hardware card — but the daemon still re-validates every
    /// L-rule (origin, expiry, call_id, canonical tier) and relaxes ONLY that one
    /// canonical leaf. Routes DIRECTLY (never the test seam) so the override reaches
    /// the real daemon socket. Origin is `owner_interactive` (guaranteed by
    /// `resolveSecurityOverride`'s interactive-only gate — else no override exists).
    private func executeApprovedRoutedBash(
        call: ToolCall,
        plan: DaemonToolRouting.BashRoutePlan,
        context: ToolExecutorContext,
        override: DaemonSecurityOverride,
        startTime: Date
    ) async -> ToolExecutorResult {
        let origin = Self.daemonToolOrigin(for: context)
        let outcome = await DaemonToolRouting.routeBash(
            call: call, session: daemonToolHostSession, plan: plan,
            origin: origin, securityOverride: override)
        let result = DaemonToolRouting.mapBashOutcome(outcome)
        await runPostToolUseHooks(toolName: call.name, output: result.output)
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult,
            "Approved routed bash (override): \(call.name) success=\(!result.isError)")
        await recordToolOutcome(
            toolName: call.name, arguments: call.arguments,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            startTime: startTime)
        let conversationOutput = result.isError
            ? Self.friendlyRoutedBashError(for: result.output) : result.output
        return ToolExecutorResult(
            result: ToolResult(output: conversationOutput, isError: result.isError),
            approvedByUser: true,
            damageControlIntervened: true,
            latencyMs: latencyMs)
    }

    private func executeRoutedBash(
        call: ToolCall,
        plan: DaemonToolRouting.BashRoutePlan,
        context: ToolExecutorContext
    ) async -> ToolExecutorResult {
        let startTime = Date()

        // ── Fail-closed plan short-circuit (advisor F8): if the daemon is
        //   intended but UNREACHABLE, NO side effect can occur, so bypass
        //   DamageControl + hooks + the daemon entirely. A catastrophe command
        //   (`rm -rf ~/Documents`) with the daemon DOWN must surface the
        //   BACKEND-UNAVAILABLE error, NOT a DamageControl cancellation (the
        //   command never ran — there's nothing for DamageControl to guard).
        //   Routes via the REAL `routeBash` (NOT the test seam) so its
        //   missing-command validation + fail-closed mapping still apply; the
        //   RAW result is audited, and only the CONVERSATION copy is
        //   friendlified. damageControlIntervened=false; no root/daemon contact.
        if plan == .daemonUnavailableFailClosed {
            let outcome = await DaemonToolRouting.routeBash(
                call: call, session: daemonToolHostSession, plan: plan)
            let raw = DaemonToolRouting.mapBashOutcome(outcome)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Routed bash fail-closed (daemon down): \(call.name) isError=\(raw.isError)")
            await recordToolOutcome(
                toolName: call.name,
                arguments: call.arguments,
                success: !raw.isError,
                error: raw.isError ? raw.output : nil,
                startTime: startTime)
            let conversationOutput = raw.isError
                ? Self.friendlyRoutedBashError(for: raw.output) : raw.output
            return ToolExecutorResult(
                result: ToolResult(output: conversationOutput, isError: raw.isError),
                approvedByUser: nil,
                damageControlIntervened: false,
                latencyMs: latencyMs
            )
        }

        // ── DamageControl FIRST for `.daemonReachable` (F8, the audit-mandated
        //   difference from write/edit). Runs the SAME gate the local pipeline
        //   does (the daemon doesn't confine bash FS reach). A catastrophe
        //   command never reaches the daemon. `.allow` / proceeded-countdown →
        //   continue; blocked / cancelled → return.
        let damageControlGate = await runDamageControlGate(call: call, context: context)
        if let damageControlBlocked = damageControlGate.blocked {
            // Security-override Wave 2 (deny → card → re-submit): a protected/secret
            // PATH block may be human-overridable. Offer the hardware-only authorize
            // card (interactive owner only); on Allow, re-submit the SAME bash
            // carrying a daemon override scoped to exactly that one canonical target.
            if let denial = damageControlGate.securityDenial, denial.overridable {
                let command = call.arguments["command"] as? String ?? ""
                if let override = await resolveSecurityOverride(
                    denial: denial, command: command, context: context) {
                    return await executeApprovedRoutedBash(
                        call: call, plan: plan, context: context,
                        override: override, startTime: startTime)
                }
            }
            return damageControlBlocked
        }
        let damageControlIntervened = damageControlGate.intervened
        // L1 / gap #38: the routed bash carries the TRUTHFUL origin so a proactive/
        // scheduler/script bash is jailed daemon-side (and can never override).
        let origin = Self.daemonToolOrigin(for: context)

        let executionArguments = computeExecutionArguments(for: call, context: context)

        // ── PreToolUse hooks (BEFORE any daemon/root side effect).
        if let blocked = await runPreToolUseHooks(
            toolName: call.name, arguments: executionArguments)
        {
            return blocked
        }

        // ── Timeout-wrapped routed bash.
        let timeoutSeconds = routedBashTimeoutOverride ?? Self.toolTimeoutSeconds(for: call.name)
        let outcome: DaemonToolRouting.BashExecutionOutcome
        do {
            let executor = routedBashExecutor
            let session = daemonToolHostSession
            outcome = try await withThrowingTaskGroup(of: DaemonToolRouting.BashExecutionOutcome.self) { group in
                group.addTask {
                    await executor(call, session, plan, origin)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .failClosed("Tool timed out after \(Int(timeoutSeconds))s")
                }
                guard let o = try await group.next() else {
                    group.cancelAll()
                    return DaemonToolRouting.BashExecutionOutcome.failClosed(
                        "Tool execution did not return a result")
                }
                group.cancelAll()
                return o
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Routed bash threw: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            await recordToolOutcome(
                toolName: call.name,
                arguments: call.arguments,
                success: false,
                error: error.localizedDescription,
                startTime: startTime)
            return ToolExecutorResult(
                result: .error(Self.friendlyRoutedBashError(for: "Tool error: \(error.localizedDescription)")),
                approvedByUser: nil,
                damageControlIntervened: damageControlIntervened,
                latencyMs: latencyMs
            )
        }

        let result = DaemonToolRouting.mapBashOutcome(outcome)

        // ── PostToolUse hooks.
        await runPostToolUseHooks(toolName: call.name, output: result.output)

        // ── Analytics + audit (mirrors step 14).
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        await recordToolOutcome(
            toolName: call.name,
            arguments: call.arguments,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            startTime: startTime)

        // ── Coarse receipt on success (Decision 1 = a), built from the
        //   outcome's pre-state material (redirect-target snapshot, or nil).
        var narrationReceiptId: String?
        if !result.isError, let store = receiptStore,
           case .routed(_, let preStateContent, let absoluteTargetPath) = outcome
        {
            let preState = absoluteTargetPath.map {
                ReceiptStore.PreStateCaptureResult(blob: preStateContent, path: $0)
            }
            narrationReceiptId = await store.createReceipt(
                toolName: call.name,
                arguments: call.arguments,
                preState: preState,
                speakerId: context.speakerId,
                sessionId: nil,
                turnId: context.workflowTurnID)
        }

        // ── Post-action narration with the receipt id (mirrors local step 16).
        let reversibility = ActionReversibility.classify(toolName: call.name, arguments: call.arguments)
        if !result.isError,
           reversibility != .notApplicable,
           context.proactiveContext == nil,
           let narrationText = Self.buildNarrationText(toolName: call.name, arguments: call.arguments)
        {
            await delegate?.toolExecutorNarrateAction(narrationText, receiptId: narrationReceiptId)
        }

        // ── Friendly error copy for the conversation (raw already in audit).
        let conversationResult: ToolResult = result.isError
            ? ToolResult(
                output: Self.friendlyRoutedBashError(for: result.output),
                isError: true)
            : result

        return ToolExecutorResult(
            result: conversationResult,
            approvedByUser: nil,
            damageControlIntervened: damageControlIntervened,
            latencyMs: latencyMs
        )
    }

    /// Map a technical routed-bash error string to Fae-voice conversation copy
    /// (F8, mirrors the write/edit variants). The raw technical string is
    /// preserved for audit/analytics; only the conversation copy is softened.
    /// NOTE: DamageControl catastrophe denials (disaster/block/confirmManual)
    /// are handled in `runDamageControlGate` and surface their OWN copy (the
    // DangerReason text); this handles the ROUTING/daemon-layer errors that
    // reach `mapBashOutcome`.
    static func friendlyRoutedBashError(for technical: String) -> String {
        // Missing command arg.
        if technical.contains("Missing required parameter") {
            return "I need a valid command to run. Nothing was executed."
        }
        // Daemon unavailable / outage — fail closed (no local bash).
        if technical.contains("Daemon unavailable")
            || technical.contains("routing is intended")
            || technical.contains("before the workspace root was approved") {
            return "The command backend isn't available right now, so I didn't run that. Please try again shortly."
        }
        if technical.contains("Daemon bash") {
            return "The command backend reported a problem running that, so nothing was executed. Please try again."
        }
        if technical.contains("was cancelled") || technical.contains("cancelled") {
            return "That command was cancelled before it finished."
        }
        if technical.contains("timed out") {
            return "That command took too long and was stopped."
        }
        if technical.contains("routing misconfigured") {
            return "I hit an internal setup problem with the bash tool. Nothing was executed. Please report this."
        }
        // Generic fallback (audit has the raw string).
        return "I couldn't run that command right now. The details are in the log."
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

    /// Test seam setter (F7a): override the routed-write executor.
    /// GUARDED: `FAE_TEST_SEAMS` is defined only in `.debug`, so this is
    /// compiled OUT of release — no production binary can override routed-write
    /// confinement/timeout (red-team F4 rule, extended to mutations).
    func setRoutedWriteExecutorForTesting(
        _ fn: @Sendable @escaping (
            ToolCall, DaemonToolHostSession, DaemonToolRouting.WriteRoutePlan
        ) async -> DaemonToolRouting.WriteExecutionOutcome
    ) {
        routedWriteExecutor = fn
    }

    /// Test seam setter (F7a): override the routed-write timeout.
    func setRoutedWriteTimeoutForTesting(_ seconds: TimeInterval?) {
        routedWriteTimeoutOverride = seconds
    }

    /// Test seam setter (F7b): override the routed-edit executor.
    /// GUARDED: `FAE_TEST_SEAMS` is debug-only, compiled OUT of release
    /// (red-team F4 rule, extended to edit).
    func setRoutedEditExecutorForTesting(
        _ fn: @Sendable @escaping (
            ToolCall, DaemonToolHostSession, DaemonToolRouting.EditRoutePlan
        ) async -> DaemonToolRouting.EditExecutionOutcome
    ) {
        routedEditExecutor = fn
    }

    /// Test seam setter (F7b): override the routed-edit timeout.
    func setRoutedEditTimeoutForTesting(_ seconds: TimeInterval?) {
        routedEditTimeoutOverride = seconds
    }

    /// Test seam setter (F8): override the routed-bash executor.
    /// GUARDED: `FAE_TEST_SEAMS` is debug-only, compiled OUT of release
    /// (red-team F4 rule, extended to bash).
    func setRoutedBashExecutorForTesting(
        _ fn: @Sendable @escaping (
            ToolCall, DaemonToolHostSession, DaemonToolRouting.BashRoutePlan, DaemonToolOrigin
        ) async -> DaemonToolRouting.BashExecutionOutcome
    ) {
        routedBashExecutor = fn
    }

    /// Test seam setter (F8): override the routed-bash timeout.
    func setRoutedBashTimeoutForTesting(_ seconds: TimeInterval?) {
        routedBashTimeoutOverride = seconds
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
