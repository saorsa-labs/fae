import Foundation

/// Safe-boot mode that bypasses user customizations without deleting data.
///
/// When active, Fae uses bundled defaults for soul/instructions, restricts
/// tools to read-only, skips the scheduler, and disables memory capture.
/// Rescue mode is a temporary overlay — deactivating restores normal operation.
@MainActor
final class RescueMode: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published var availableSnapshots: [GitVaultManager.VaultSnapshot] = []
    @Published var isRestoring: Bool = false

    func activate() {
        isActive = true
        NSLog("RescueMode: activated — safe boot with defaults")
    }

    func deactivate() {
        isActive = false
        NSLog("RescueMode: deactivated — returning to normal operation")
    }

    /// Load vault snapshots for the restore UI.
    func loadSnapshots(from vault: GitVaultManager) async {
        do {
            availableSnapshots = try await vault.listSnapshots(limit: 20)
        } catch {
            NSLog("RescueMode: failed to load snapshots: %@", error.localizedDescription)
            availableSnapshots = []
        }
    }
}
