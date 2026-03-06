import Foundation

/// Persists user-enabled/disabled tool toggles for settings and cowork surfaces.
///
/// Runtime tool-mode and privacy gates still apply. This store adds an extra
/// user-controlled deny layer on top of those hard limits.
enum ToolToggleStore {
    private static let disabledToolsKey = "fae.disabledTools"

    static func disabledToolNames(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: disabledToolsKey) ?? [])
    }

    static func isToolEnabled(_ name: String, defaults: UserDefaults = .standard) -> Bool {
        !disabledToolNames(defaults: defaults).contains(name)
    }

    static func setToolEnabled(_ enabled: Bool, for name: String, defaults: UserDefaults = .standard) {
        var disabled = disabledToolNames(defaults: defaults)
        if enabled {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        defaults.set(disabled.sorted(), forKey: disabledToolsKey)
    }

    static func setDisabledToolNames(_ names: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(names.sorted(), forKey: disabledToolsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: disabledToolsKey)
    }
}
