import Foundation

/// Three-state circuit breaker for adaptive engine selection.
///
/// Closed → (N failures) → Open → (cooldown elapsed) → HalfOpen → success → Closed
///                                                                 failure → Open
actor CircuitBreaker {
    /// Circuit breaker state for a single engine.
    enum CircuitState: Sendable {
        case closed
        case open
        case halfOpen
    }

    /// Health record for a single engine.
    struct EngineHealth: Sendable {
        var state: CircuitState = .closed
        var consecutiveFailures: Int = 0
        var lastFailureAt: Date?
        var lastSuccessAt: Date?
    }

    /// Configuration.
    let failureThreshold: Int
    let cooldownSeconds: TimeInterval

    /// Per-engine health state.
    private var engines: [SearchEngine: EngineHealth] = [:]

    init(failureThreshold: Int = 3, cooldownSeconds: TimeInterval = 60) {
        self.failureThreshold = failureThreshold
        self.cooldownSeconds = cooldownSeconds
    }

    /// Record a successful query for an engine.
    func recordSuccess(_ engine: SearchEngine) {
        var health = engines[engine] ?? EngineHealth()
        health.state = .closed
        health.consecutiveFailures = 0
        health.lastSuccessAt = Date()
        engines[engine] = health
    }

    /// Record a failed query for an engine.
    func recordFailure(_ engine: SearchEngine) {
        var health = engines[engine] ?? EngineHealth()
        health.consecutiveFailures += 1
        health.lastFailureAt = Date()

        if health.consecutiveFailures >= failureThreshold {
            health.state = .open
        }
        engines[engine] = health
    }

    /// Whether a query should be attempted for this engine.
    func shouldAttempt(_ engine: SearchEngine) -> Bool {
        let health = engines[engine] ?? EngineHealth()

        switch health.state {
        case .closed, .halfOpen:
            return true
        case .open:
            // Check if cooldown has elapsed.
            guard let lastFailure = health.lastFailureAt else { return true }
            if Date().timeIntervalSince(lastFailure) >= cooldownSeconds {
                // Transition to halfOpen — allow one probe request.
                var updated = health
                updated.state = .halfOpen
                engines[engine] = updated
                return true
            }
            return false
        }
    }

    /// Get current state for an engine.
    func engineState(_ engine: SearchEngine) -> CircuitState {
        (engines[engine] ?? EngineHealth()).state
    }

    /// Health report for all tracked engines.
    func healthReport() -> [(engine: SearchEngine, state: CircuitState, failures: Int)] {
        engines.map { ($0.key, $0.value.state, $0.value.consecutiveFailures) }
    }

    /// Reset all engine state.
    func reset() {
        engines.removeAll()
    }
}

/// Process-wide singleton circuit breaker.
actor GlobalCircuitBreaker {
    static let shared = GlobalCircuitBreaker()
    private let breaker = CircuitBreaker()

    func recordSuccess(_ engine: SearchEngine) async {
        await breaker.recordSuccess(engine)
    }

    func recordFailure(_ engine: SearchEngine) async {
        await breaker.recordFailure(engine)
    }

    func shouldAttempt(_ engine: SearchEngine) async -> Bool {
        await breaker.shouldAttempt(engine)
    }

    func reset() async {
        await breaker.reset()
    }
}
