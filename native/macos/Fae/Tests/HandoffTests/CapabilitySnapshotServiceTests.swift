import XCTest
@testable import Fae

final class CapabilitySnapshotServiceTests: XCTestCase {
    func testPolicyProfileMapping() {
        XCTAssertEqual(CapabilitySnapshotService.policyProfile(for: "assistant"), "assistant")
        XCTAssertEqual(CapabilitySnapshotService.policyProfile(for: "full"), "full_access")
    }

    func testSnapshotBuildIncludesToolAvailabilityAndPermissions() {
        let registry = ToolRegistry.buildDefault()
        let permissions = PermissionStatusProvider.Snapshot(
            microphone: true,
            contacts: false,
            calendar: true,
            reminders: false,
            screenRecording: false,
            camera: true
        )

        let snapshot = CapabilitySnapshotService.buildSnapshot(
            triggerText: "test",
            toolMode: "assistant",
            privacyMode: "local_preferred",
            speakerState: "Speaker unknown",
            ownerGateEnabled: false,
            ownerProfileExists: false,
            permissions: permissions,
            thinkingEnabled: false,
            requireDirectAddress: false,
            visionEnabled: false,
            voiceIdentityLock: true,
            registry: registry
        )

        XCTAssertEqual(snapshot.policyProfile, "assistant")
        XCTAssertTrue(snapshot.allowedTools.contains("read"))
        XCTAssertTrue(snapshot.missingPermissionActions.contains(where: { $0.capability == "contacts" }))
        XCTAssertTrue(snapshot.missingPermissionActions.contains(where: { $0.capability == "screen_recording" }))
    }
}
