import XCTest

@testable import Fae

/// UX W4 — first-launch onboarding contract.
///
/// These tests encode two product decisions, not just current behavior:
/// 1. The native first-launch flow must front-load ONLY the microphone
///    permission (PTT cannot work without it). Contacts, calendar, and
///    reminders are granted just-in-time by the Apple tools, so a new user
///    never faces a wall of four permission dialogs before Fae speaks.
/// 2. The conversational onboarding turn is one-shot per install and must
///    survive the ~8GB first-run model download: never re-fire once
///    delivered, never fire before the pipeline is ready, never be lost
///    while models are still loading (deferred, not dropped).
final class OnboardingFirstLaunchTests: XCTestCase {

    // MARK: - First-launch permission front-load (mic-only)

    func testFirstLaunchFrontLoadIsMicrophoneOnly() {
        XCTAssertEqual(
            FirstLaunchPermissionPolicy.requested,
            ["microphone"],
            "W4: the first-launch permission front-load must be mic-only — "
                + "re-adding permissions here reintroduces the 4-dialog wall"
        )
    }

    func testAppleDataPermissionsAreDeferredToFirstToolUse() {
        for permission in ["contacts", "calendar", "reminders"] {
            XCTAssertFalse(
                FirstLaunchPermissionPolicy.requested.contains(permission),
                "\(permission) must not be requested at first launch — it is JIT"
            )
            XCTAssertTrue(
                FirstLaunchPermissionPolicy.deferredToFirstUse.contains(permission),
                "\(permission) must be listed as deferred-to-first-use"
            )
        }
    }

    func testNoPermissionIsBothFrontLoadedAndDeferred() {
        let overlap = Set(FirstLaunchPermissionPolicy.requested)
            .intersection(FirstLaunchPermissionPolicy.deferredToFirstUse)
        XCTAssertTrue(
            overlap.isEmpty,
            "a permission cannot be both front-loaded and JIT: \(overlap)"
        )
    }

    // MARK: - One-shot conversational onboarding trigger

    func testDeliveredFlagPermanentlySuppressesRefire() {
        // Once delivered, the conversation must never re-fire — regardless of
        // pipeline state (e.g. app relaunch after onboarding).
        XCTAssertEqual(
            ConversationalOnboardingPolicy.action(alreadyDelivered: true, pipelineReady: true),
            .skip
        )
        XCTAssertEqual(
            ConversationalOnboardingPolicy.action(alreadyDelivered: true, pipelineReady: false),
            .skip
        )
    }

    func testFirstFireWaitsForPipelineReady() {
        // Models still downloading on first run: the turn must be deferred
        // (intent recorded, retried on ready) — not fired and not dropped.
        XCTAssertEqual(
            ConversationalOnboardingPolicy.action(alreadyDelivered: false, pipelineReady: false),
            .deferred
        )
    }

    func testFiresExactlyWhenPipelineIsReadyAndNotYetDelivered() {
        XCTAssertEqual(
            ConversationalOnboardingPolicy.action(alreadyDelivered: false, pipelineReady: true),
            .start
        )
    }
}
