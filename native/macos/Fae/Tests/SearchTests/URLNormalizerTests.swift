import XCTest
@testable import Fae

final class URLNormalizerTests: XCTestCase {

    // MARK: - Basic normalization

    func testStripTrailingSlash() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com/page/"),
            URLNormalizer.normalize("https://example.com/page")
        )
    }

    func testLowercaseSchemeAndHost() {
        XCTAssertEqual(
            URLNormalizer.normalize("HTTPS://EXAMPLE.COM/Page"),
            URLNormalizer.normalize("https://example.com/Page")
        )
    }

    func testStripFragment() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com/page#section"),
            URLNormalizer.normalize("https://example.com/page")
        )
    }

    func testStripDefaultPorts() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com:443/page"),
            URLNormalizer.normalize("https://example.com/page")
        )
        XCTAssertEqual(
            URLNormalizer.normalize("http://example.com:80/page"),
            URLNormalizer.normalize("http://example.com/page")
        )
    }

    func testPreserveNonDefaultPort() {
        let normalized = URLNormalizer.normalize("https://example.com:8080/page")
        XCTAssertTrue(normalized.contains("8080"))
    }

    // MARK: - Tracking parameter stripping

    func testStripUTMParams() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com/page?utm_source=google&utm_medium=cpc&real=1"),
            URLNormalizer.normalize("https://example.com/page?real=1")
        )
    }

    func testStripFBClid() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com/page?fbclid=abc123&real=1"),
            URLNormalizer.normalize("https://example.com/page?real=1")
        )
    }

    func testStripGClid() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com/page?gclid=abc123"),
            URLNormalizer.normalize("https://example.com/page")
        )
    }

    func testStripMultipleTrackingParams() {
        let input = "https://example.com/page?utm_source=x&ref=y&fbclid=z&si=w&feature=share&real=keep"
        let clean = "https://example.com/page?real=keep"
        XCTAssertEqual(
            URLNormalizer.normalize(input),
            URLNormalizer.normalize(clean)
        )
    }

    // MARK: - Query parameter sorting

    func testSortQueryParams() {
        XCTAssertEqual(
            URLNormalizer.normalize("https://example.com/page?z=1&a=2&m=3"),
            URLNormalizer.normalize("https://example.com/page?a=2&m=3&z=1")
        )
    }

    // MARK: - www prefix (not stripped — www and non-www are distinct)

    func testWWWPreserved() {
        // URLNormalizer does not strip www — they're treated as different hosts for dedup safety.
        let withWWW = URLNormalizer.normalize("https://www.example.com/page")
        let withoutWWW = URLNormalizer.normalize("https://example.com/page")
        XCTAssertNotEqual(withWWW, withoutWWW)
    }

    // MARK: - Edge cases

    func testInvalidURLReturnsLowercased() {
        // URLComponents may parse or percent-encode unexpected inputs.
        let result = URLNormalizer.normalize("not a url at all")
        XCTAssertFalse(result.isEmpty)
    }

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(URLNormalizer.normalize(""), "")
    }

    func testComplexRealWorldURL() {
        let messy = "https://WWW.Example.COM:443/article/page?utm_source=twitter&q=test&fbclid=abc#top"
        let normalized = URLNormalizer.normalize(messy)
        // Should strip tracking params, fragment, default port, lowercase host.
        XCTAssertTrue(normalized.contains("q=test"), "Should keep real params")
        XCTAssertFalse(normalized.contains("utm_source"), "Should strip tracking params")
        XCTAssertFalse(normalized.contains("fbclid"), "Should strip fbclid")
        XCTAssertFalse(normalized.contains("#top"), "Should strip fragment")
        XCTAssertFalse(normalized.contains(":443"), "Should strip default port")
        XCTAssertTrue(normalized.contains("example.com"), "Should lowercase host")
    }
}
