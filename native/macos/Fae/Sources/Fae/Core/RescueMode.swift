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

    /// Restore Fae's data from a vault snapshot (or HEAD when `commit` is nil).
    ///
    /// Drives `isRestoring` around the call so the restore UI can show progress
    /// and disable interaction. Returns `true` on success. The underlying
    /// `GitVaultManager.restore` copies each file into place atomically, so a
    /// mid-restore failure never leaves a deleted-but-not-replaced database.
    @discardableResult
    func restore(commit: String? = nil, from vault: GitVaultManager) async -> Bool {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await vault.restore(commitHash: commit)
            NSLog("RescueMode: restored from vault snapshot %@", commit ?? "HEAD")
            return true
        } catch {
            NSLog("RescueMode: restore failed: %@", error.localizedDescription)
            return false
        }
    }
}
