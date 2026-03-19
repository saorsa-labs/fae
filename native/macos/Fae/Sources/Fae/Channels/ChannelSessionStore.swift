import Foundation

/// Manages all active channel sessions keyed by sender identity.
///
/// The store is an actor to serialise session creation and cleanup. Sessions
/// are created lazily on first message from a sender and cleaned up when idle
/// for longer than the configured timeout.
actor ChannelSessionStore {
    /// All active sessions keyed by `SessionKey`.
    private var sessions: [SessionKey: ChannelSession] = [:]

    /// Default idle timeout before a session is eligible for cleanup (1 hour).
    private let defaultIdleTimeout: TimeInterval = 3600

    /// The number of currently tracked sessions.
    var activeSessionCount: Int {
        sessions.count
    }

    /// Retrieve or create a session for the given key.
    ///
    /// If a session already exists for this sender+channel pair, it is returned.
    /// Otherwise a new session is created, stored, and returned.
    ///
    /// - Parameters:
    ///   - key: The composite channel + sender key.
    ///   - displayName: Optional display name to set on a newly created session.
    /// - Returns: The existing or newly created `ChannelSession`.
    func session(for key: SessionKey, displayName: String? = nil) -> ChannelSession {
        if let existing = sessions[key] {
            if let displayName {
                existing.updateDisplayName(displayName)
            }
            return existing
        }
        let newSession = ChannelSession(key: key, senderDisplayName: displayName)
        sessions[key] = newSession
        return newSession
    }

    /// Remove sessions that have been idle longer than the specified interval.
    ///
    /// - Parameter timeout: The idle duration threshold. Defaults to 1 hour.
    /// - Returns: The number of sessions that were removed.
    @discardableResult
    func cleanupIdle(olderThan timeout: TimeInterval? = nil) -> Int {
        let threshold = timeout ?? defaultIdleTimeout
        let cutoff = Date().addingTimeInterval(-threshold)
        var removedCount = 0

        for (key, session) in sessions {
            if session.lastActivity < cutoff {
                session.deactivate()
                sessions.removeValue(forKey: key)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            NSLog("ChannelSessionStore: cleaned up %d idle session(s), %d remaining",
                  removedCount, sessions.count)
        }

        return removedCount
    }

    /// Remove a specific session by key.
    ///
    /// - Parameter key: The session key to remove.
    /// - Returns: The removed session, if it existed.
    @discardableResult
    func removeSession(for key: SessionKey) -> ChannelSession? {
        let session = sessions.removeValue(forKey: key)
        session?.deactivate()
        return session
    }

    /// Remove all sessions. Used for testing and shutdown.
    func removeAll() {
        for session in sessions.values {
            session.deactivate()
        }
        sessions.removeAll()
    }
}
