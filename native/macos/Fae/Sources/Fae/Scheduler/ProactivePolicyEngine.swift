import Foundation

enum ProactiveUrgency: String, Sendable {
    case low
    case medium
    case high
}

enum ProactiveDispatchMode: String, Sendable, Equatable {
    case suppress
    case digest
    case immediate
}

struct ProactiveDecision: Sendable, Equatable {
    let mode: ProactiveDispatchMode
    let reason: String
}

enum ProactivePolicyEngine {
    static func inQuietHours(now: Date = Date(), startHour: Int = 22, endHour: Int = 7) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    static func decide(
        urgency: ProactiveUrgency,
        digestEligibleCount: Int,
        now: Date = Date(),
        quietStartHour: Int = 22,
        quietEndHour: Int = 7
    ) -> ProactiveDecision {
        if urgency == .high { return .init(mode: .immediate, reason: "urgency_override") }
        let quiet = inQuietHours(now: now, startHour: quietStartHour, endHour: quietEndHour)
        if quiet {
            if digestEligibleCount >= 2 { return .init(mode: .digest, reason: "quiet_hours_digest") }
            return .init(mode: .suppress, reason: "quiet_hours_suppress")
        }
        if digestEligibleCount >= 3 { return .init(mode: .digest, reason: "repetition_digest") }
        return .init(mode: .immediate, reason: "normal_immediate")
    }
}
