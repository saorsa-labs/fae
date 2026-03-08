import Foundation

enum InferenceWorkClass: String, Sendable {
    case operatorLLM = "operator"
    case kokoroTTS = "kokoro"
    case conciergeLLM = "concierge"

    var priorityRank: Int {
        switch self {
        case .operatorLLM:
            return 0
        case .kokoroTTS:
            return 1
        case .conciergeLLM:
            return 2
        }
    }
}

actor InferencePriorityController {
    static let shared = InferencePriorityController()

    struct Snapshot: Sendable, Equatable {
        var active: Set<InferenceWorkClass> = []
        var preferred: InferenceWorkClass?
    }

    private struct Waiter {
        let id: UUID
        let role: InferenceWorkClass
        let continuation: CheckedContinuation<Void, Never>
    }

    private var active: Set<InferenceWorkClass> = []
    private var preferred: InferenceWorkClass?
    private var waiters: [Waiter] = []

    func begin(_ role: InferenceWorkClass) async {
        if role == .operatorLLM {
            preferred = .operatorLLM
            active.insert(role)
            return
        }

        if role == .kokoroTTS {
            preferred = .kokoroTTS
        }

        if canStart(role) {
            active.insert(role)
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: UUID(), role: role, continuation: continuation))
        }
        active.insert(role)
    }

    func end(_ role: InferenceWorkClass) {
        active.remove(role)
        if preferred == role {
            preferred = nil
        }
        resumeEligibleWaiters()
    }

    func snapshot() -> Snapshot {
        Snapshot(active: active, preferred: preferred)
    }

    private func canStart(_ role: InferenceWorkClass) -> Bool {
        switch role {
        case .operatorLLM:
            return true
        case .kokoroTTS:
            return !active.contains(.operatorLLM)
        case .conciergeLLM:
            return !active.contains(.operatorLLM) && !active.contains(.kokoroTTS)
        }
    }

    private func resumeEligibleWaiters() {
        let sorted = waiters.sorted { lhs, rhs in
            lhs.role.priorityRank < rhs.role.priorityRank
        }

        var resumedIDs = Set<UUID>()
        for waiter in sorted where canStart(waiter.role) {
            resumedIDs.insert(waiter.id)
            waiter.continuation.resume()
            active.insert(waiter.role)
            if waiter.role != .conciergeLLM {
                break
            }
        }

        waiters.removeAll { resumedIDs.contains($0.id) }
    }
}
