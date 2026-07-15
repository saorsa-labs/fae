import XCTest
@testable import Fae

/// Duplicate-injection guard (live incident 2026-07-15): the composer gives no
/// feedback while a turn is queued behind a slow LLM, so the owner re-sent the
/// same text 3.8s later — both copies became full daemon turns (identical audit
/// arg_hash) and Fae answered twice. `PipelineCoordinator.isDuplicateInjection`
/// must drop the resend, and ONLY the resend: identical text while idle is a
/// deliberate new turn, different text always passes, and the window is finite.
final class InjectionDedupeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_134_063)  // the live evt-14 instant

    func testDropsIdenticalResendWithinWindowWhileGenerating() {
        // The live shape: same text, 3.8s apart, first turn still generating.
        XCTAssertTrue(
            PipelineCoordinator.isDuplicateInjection(
                text: "hf_EXAMPLE_TOKEN_VALUE",
                previousText: "hf_EXAMPLE_TOKEN_VALUE",
                previousAt: now.addingTimeInterval(-3.8),
                now: now,
                generationActive: true
            )
        )
    }

    func testAllowsIdenticalResendWhenIdle() {
        // No generation in flight → the user really wants to say it again.
        XCTAssertFalse(
            PipelineCoordinator.isDuplicateInjection(
                text: "yes",
                previousText: "yes",
                previousAt: now.addingTimeInterval(-3.8),
                now: now,
                generationActive: false
            )
        )
    }

    func testAllowsDifferentTextWhileGenerating() {
        // Different text is a barge-in, never a duplicate.
        XCTAssertFalse(
            PipelineCoordinator.isDuplicateInjection(
                text: "actually stop",
                previousText: "hf_EXAMPLE_TOKEN_VALUE",
                previousAt: now.addingTimeInterval(-2),
                now: now,
                generationActive: true
            )
        )
    }

    func testAllowsIdenticalResendAfterWindowExpires() {
        XCTAssertFalse(
            PipelineCoordinator.isDuplicateInjection(
                text: "yes",
                previousText: "yes",
                previousAt: now.addingTimeInterval(-(PipelineCoordinator.duplicateInjectionWindow + 1)),
                now: now,
                generationActive: true
            )
        )
    }

    func testAllowsFirstEverInjection() {
        XCTAssertFalse(
            PipelineCoordinator.isDuplicateInjection(
                text: "hello",
                previousText: nil,
                previousAt: nil,
                now: now,
                generationActive: true
            )
        )
    }
}
