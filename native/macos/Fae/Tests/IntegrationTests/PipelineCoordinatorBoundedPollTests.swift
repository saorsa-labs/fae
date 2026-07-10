import Foundation
import XCTest

@testable import Fae

/// Tests the bounded-poll mechanism that bounds the #4 fallback-TTS load wait.
/// `engine.load` → `TTS.loadModel` has no cooperative-cancellation points, so a
/// grouped/awaited load cannot be time-bounded; instead `inProcessFallbackTTSEngine`
/// polls `engine.isLoaded` via `boundedPoll`. These pin the bound itself.
final class PipelineCoordinatorBoundedPollTests: XCTestCase {

    /// A sendable counter whose predicate flips to true after N reads.
    private actor FlipAfter {
        private var reads = 0
        private let threshold: Int
        init(_ threshold: Int) { self.threshold = threshold }
        func ready() -> Bool {
            reads += 1
            return reads >= threshold
        }
    }

    func testReturnsTrueWhenPredicateFlipsWithinTimeout() async {
        let flip = FlipAfter(3)  // flips true on the 3rd read
        let result = await PipelineCoordinator.boundedPoll(
            predicate: { await flip.ready() }, timeoutMs: 2_000, pollIntervalMs: 5)
        XCTAssertTrue(result, "should observe the predicate flip true within the timeout")
    }

    func testReturnsFalseOnTimeoutWhenPredicateNeverFlips() async {
        // Never flips; tiny timeout keeps the test fast (~50ms).
        let result = await PipelineCoordinator.boundedPoll(
            predicate: { false }, timeoutMs: 50, pollIntervalMs: 10)
        XCTAssertFalse(result, "should time out (return false) when the predicate never flips")
    }

    func testReturnsTrueImmediatelyIfPredicateAlreadyTrue() async {
        let result = await PipelineCoordinator.boundedPoll(
            predicate: { true }, timeoutMs: 50, pollIntervalMs: 10)
        XCTAssertTrue(result, "should short-circuit true on the first read without polling")
    }
}
