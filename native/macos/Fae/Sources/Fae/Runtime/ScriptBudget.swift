import Foundation

/// Host-enforced resource limits for a single JSC tool-program execution.
///
/// Every ``JSCRuntime/run(script:budget:)`` call receives a budget that caps:
/// - **Wall-clock time** — the script is cancelled after `maxWallClockSeconds`.
/// - **Tool invocations** — `fae.tool()` calls beyond `maxToolCalls` are rejected.
/// - **Concurrent tool calls** — at most `maxConcurrentToolCalls` in-flight at once.
///
/// Budget violations surface as structured ``JSCScriptResult`` errors so the
/// caller (and the LLM that authored the script) can understand what happened.
struct ScriptBudget: Sendable, Equatable {

    /// Maximum number of `fae.tool()` invocations the script may make.
    /// Calls beyond this limit are rejected with a budget-exceeded error.
    let maxToolCalls: Int

    /// Maximum wall-clock seconds the script is allowed to run.
    /// After this deadline the runtime cancels the drain loop and returns
    /// a `.budgetExceeded` result.
    let maxWallClockSeconds: TimeInterval

    /// Maximum number of tool calls that may be in-flight concurrently.
    /// Additional `fae.tool()` calls block (via promise) until a slot opens,
    /// or are rejected if the wall-clock deadline expires first.
    let maxConcurrentToolCalls: Int

    // MARK: - Defaults

    /// The default budget used when the caller does not specify one.
    ///
    /// - 20 tool calls (generous for multi-step programs)
    /// - 120 seconds wall-clock (2 minutes)
    /// - 5 concurrent tool calls
    static let `default` = ScriptBudget(
        maxToolCalls: 20,
        maxWallClockSeconds: 120,
        maxConcurrentToolCalls: 5
    )

    /// A minimal budget suitable for quick single-tool scripts.
    static let minimal = ScriptBudget(
        maxToolCalls: 3,
        maxWallClockSeconds: 30,
        maxConcurrentToolCalls: 2
    )
}

/// Tracks budget consumption during a single script execution.
///
/// Thread-safe: all mutations go through a serial dispatch queue.
final class ScriptBudgetTracker: @unchecked Sendable {

    /// The budget being enforced.
    let budget: ScriptBudget

    /// Serial queue protecting mutable counters.
    private let queue = DispatchQueue(label: "fae.jsc.budget.tracker")

    /// Total number of tool calls initiated so far.
    private var _toolCallCount: Int = 0

    /// Number of tool calls currently in-flight.
    private var _concurrentCount: Int = 0

    /// Whether the script has been cancelled by the host.
    private var _cancelled: Bool = false

    /// The wall-clock deadline computed from the budget.
    let deadline: Date

    init(budget: ScriptBudget) {
        self.budget = budget
        self.deadline = Date().addingTimeInterval(budget.maxWallClockSeconds)
    }

    // MARK: - Query

    /// The total number of tool calls initiated.
    var toolCallCount: Int {
        queue.sync { _toolCallCount }
    }

    /// The number of tool calls currently in-flight.
    var concurrentCount: Int {
        queue.sync { _concurrentCount }
    }

    /// Whether the host has signalled cancellation.
    var isCancelled: Bool {
        queue.sync { _cancelled }
    }

    /// Whether the wall-clock deadline has passed.
    var isExpired: Bool {
        Date() >= deadline
    }

    /// Whether any budget limit has been breached or the script was cancelled.
    var isOverBudget: Bool {
        queue.sync {
            _cancelled || Date() >= deadline || _toolCallCount > budget.maxToolCalls
        }
    }

    // MARK: - Tool Call Gating

    /// Attempt to start a new tool call. Returns `nil` on success (the caller
    /// must call ``finishToolCall()`` when the call completes), or an error
    /// string explaining which budget limit was hit.
    func tryStartToolCall() -> String? {
        queue.sync {
            if _cancelled {
                return "Script execution was cancelled"
            }
            if Date() >= deadline {
                return "Script exceeded wall-clock budget of \(Int(budget.maxWallClockSeconds))s"
            }
            if _toolCallCount >= budget.maxToolCalls {
                return "Script exceeded tool-call budget (\(budget.maxToolCalls) calls)"
            }
            if _concurrentCount >= budget.maxConcurrentToolCalls {
                return "Script exceeded concurrent tool-call limit (\(budget.maxConcurrentToolCalls))"
            }
            _toolCallCount += 1
            _concurrentCount += 1
            return nil
        }
    }

    /// Mark a tool call as finished, freeing a concurrency slot.
    func finishToolCall() {
        queue.sync {
            _concurrentCount = max(0, _concurrentCount - 1)
        }
    }

    // MARK: - Cancellation

    /// Signal cooperative cancellation. In-flight tool calls will finish but
    /// no new ones will be accepted, and the drain loop will exit early.
    func cancel() {
        queue.sync { _cancelled = true }
    }
}
