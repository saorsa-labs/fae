import Foundation

/// Safe-boot mode that bypasses user customizations without deleting data.
///
/// When active, Fae uses bundled defaults for soul/instructions, restricts
/// tools to read-only, skips the scheduler, and disables memory capture.
/// Rescue mode is a temporary overlay — deactivating restores normal operation.
@MainActor
final class RescueMode: ObservableObject {
    @Published private(set) var isActive: Bool = false

    func activate() {
        isActive = true
        NSLog("RescueMode: activated — safe boot with defaults")
    }

    func deactivate() {
        isActive = false
        NSLog("RescueMode: deactivated — returning to normal operation")
    }
}
