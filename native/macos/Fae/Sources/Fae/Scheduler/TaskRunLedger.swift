import Foundation

enum TaskRunState: String, Sendable {
    case idle
    case running
    case success
    case failed
}

struct TaskRunRecord: Sendable, Equatable {
    let taskID: String
    let idempotencyKey: String
    let state: TaskRunState
    let attempt: Int
    let updatedAt: Date
    let lastError: String?
}

/// Tracks scheduler task runs with idempotency and optional SQLite persistence.
///
/// When a `SchedulerPersistenceStore` is provided, all writes go through to
/// SQLite so state survives app restart. The in-memory cache (`seenKeys`)
/// avoids hitting the DB on every tick.
actor TaskRunLedger {
    private var byTask: [String: TaskRunRecord] = [:]
    private var seenKeys: Set<String> = []
    private let store: SchedulerPersistenceStore?

    init(store: SchedulerPersistenceStore? = nil) {
        self.store = store
    }

    func shouldRun(taskID: String, idempotencyKey: String) async -> Bool {
        // Fast path: in-memory cache
        if seenKeys.contains(idempotencyKey) { return false }

        // Slow path: check persistence store
        if let store {
            do {
                if try await store.hasSeenKey(idempotencyKey) {
                    seenKeys.insert(idempotencyKey)
                    return false
                }
            } catch {
                NSLog("TaskRunLedger: persistence check failed: %@", error.localizedDescription)
            }
        }

        seenKeys.insert(idempotencyKey)
        return true
    }

    func markRunning(taskID: String, idempotencyKey: String, attempt: Int) async {
        let record = TaskRunRecord(
            taskID: taskID, idempotencyKey: idempotencyKey,
            state: .running, attempt: attempt,
            updatedAt: Date(), lastError: nil
        )
        byTask[taskID] = record
        await persistRecord(record)
    }

    func markSuccess(taskID: String, idempotencyKey: String, attempt: Int) async {
        let record = TaskRunRecord(
            taskID: taskID, idempotencyKey: idempotencyKey,
            state: .success, attempt: attempt,
            updatedAt: Date(), lastError: nil
        )
        byTask[taskID] = record
        await persistUpdate(idempotencyKey: idempotencyKey, state: .success, error: nil)
    }

    func markFailed(taskID: String, idempotencyKey: String, attempt: Int, error: String) async {
        let record = TaskRunRecord(
            taskID: taskID, idempotencyKey: idempotencyKey,
            state: .failed, attempt: attempt,
            updatedAt: Date(), lastError: error
        )
        byTask[taskID] = record
        await persistUpdate(idempotencyKey: idempotencyKey, state: .failed, error: error)
    }

    func latest(taskID: String) async -> TaskRunRecord? {
        if let cached = byTask[taskID] { return cached }
        // Fall through to persistence store
        guard let store else { return nil }
        do {
            return try await store.latestRun(taskID: taskID)
        } catch {
            NSLog("TaskRunLedger: persistence read failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Return recent run history from the persistence store.
    func recentHistory(taskID: String, limit: Int = 20) async -> [TaskRunRecord] {
        guard let store else { return [] }
        do {
            return try await store.recentRuns(taskID: taskID, limit: limit)
        } catch {
            NSLog("TaskRunLedger: history query failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - Persistence Helpers

    private func persistRecord(_ record: TaskRunRecord) async {
        guard let store else { return }
        do {
            try await store.insertRun(record)
        } catch {
            NSLog("TaskRunLedger: persist insert failed: %@", error.localizedDescription)
        }
    }

    private func persistUpdate(idempotencyKey: String, state: TaskRunState, error: String?) async {
        guard let store else { return }
        do {
            try await store.updateRunState(idempotencyKey: idempotencyKey, state: state, error: error)
        } catch {
            NSLog("TaskRunLedger: persist update failed: %@", error.localizedDescription)
        }
    }
}
