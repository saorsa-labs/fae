import XCTest
@testable import Fae

final class CapabilitySnapshotServiceTests: XCTestCase {
    func testPolicyProfileMapping() {
        XCTAssertEqual(CapabilitySnapshotService.policyProfile(for: "off"), "more_cautious")
        XCTAssertEqual(CapabilitySnapshotService.policyProfile(for: "read_only"), "more_cautious")
        XCTAssertEqual(CapabilitySnapshotService.policyProfile(for: "full"), "balanced")
        XCTAssertEqual(CapabilitySnapshotService.policyProfile(for: "full_no_approval"), "more_autonomous")
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
        let approvalSnapshot = ApprovedToolsStore.ApprovalSnapshot(
            approvedTools: ["read"],
            approveAllReadonly: true,
            approveAll: false
        )

        let snapshot = CapabilitySnapshotService.buildSnapshot(
            triggerText: "test",
            toolMode: "read_only",
            speakerState: "Speaker unknown",
            ownerGateEnabled: false,
            ownerProfileExists: false,
            permissions: permissions,
            thinkingEnabled: false,
            bargeInEnabled: true,
            requireDirectAddress: false,
            visionEnabled: false,
            voiceIdentityLock: true,
            approvalSnapshot: approvalSnapshot,
            registry: registry
        )

        XCTAssertEqual(snapshot.policyProfile, "more_cautious")
        XCTAssertTrue(snapshot.allowedTools.contains("read"))
        XCTAssertTrue(snapshot.deniedTools.contains("write"))
        XCTAssertEqual(snapshot.approvedTools, ["read"])
        XCTAssertTrue(snapshot.approveAllReadonly)
        XCTAssertFalse(snapshot.approveAllInCurrentMode)
        XCTAssertTrue(snapshot.missingPermissionActions.contains(where: { $0.capability == "contacts" }))
        XCTAssertTrue(snapshot.missingPermissionActions.contains(where: { $0.capability == "screen_recording" }))
    }
}
