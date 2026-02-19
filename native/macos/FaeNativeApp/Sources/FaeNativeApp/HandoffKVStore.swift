import Foundation
import FaeHandoffKit

// MARK: - HandoffKVStore

/// Thin wrapper around `NSUbiquitousKeyValueStore` for persisting a
/// `ConversationSnapshot` to iCloud as a handoff fallback.
///
/// All methods accept an injectable `store` parameter (defaults to `.default`)
/// so tests can substitute a mock without touching iCloud.
enum HandoffKVStore {

    // MARK: - Constants

    private static let snapshotKey = "fae.handoff.snapshot"

    // MARK: - Encoder / Decoder

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Public API

    /// Persist the snapshot to iCloud key-value store.
    ///
    /// When iCloud is unavailable (no account, MDM restriction, sandbox
    /// limitation), the write is silently skipped with a log warning.
    static func save(_ snapshot: ConversationSnapshot,
                     store: NSUbiquitousKeyValueStore = .default) {
        guard let data = try? encoder.encode(snapshot) else {
            NSLog("HandoffKVStore: failed to encode snapshot")
            return
        }
        store.set(data, forKey: snapshotKey)
        if !store.synchronize() {
            NSLog("HandoffKVStore: iCloud KV synchronize returned false — store may be unavailable")
        }
    }

    /// Load the most recent snapshot from iCloud key-value store.
    ///
    /// Returns `nil` when iCloud is unavailable, the key is absent, or the
    /// stored data cannot be decoded.
    static func load(store: NSUbiquitousKeyValueStore = .default) -> ConversationSnapshot? {
        guard let data = store.data(forKey: snapshotKey) else { return nil }
        return try? decoder.decode(ConversationSnapshot.self, from: data)
    }

    /// Remove the stored snapshot. Always safe — no-op when the key is absent
    /// or iCloud is unavailable.
    static func clear(store: NSUbiquitousKeyValueStore = .default) {
        store.removeObject(forKey: snapshotKey)
        store.synchronize()
    }

    // MARK: - External Change Observation

    /// Begin observing external iCloud changes. When another device writes a
    /// snapshot, `handler` is called on the main queue with the decoded value.
    ///
    /// Retain the returned token to keep the observation alive; releasing it
    /// removes the observer.
    @discardableResult
    static func startObserving(
        store: NSUbiquitousKeyValueStore = .default,
        handler: @escaping (ConversationSnapshot) -> Void
    ) -> NSObjectProtocol {
        // Fetch latest values immediately so we don't miss recent writes.
        store.synchronize()

        return NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { notification in
            // Only react to server-change or initial-sync reasons.
            if let info = notification.userInfo,
               let reason = info[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
               reason != NSUbiquitousKeyValueStoreServerChange
                && reason != NSUbiquitousKeyValueStoreInitialSyncChange {
                return
            }
            if let snapshot = load(store: store) {
                handler(snapshot)
            }
        }
    }
}
