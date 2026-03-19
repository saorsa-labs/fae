import Foundation

/// Strategy protocol for making interruption decisions.
///
/// Implementations receive a snapshot of pipeline state and return a decision:
/// ignore, keep collecting, or interrupt now. This allows swapping between
/// the legacy fixed-threshold behavior and adaptive heuristic approaches
/// without modifying PipelineCoordinator.
protocol InterruptionDeciding: Sendable {
    /// Process an interruption input and return a decision.
    mutating func process(_ input: InterruptionInput) -> InterruptionDecision
    /// Reset internal state (e.g., when assistant stops speaking).
    mutating func reset()
}
