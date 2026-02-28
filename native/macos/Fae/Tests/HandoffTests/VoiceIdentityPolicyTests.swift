import XCTest
@testable import Fae

final class VoiceIdentityPolicyTests: XCTestCase {
    func testNonOwnerLowRiskAllows() {
        var cfg = FaeConfig.SpeakerConfig()
        cfg.requireOwnerForTools = true
        let d = VoiceIdentityPolicy.evaluateSensitiveAction(config: cfg, isOwner: false, risk: .low, toolName: "read")
        XCTAssertEqual(d, .allow)
    }

    func testNonOwnerMediumRequiresStepUp() {
        var cfg = FaeConfig.SpeakerConfig()
        cfg.requireOwnerForTools = true
        let d = VoiceIdentityPolicy.evaluateSensitiveAction(config: cfg, isOwner: false, risk: .medium, toolName: "edit")
        if case .requireStepUp(let msg) = d {
            XCTAssertTrue(msg.contains("medium-risk"))
        } else {
            XCTFail("Expected step-up")
        }
    }

    func testNonOwnerHighDenies() {
        var cfg = FaeConfig.SpeakerConfig()
        cfg.requireOwnerForTools = true
        let d = VoiceIdentityPolicy.evaluateSensitiveAction(config: cfg, isOwner: false, risk: .high, toolName: "bash")
        if case .deny(let msg) = d {
            XCTAssertTrue(msg.contains("high-risk"))
        } else {
            XCTFail("Expected deny")
        }
    }
}
