import Foundation

extension FaeScheduler {
    private func proactiveDispatchDecision(
        taskID: String,
        urgency: ProactiveUrgency
    ) -> ProactiveDecision {
        let nextCount: Int
        if urgency == .low || urgency == .medium {
            nextCount = (proactiveDigestEligibleCounts[taskID] ?? 0) + 1
            proactiveDigestEligibleCounts[taskID] = nextCount
        } else {
            proactiveDigestEligibleCounts[taskID] = 0
            nextCount = 0
        }

        var decision = ProactivePolicyEngine.decide(
            urgency: urgency,
            digestEligibleCount: nextCount
        )

        if urgency == .low,
           proactiveInterjectionCount >= 2,
           decision.mode == .immediate
        {
            decision = .init(mode: .digest, reason: "noise_budget_digest")
        }

        return decision
    }

    func proactiveDispatchMode(taskID: String, urgency: ProactiveUrgency) async -> ProactiveDispatchMode {
        proactiveDispatchDecision(taskID: taskID, urgency: urgency).mode
    }
}
