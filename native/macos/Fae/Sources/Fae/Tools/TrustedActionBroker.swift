import Foundation

/// User-facing autonomy profile for policy tuning.
enum PolicyProfile: String, Sendable {
    case balanced
    case moreAutonomous
    case moreCautious
}

/// Source that triggered an action intent.
enum ActionSource: String, Sendable {
    case voice
    case text
    case scheduler
    case relay
    case skill
    case unknown
}

/// Canonical policy input envelope evaluated at the tool chokepoint.
struct ActionIntent: Sendable {
    let source: ActionSource
    let toolName: String
    let riskLevel: ToolRiskLevel
    let requiresApproval: Bool
    let isOwner: Bool
    let livenessScore: Float?
    let explicitUserAuthorization: Bool
    let hasCapabilityTicket: Bool
    let policyProfile: PolicyProfile
    let argumentSummary: String
    let schedulerTaskId: String?  // nil for non-scheduler actions
    let schedulerAllowedTools: Set<String>
    let schedulerConsentGranted: Bool

    init(
        source: ActionSource,
        toolName: String,
        riskLevel: ToolRiskLevel,
        requiresApproval: Bool,
        isOwner: Bool,
        livenessScore: Float?,
        explicitUserAuthorization: Bool,
        hasCapabilityTicket: Bool,
        policyProfile: PolicyProfile,
        argumentSummary: String,
        schedulerTaskId: String? = nil,
        schedulerAllowedTools: Set<String> = [],
        schedulerConsentGranted: Bool = false
    ) {
        self.source = source
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.requiresApproval = requiresApproval
        self.isOwner = isOwner
        self.livenessScore = livenessScore
        self.explicitUserAuthorization = explicitUserAuthorization
        self.hasCapabilityTicket = hasCapabilityTicket
        self.policyProfile = policyProfile
        self.argumentSummary = argumentSummary
        self.schedulerTaskId = schedulerTaskId
        self.schedulerAllowedTools = schedulerAllowedTools
        self.schedulerConsentGranted = schedulerConsentGranted
    }
}

/// Stable reason codes used for audit/replay.
enum DecisionReasonCode: String, Sendable {
    case unknownTool
    case noExplicitRule
    case noCapabilityTicket
    case ownerRequired
    case stepUpRequired
    case explicitApprovalRequired
    case mediumRiskRequiresConfirmation
    case highRiskRequiresConfirmation
    case allowLowRisk
    case allowAutonomousMediumRisk
    case outboundRecipientNovelty
    case outboundPayloadRisk
    case approvedByUserGrant
    case schedulerAutoAllowed
    case damageControlBlock
    case damageControlDisaster
    case damageControlConfirmManual
}

struct DecisionReason: Sendable {
    let code: DecisionReasonCode
    let message: String
}

struct ConfirmationPrompt: Sendable {
    let message: String
}

enum SafetyTransform: String, Sendable {
    case none
    case checkpointBeforeMutation
}

enum BrokerDecision: Sendable {
    case allow(reason: DecisionReason)
    case allowWithTransform(transform: SafetyTransform, reason: DecisionReason)
    /// Standard or damage-control confirmation.
    ///
    /// - `manualOnly`: When true, voice "yes/no" is rejected — only a physical button press proceeds.
    ///   Set by `DamageControlPolicy` for `disaster` and `confirmManual` verdicts.
    /// - `isDisasterLevel`: When true, the overlay shows the DISASTER WARNING variant with a red border.
    case confirm(prompt: ConfirmationPrompt, reason: DecisionReason, manualOnly: Bool = false, isDisasterLevel: Bool = false)
    case deny(reason: DecisionReason)
}

protocol TrustedActionBroker: Sendable {
    func evaluate(_ intent: ActionIntent) async -> BrokerDecision
}

/// Deterministic broker that centralizes voice-identity and tool-risk policy.
actor DefaultTrustedActionBroker: TrustedActionBroker {
    private let knownTools: Set<String>
    private let speakerConfig: FaeConfig.SpeakerConfig

    /// Per-task tool allowlists for scheduler auto-allow.
    private static let schedulerTaskAllowlists: [String: Set<String>] = [
        "camera_presence_check": ["camera"],
        "screen_activity_check": ["screenshot"],
        "overnight_work": ["web_search", "fetch_url", "activate_skill"],
        "enhanced_morning_briefing": ["calendar", "reminders", "contacts", "mail", "notes", "activate_skill"],
        // capability_discovery: informational only — no surveillance, consent always true.
        "capability_discovery": ["activate_skill"],
    ]

    /// Tools that scheduler tasks can NEVER use regardless of allowlist.
    private static let schedulerDeniedTools: Set<String> = [
        "write", "edit", "bash", "manage_skill", "self_config",
    ]

    /// Explicitly modeled tools in broker policy. Any known tool not listed here
    /// is denied by default until a policy rule is added.
    private static let explicitRuleTools: Set<String> = [
        "read", "write", "edit", "bash", "self_config",
        "session_search", "web_search", "fetch_url", "input_request",
        "activate_skill", "run_skill", "manage_skill",
        "delegate_agent",
        "channel_setup",
        "calendar", "reminders", "contacts", "mail", "notes",
        "scheduler_list", "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger",
        "roleplay",
        // Vision & computer use tools.
        "screenshot", "camera", "read_screen",
        "click", "type_text", "scroll", "find_element",
        // Voice identity.
        "voice_identity",
    ]

    /// Medium-risk tools that should still confirm when user intent is ambiguous.
    private static let highImpactMediumTools: Set<String> = [
        "run_skill",
        "screenshot", "camera", "scroll",
    ]

    init(knownTools: Set<String>, speakerConfig: FaeConfig.SpeakerConfig) {
        self.knownTools = knownTools
        self.speakerConfig = speakerConfig
    }

    func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
        guard knownTools.contains(intent.toolName) else {
            return .deny(reason: DecisionReason(
                code: .unknownTool,
                message: "Unknown tool is denied by policy."
            ))
        }

        guard Self.explicitRuleTools.contains(intent.toolName) else {
            return .deny(reason: DecisionReason(
                code: .noExplicitRule,
                message: "No explicit broker rule exists for this action; denied by default."
            ))
        }

        guard intent.hasCapabilityTicket else {
            return .deny(reason: DecisionReason(
                code: .noCapabilityTicket,
                message: "No active capability grant for this action."
            ))
        }

        // Scheduler auto-allow for consented awareness observations.
        if intent.source == .scheduler {
            guard intent.schedulerConsentGranted else {
                return .deny(reason: DecisionReason(
                    code: .noCapabilityTicket,
                    message: "Awareness consent not granted"
                ))
            }

            guard let taskId = intent.schedulerTaskId else {
                return .deny(reason: DecisionReason(
                    code: .noExplicitRule,
                    message: "Unknown scheduler task policy"
                ))
            }

            let allowed: Set<String>
            if !intent.schedulerAllowedTools.isEmpty {
                allowed = intent.schedulerAllowedTools
            } else if let knownAllowed = Self.schedulerTaskAllowlists[taskId] {
                allowed = knownAllowed
            } else {
                return .deny(reason: DecisionReason(
                    code: .noExplicitRule,
                    message: "Unknown scheduler task policy"
                ))
            }

            // Deny write/mutation tools from scheduler tasks.
            if Self.schedulerDeniedTools.contains(intent.toolName) {
                return .deny(reason: DecisionReason(
                    code: .noExplicitRule,
                    message: "Write/mutation tools not allowed for scheduler observations"
                ))
            }

            guard allowed.contains(intent.toolName) else {
                return .deny(reason: DecisionReason(
                    code: .noExplicitRule,
                    message: "Tool not allowed for scheduler task \(taskId)"
                ))
            }

            return .allow(reason: DecisionReason(
                code: .schedulerAutoAllowed,
                message: "Allowed for \(taskId) with user consent"
            ))
        }

        // Voice identity step-up/deny is always evaluated first.
        let voiceDecision = VoiceIdentityPolicy.evaluateSensitiveAction(
            config: speakerConfig,
            isOwner: intent.isOwner,
            risk: intent.riskLevel,
            toolName: intent.toolName,
            livenessScore: intent.livenessScore
        )

        switch voiceDecision {
        case .deny(let message):
            return .deny(reason: DecisionReason(
                code: .ownerRequired,
                message: message
            ))

        case .requireStepUp(let message):
            return .confirm(
                prompt: ConfirmationPrompt(message: "Step-up confirmation: \(message)"),
                reason: DecisionReason(code: .stepUpRequired, message: message)
            )

        case .allow:
            break
        }

        // Check user-granted progressive approvals before prompting for confirmation.
        let approvedToolsStore = ApprovedToolsStore.shared
        if await approvedToolsStore.shouldAutoApprove(toolName: intent.toolName, riskLevel: intent.riskLevel) {
            return .allow(reason: DecisionReason(
                code: .approvedByUserGrant,
                message: "Auto-approved by user grant"
            ))
        }

        // Tool risk policy drives confirmation behavior.
        let requiresConfirmation: Bool
        switch intent.policyProfile {
        case .balanced:
            requiresConfirmation = shouldConfirmInBalancedProfile(intent)

        case .moreCautious:
            // Cautious mode: anything non-low requires confirmation.
            requiresConfirmation = true

        case .moreAutonomous:
            // Autonomous mode still confirms high-risk/explicit-approval tools.
            requiresConfirmation = shouldConfirmInAutonomousProfile(intent)
        }

        if requiresConfirmation {
            // Autonomous profile can proceed for selected mutation tools only
            // when reversible safety wrappers are applied.
            if intent.policyProfile == .moreAutonomous {
                let summary = intent.argumentSummary.lowercased()
                if ["write", "edit"].contains(intent.toolName)
                    || (intent.toolName == "manage_skill" && summary.contains("delete"))
                {
                    return .allowWithTransform(
                        transform: .checkpointBeforeMutation,
                        reason: DecisionReason(
                            code: .explicitApprovalRequired,
                            message: "Allowed in autonomous profile with reversible checkpoint"
                        )
                    )
                }
            }

            let code: DecisionReasonCode = {
                if intent.requiresApproval { return .explicitApprovalRequired }
                return intent.riskLevel == .high
                    ? .highRiskRequiresConfirmation
                    : .mediumRiskRequiresConfirmation
            }()

            return .confirm(
                prompt: ConfirmationPrompt(message: intent.argumentSummary),
                reason: DecisionReason(code: code, message: "Confirmation required by policy")
            )
        }

        if intent.riskLevel == .medium, intent.policyProfile == .moreAutonomous {
            return .allow(reason: DecisionReason(
                code: .allowAutonomousMediumRisk,
                message: "Allowed by autonomous profile for medium-risk action"
            ))
        }

        return .allow(reason: DecisionReason(
            code: .allowLowRisk,
            message: "Allowed by policy"
        ))
    }

    private func shouldConfirmInBalancedProfile(_ intent: ActionIntent) -> Bool {
        if intent.requiresApproval || intent.riskLevel == .high {
            return true
        }

        if intent.riskLevel == .medium {
            // Minimize prompt noise: medium-risk confirms only when both
            // high-impact and intent is ambiguous.
            return Self.highImpactMediumTools.contains(intent.toolName)
                && !intent.explicitUserAuthorization
        }

        return false
    }

    private func shouldConfirmInAutonomousProfile(_ intent: ActionIntent) -> Bool {
        guard !intent.explicitUserAuthorization else {
            return false
        }

        if intent.requiresApproval || intent.riskLevel == .high {
            return true
        }

        return false
    }
}
