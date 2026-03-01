import Foundation
import XCTest
@testable import Fae

final class NetworkAndPathPolicyFuzzTests: XCTestCase {

    func testBlocksKnownLocalTargets() {
        let blocked = [
            "http://localhost:8000",
            "http://127.0.0.1:8080",
            "http://10.1.2.3",
            "http://172.16.1.2",
            "http://192.168.1.2",
            "http://169.254.10.20",
            "http://169.254.169.254/latest/meta-data",
            "http://metadata.google.internal/computeMetadata/v1",
        ]

        for url in blocked {
            XCTAssertNotNil(NetworkTargetPolicy.blockedReason(urlString: url), "Expected blocked: \(url)")
        }
    }

    func testAllowsTypicalPublicTargets() {
        let allowed = [
            "https://example.com",
            "https://api.github.com",
            "https://news.ycombinator.com",
            "http://8.8.8.8",
            "http://1.1.1.1",
        ]

        for url in allowed {
            XCTAssertNil(NetworkTargetPolicy.blockedReason(urlString: url), "Expected allowed: \(url)")
        }
    }

    func testFuzzPrivateIPv4AlwaysBlocked() {
        for _ in 0..<200 {
            let url = "http://\(randomPrivateIPv4())/"
            XCTAssertNotNil(NetworkTargetPolicy.blockedReason(urlString: url), "Expected blocked: \(url)")
        }
    }

    func testFuzzLikelyPublicIPv4MostlyAllowed() {
        for _ in 0..<200 {
            let ip = randomLikelyPublicIPv4()
            let url = "http://\(ip)/"
            XCTAssertNil(NetworkTargetPolicy.blockedReason(urlString: url), "Expected allowed: \(url)")
        }
    }

    func testPathPolicyBlocksSymlinkEscape() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fae-pathpolicy-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let link = tmp.appendingPathComponent("etc-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc")

        let escapedPath = link.appendingPathComponent("hosts").path
        let decision = PathPolicy.validateWritePath(escapedPath)
        if case .blocked = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected symlink escape path to be blocked")
        }
    }

    // MARK: - Helpers

    private func randomPrivateIPv4() -> String {
        let choice = Int.random(in: 0...3)
        switch choice {
        case 0:
            return "10.\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        case 1:
            return "172.\(Int.random(in: 16...31)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        case 2:
            return "192.168.\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        default:
            return "169.254.\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        }
    }

    private func randomLikelyPublicIPv4() -> String {
        while true {
            let a = Int.random(in: 1...223)
            let b = Int.random(in: 0...255)
            let c = Int.random(in: 0...255)
            let d = Int.random(in: 1...254)

            // Skip private/local ranges.
            if a == 10 { continue }
            if a == 127 { continue }
            if a == 172 && (16...31).contains(b) { continue }
            if a == 192 && b == 168 { continue }
            if a == 169 && b == 254 { continue }

            return "\(a).\(b).\(c).\(d)"
        }
    }
}
