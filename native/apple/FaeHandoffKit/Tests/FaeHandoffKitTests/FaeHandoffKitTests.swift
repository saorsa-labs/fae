import XCTest
@testable import FaeHandoffKit

final class FaeHandoffKitTests: XCTestCase {
    func testPayloadRoundTrip() throws {
        let payload = FaeHandoffPayload(
            target: .watch,
            command: "move to my watch",
            issuedAtEpochMs: 1_701_000_000_000
        )

        let userInfo = FaeHandoffContract.userInfo(from: payload)
        let decoded = try FaeHandoffContract.payload(from: userInfo)
        XCTAssertEqual(decoded, payload)
    }

    func testMissingTargetFails() {
        XCTAssertThrowsError(
            try FaeHandoffContract.payload(from: ["command": "move to my phone"])
        ) { error in
            XCTAssertEqual(error as? FaeHandoffError, .missingField("target"))
        }
    }

    func testInvalidTargetFails() {
        XCTAssertThrowsError(
            try FaeHandoffContract.payload(
                from: ["target": "tablet", "issuedAtEpochMs": 123]
            )
        ) { error in
            XCTAssertEqual(error as? FaeHandoffError, .invalidTarget("tablet"))
        }
    }
}
