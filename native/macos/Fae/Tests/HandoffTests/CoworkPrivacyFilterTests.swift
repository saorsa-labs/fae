import XCTest
@testable import Fae

/// Verify CoworkToolExecutor correctly scans outbound prompts for PII via the
/// injected privacy filter bridge, and treats the scan as detect-only (no
/// prompt mutation) for this prototype.
final class CoworkPrivacyFilterTests: XCTestCase {

    // MARK: - Test Doubles

    private actor StubPrivacyFilter: PrivacyFilterScanning {
        private let result: PrivacyFilterResult
        private(set) var scanCount: Int = 0
        private(set) var lastInput: String?

        init(_ result: PrivacyFilterResult) {
            self.result = result
        }

        func scan(_ text: String) async -> PrivacyFilterResult {
            scanCount += 1
            lastInput = text
            return result
        }
    }

    private actor SpySecurityLogger: SecurityEventLogging {
        private(set) var events: [(event: String, categories: String?)] = []

        func log(
            event: String,
            toolName: String,
            decision: String?,
            reasonCode: String?,
            approved: Bool?,
            success: Bool?,
            error: String?,
            arguments: [String: Any]?
        ) {
            events.append((event: event, categories: arguments?["categories"] as? String))
        }
    }

    private struct StubProvider: CoworkLLMProvider {
        let kind: CoworkLLMProviderKind = .openAICompatibleExternal
        func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse {
            CoworkProviderResponse(content: "response", status: "ok")
        }
    }

    // MARK: - Helpers

    private func makeRequest(_ promptText: String = "hello world") -> CoworkProviderRequest {
        let prepared = WorkWithFaePreparedPrompt(
            userVisiblePrompt: promptText,
            faeLocalPrompt: promptText,
            shareablePrompt: promptText,
            containsLocalOnlyContext: false
        )
        return CoworkProviderRequest(model: "gpt-4", preparedPrompt: prepared)
    }

    private func makeExecutor(
        filter: (any PrivacyFilterScanning)? = nil,
        logger: SpySecurityLogger? = nil
    ) -> CoworkToolExecutor {
        let policy = DamageControlPolicy()
        return CoworkToolExecutor(
            damageControlPolicy: policy,
            inboundScanPatterns: [],
            isReady: true,
            securityLogger: logger,
            eventBus: nil,
            privacyFilter: filter
        )
    }

    // MARK: - Tests

    func testPrivacyFilterNotSet_noScanPerformed() async throws {
        let logger = SpySecurityLogger()
        let executor = makeExecutor(filter: nil, logger: logger)

        _ = try await executor.submit(request: makeRequest(), provider: StubProvider())

        let metrics = await executor.getMetrics()
        XCTAssertEqual(metrics["openAICompatibleExternal"]?.piiDetected ?? 0, 0,
                       "No scan should run when filter is nil")
        let events = await logger.events.map { $0.event }
        XCTAssertFalse(events.contains("cowork_pii_detected"))
    }

    func testPrivacyFilterCleanText_noEventEmitted() async throws {
        let filter = StubPrivacyFilter(PrivacyFilterResult(
            spans: [],
            redacted: "hello world",
            hasPII: false,
            unavailable: false
        ))
        let logger = SpySecurityLogger()
        let executor = makeExecutor(filter: filter, logger: logger)

        _ = try await executor.submit(request: makeRequest(), provider: StubProvider())

        let metrics = await executor.getMetrics()
        XCTAssertEqual(metrics["openAICompatibleExternal"]?.piiDetected ?? 0, 0)
        await XCTAssertEqualAsync(await filter.scanCount, 1, "Scan ran once even on clean text")
        let events = await logger.events.map { $0.event }
        XCTAssertFalse(events.contains("cowork_pii_detected"))
    }

    func testPrivacyFilterDetectsPII_eventAndMetricAndLog() async throws {
        let spans = [
            PrivacyFilterSpan(category: "private_email", text: "a@b.com", start: 10, end: 17),
            PrivacyFilterSpan(category: "private_phone", text: "555", start: 20, end: 23),
            PrivacyFilterSpan(category: "private_email", text: "c@d.com", start: 30, end: 37),
        ]
        let filter = StubPrivacyFilter(PrivacyFilterResult(
            spans: spans,
            redacted: "[redacted]",
            hasPII: true,
            unavailable: false
        ))
        let logger = SpySecurityLogger()
        let executor = makeExecutor(filter: filter, logger: logger)

        _ = try await executor.submit(request: makeRequest("email a@b.com phone 555 alt c@d.com"),
                                      provider: StubProvider())

        let metrics = await executor.getMetrics()
        XCTAssertEqual(metrics["openAICompatibleExternal"]?.piiDetected ?? 0, 1,
                       "piiDetected counter incremented once per request, not per span")

        // Allow the detached logging Task to settle before reading spy state.
        try await Task.sleep(for: .milliseconds(50))
        let events = await logger.events
        let piiEvents = events.filter { $0.event == "cowork_pii_detected" }
        XCTAssertEqual(piiEvents.count, 1)
        XCTAssertEqual(piiEvents.first?.categories, "private_email,private_phone",
                       "Duplicate categories are folded; first-seen order preserved")
    }

    func testPrivacyFilterUnavailable_observedAsPassthrough() async throws {
        let filter = StubPrivacyFilter(PrivacyFilterResult.passthrough("hello world"))
        let logger = SpySecurityLogger()
        let executor = makeExecutor(filter: filter, logger: logger)

        _ = try await executor.submit(request: makeRequest(), provider: StubProvider())

        let metrics = await executor.getMetrics()
        XCTAssertEqual(metrics["openAICompatibleExternal"]?.piiDetected ?? 0, 0,
                       "Unavailable filter must not bump the metric")
        let events = await logger.events.map { $0.event }
        XCTAssertFalse(events.contains("cowork_pii_detected"))
    }

    // MARK: - Bridge result type

    func testPrivacyFilterResult_passthroughConstructor() {
        let result = PrivacyFilterResult.passthrough("original text")
        XCTAssertEqual(result.redacted, "original text")
        XCTAssertTrue(result.unavailable)
        XCTAssertFalse(result.hasPII)
        XCTAssertTrue(result.spans.isEmpty)
    }
}

// MARK: - Async assertion helper

private func XCTAssertEqualAsync<T: Equatable>(
    _ expression1: @autoclosure () async throws -> T,
    _ expression2: @autoclosure () -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) async rethrows {
    let lhs = try await expression1()
    XCTAssertEqual(lhs, expression2(), message(), file: file, line: line)
}
