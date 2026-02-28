import Foundation

extension FaeScheduler {
    func retryDelaySeconds(attempt: Int, maxRetries: Int = 3) -> Int? {
        guard attempt < maxRetries else { return nil }
        return min(60, Int(pow(2.0, Double(attempt))))
    }

    func makeIdempotencyKey(taskID: String, at date: Date = Date()) -> String {
        let bucket = Int(date.timeIntervalSince1970 / 60)
        return "\(taskID):\(bucket)"
    }

    /// Execute a task with idempotency, persistence, and auto-retry.
    ///
    /// On failure, computes exponential backoff delay and retries up to
    /// `maxRetries` times. Each retry uses the same idempotency key so
    /// the ledger tracks the full attempt chain.
    func executeReliably(
        taskID: String,
        attempt: Int = 0,
        maxRetries: Int = 3,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        let key = makeIdempotencyKey(taskID: taskID)
        let ledger = self.taskRunLedger
        let should = await ledger.shouldRun(taskID: taskID, idempotencyKey: key)
        guard should else { return }

        await ledger.markRunning(taskID: taskID, idempotencyKey: key, attempt: attempt)
        do {
            try await operation()
            await ledger.markSuccess(taskID: taskID, idempotencyKey: key, attempt: attempt)
        } catch {
            let errorMsg = String(describing: error)
            await ledger.markFailed(
                taskID: taskID, idempotencyKey: key,
                attempt: attempt, error: errorMsg
            )

            // Auto-retry with exponential backoff
            if let delay = retryDelaySeconds(attempt: attempt, maxRetries: maxRetries) {
                NSLog(
                    "FaeScheduler: task '%@' failed (attempt %d), retrying in %ds: %@",
                    taskID, attempt, delay, errorMsg
                )
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                await executeReliably(
                    taskID: taskID,
                    attempt: attempt + 1,
                    maxRetries: maxRetries,
                    operation: operation
                )
            } else {
                NSLog(
                    "FaeScheduler: task '%@' failed after %d attempts, giving up: %@",
                    taskID, attempt + 1, errorMsg
                )
            }
        }
    }

    func latestRunRecord(taskID: String) async -> TaskRunRecord? {
        await taskRunLedger.latest(taskID: taskID)
    }
}
