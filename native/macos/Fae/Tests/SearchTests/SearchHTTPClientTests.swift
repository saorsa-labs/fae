import XCTest
@testable import Fae

final class SearchHTTPClientTests: XCTestCase {

    // MARK: - User-Agent rotation

    func testUserAgentIsNotEmpty() {
        let ua = SearchHTTPClient.userAgent()
        XCTAssertFalse(ua.isEmpty)
        XCTAssertTrue(ua.contains("Mozilla"), "User-Agent should look like a real browser")
    }

    func testUserAgentRotation() {
        // Call many times and verify we get at least 2 different UAs (statistical).
        var agents = Set<String>()
        for _ in 0..<50 {
            agents.insert(SearchHTTPClient.userAgent())
        }
        XCTAssertGreaterThan(agents.count, 1, "Should rotate between multiple User-Agents")
    }

    func testCustomUserAgent() {
        let ua = SearchHTTPClient.userAgent(custom: "CustomBot/1.0")
        XCTAssertEqual(ua, "CustomBot/1.0")
    }

    func testUserAgentsArrayNotEmpty() {
        XCTAssertFalse(SearchHTTPClient.userAgents.isEmpty)
        XCTAssertGreaterThanOrEqual(SearchHTTPClient.userAgents.count, 3)
    }

    // MARK: - Session configuration

    func testSessionConfigurationUsesTimeout() {
        var config = SearchConfig.default
        config.timeoutSeconds = 15
        let sessionConfig = SearchHTTPClient.sessionConfiguration(config: config)
        XCTAssertEqual(sessionConfig.timeoutIntervalForRequest, 15)
    }

    // MARK: - Request building

    func testGetRequestHasUserAgent() {
        let url = URL(string: "https://example.com")!
        let config = SearchConfig.default
        let request = SearchHTTPClient.getRequest(url: url, config: config)

        XCTAssertEqual(request.httpMethod, "GET")
        let ua = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua)
        XCTAssertTrue(ua?.contains("Mozilla") ?? false)
    }

    func testGetRequestHasAcceptHeaders() {
        let url = URL(string: "https://example.com")!
        let request = SearchHTTPClient.getRequest(url: url, config: .default)

        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testPostRequestHasBody() {
        let url = URL(string: "https://example.com")!
        let request = SearchHTTPClient.postRequest(url: url, body: "q=test", config: .default)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNotNil(request.httpBody)
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "q=test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded")
    }

    func testConfigUserAgentOverride() {
        var config = SearchConfig.default
        config.userAgent = "CustomAgent/1.0"
        let url = URL(string: "https://example.com")!
        let request = SearchHTTPClient.getRequest(url: url, config: config)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CustomAgent/1.0")
    }
}
