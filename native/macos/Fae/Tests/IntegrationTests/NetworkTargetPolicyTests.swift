import XCTest
@testable import Fae

final class NetworkTargetPolicyTests: XCTestCase {

    // MARK: - isBlockedIPAddress

    func testIsBlockedLoopback() {
        XCTAssertTrue(NetworkTargetPolicy.isBlockedIPAddress("127.0.0.1"))
    }

    func testIsBlockedPrivate10() {
        XCTAssertTrue(NetworkTargetPolicy.isBlockedIPAddress("10.0.0.1"))
    }

    func testIsBlockedPrivate192() {
        XCTAssertTrue(NetworkTargetPolicy.isBlockedIPAddress("192.168.1.1"))
    }

    func testIsBlockedIPv6Loopback() {
        XCTAssertTrue(NetworkTargetPolicy.isBlockedIPAddress("::1"))
    }

    func testIsBlockedLinkLocal() {
        XCTAssertTrue(NetworkTargetPolicy.isBlockedIPAddress("fe80::1"))
    }

    func testIsNotBlockedPublic() {
        XCTAssertFalse(NetworkTargetPolicy.isBlockedIPAddress("8.8.8.8"))
    }

    func testIsNotBlockedHostname() {
        XCTAssertFalse(NetworkTargetPolicy.isBlockedIPAddress("example.com"))
    }

    func testIsBlockedZero() {
        XCTAssertTrue(NetworkTargetPolicy.isBlockedIPAddress("0.0.0.0"))
    }
}
