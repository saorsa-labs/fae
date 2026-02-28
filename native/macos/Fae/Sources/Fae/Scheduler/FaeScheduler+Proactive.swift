import Foundation

private enum ProactiveCounterStore {
    static var counts: [String: Int] = [:]
}

extension FaeScheduler {
    func proactiveDispatchMode(taskID: String, urgency: ProactiveUrgency) async -> ProactiveDispatchMode {
        let nextCount: Int
        if urgency == .low || urgency == .medium {
            nextCount = (ProactiveCounterStore.counts[taskID] ?? 0) + 1
            ProactiveCounterStore.counts[taskID] = nextCount
        } else {
            ProactiveCounterStore.counts[taskID] = 0
            nextCount = 0
        }
        return ProactivePolicyEngine.decide(urgency: urgency, digestEligibleCount: nextCount).mode
    }
}
