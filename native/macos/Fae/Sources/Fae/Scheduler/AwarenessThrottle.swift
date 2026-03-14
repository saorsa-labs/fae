import Foundation
import IOKit.ps

/// Decision from the awareness throttle.
enum ThrottleDecision: Sendable {
    /// Skip this observation entirely.
    case skip(reason: String)
    /// Run observation but suppress speech output.
    case silentOnly
    /// Normal operation — full behavior including speech if appropriate.
    case normal
}

/// Lightweight utility checking battery, thermal, and time-of-day conditions
/// to gate proactive awareness observations.
struct AwarenessThrottle: Sendable {

    /// Check whether an awareness task should run, run silently, or be skipped.
    ///
    /// - Parameters:
    ///   - config: Current awareness configuration.
    ///   - taskId: The scheduled task identifier (e.g. "camera_presence_check").
    ///   - lastUserSeenAt: When the user was last detected by camera (nil = never).
    /// - Returns: A throttle decision.
    static func check(
        config: FaeConfig.AwarenessConfig,
        taskId: String,
        lastUserSeenAt: Date? = nil
    ) -> ThrottleDecision {
        // Tier 1 tasks (briefing, overnight research) run with proactiveLiteEnabled alone.
        // Tier 2 tasks (camera, screen) require full awareness consent.
        let isTier1 = taskId == "enhanced_morning_briefing" || taskId == "overnight_work"
        if isTier1 {
            guard config.proactiveLiteEnabled || (config.enabled && config.consentGrantedAt != nil) else {
                return .skip(reason: "Proactive lite disabled and no awareness consent")
            }
        } else {
            guard config.enabled, config.consentGrantedAt != nil else {
                return .skip(reason: "Awareness not enabled or no consent")
            }
        }

        // Battery check.
        if config.pauseOnBattery && isOnBattery() {
            return .skip(reason: "On battery power")
        }

        // Thermal pressure check.
        if config.pauseOnThermalPressure && isThermalPressureHigh() {
            return .skip(reason: "Thermal pressure elevated")
        }

        // Quiet hours: 22:00-07:00.
        if isQuietHours() {
            switch taskId {
            case "camera_presence_check":
                // Camera still runs silently for presence tracking.
                return .silentOnly
            case "screen_activity_check":
                // Screen observations paused entirely during quiet hours.
                return .skip(reason: "Screen observation paused during quiet hours")
            default:
                // Other tasks (overnight_work) run normally during their scheduled window.
                break
            }
        }

        return .normal
    }

    /// Whether the current time falls within quiet hours (22:00-07:00).
    static func isQuietHours() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 22 || hour < 7
    }

    /// Whether the user has been absent long enough to reduce observation frequency.
    ///
    /// Returns true if the user hasn't been seen for more than 30 minutes,
    /// suggesting reduced camera check frequency (e.g. every 5 minutes instead of 30s).
    static func shouldReduceFrequency(lastUserSeenAt: Date?) -> Bool {
        guard let lastSeen = lastUserSeenAt else {
            // Never seen — use reduced frequency.
            return true
        }
        return Date().timeIntervalSince(lastSeen) > 30 * 60
    }

    /// Random jitter in seconds (+-5s) to prevent synchronized VLM load spikes.
    static func randomJitter() -> TimeInterval {
        Double.random(in: -5.0...5.0)
    }

    // MARK: - System Checks

    /// Check if the Mac is running on battery (not connected to power).
    private static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              !sources.isEmpty
        else {
            // No power source info — assume plugged in.
            return false
        }

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
               let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
                if powerSource == kIOPSBatteryPowerValue {
                    return true
                }
            }
        }
        return false
    }

    /// Check if the system is under significant thermal pressure.
    private static func isThermalPressureHigh() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}
