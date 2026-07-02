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

    /// Vault used by the restore UI — wired by `FaeCore` when rescue mode is registered.
    var vault: GitVaultManager?

    func activate() {
        isActive = true
        NSLog("RescueMode: activated — safe boot with defaults")
    }

    func deactivate() {
        isActive = false
        NSLog("RescueMode: deactivated — returning to normal operation")
    }

    /// Load vault snapshots for the restore UI, using the wired `vault`.
    ///
    /// A no-op that clears the list when no vault is wired, so the UI shows an
    /// empty backup list rather than stale entries.
    func loadSnapshots() async {
        guard let vault else {
            NSLog("RescueMode: loadSnapshots skipped — no vault wired")
            availableSnapshots = []
            return
        }
        await loadSnapshots(from: vault)
    }

    /// Restore from a vault snapshot (or HEAD) using the wired `vault`.
    ///
    /// Returns `false` without touching any data when no vault is wired.
    @discardableResult
    func restore(commit: String? = nil) async -> Bool {
        guard let vault else {
            NSLog("RescueMode: restore skipped — no vault wired")
            return false
        }
        return await restore(commit: commit, from: vault)
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
