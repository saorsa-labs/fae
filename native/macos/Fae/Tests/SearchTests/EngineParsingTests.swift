import XCTest
@testable import Fae

/// Unit tests for each engine's HTML parser using known HTML samples.
/// These tests don't require network — they verify parsing logic directly.
final class EngineParsingTests: XCTestCase {

    // MARK: - DuckDuckGo parsing

    func testDDGParseResultLink() {
        let html = """
        <div class="results">
            <div class="result results_links results_links_deep web-result">
                <a class="result__a" href="https://example.com/page1">Example Title</a>
                <a class="result__snippet">This is the snippet text for the result.</a>
            </div>
            <div class="result results_links results_links_deep web-result">
                <a class="result__a" href="https://example.com/page2">Second Result</a>
                <a class="result__snippet">Second snippet text here.</a>
            </div>
        </div>
        """
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Example Title")
        XCTAssertEqual(results[0].url, "https://example.com/page1")
        XCTAssertTrue(results[0].snippet.contains("snippet text"))
        XCTAssertEqual(results[1].title, "Second Result")
    }

    func testDDGParseRedirectURL() {
        let html = """
        <div class="result results_links results_links_deep web-result">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Freal-page&rut=abc123">Redirected Title</a>
            <a class="result__snippet">Snippet here.</a>
        </div>
        """
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].url, "https://example.com/real-page",
            "Should unwrap DDG redirect URL")
    }

    func testDDGParseEmptyHTML() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: "<html><body></body></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testDDGParseMaxResults() {
        var html = "<div class='results'>"
        for i in 0..<20 {
            html += """
            <div class="result results_links results_links_deep web-result">
                <a class="result__a" href="https://example.com/page\(i)">Title \(i)</a>
                <a class="result__snippet">Snippet \(i).</a>
            </div>
            """
        }
        html += "</div>"

        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 5, "Should respect maxResults limit")
    }

    // MARK: - Google parsing

    func testGoogleParseResultBlock() {
        let html = """
        <div class="g">
            <a href="https://example.com/google-result"><h3>Google Result Title</h3></a>
            <span class="VwiC3b">This is a Google snippet.</span>
        </div>
        <div id="botstuff"></div>
        """
        let engine = GoogleEngine()
        let results = engine.parseGoogleResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Google Result Title")
        XCTAssertEqual(results[0].url, "https://example.com/google-result")
        XCTAssertTrue(results[0].snippet.contains("Google snippet"))
    }

    func testGoogleUnwrapRedirect() {
        let engine = GoogleEngine()

        let unwrapped = engine.unwrapGoogleRedirect("/url?q=https://example.com/real&sa=U")
        XCTAssertEqual(unwrapped, "https://example.com/real")

        let direct = engine.unwrapGoogleRedirect("https://example.com/direct")
        XCTAssertEqual(direct, "https://example.com/direct")
    }

    // MARK: - Bing parsing

    func testBingParseAlgoBlock() {
        let html = """
        <li class="b_algo">
            <h2><a href="https://example.com/bing-result">Bing Result Title</a></h2>
            <div class="b_caption"><p>This is a Bing snippet.</p></div>
        </li>
        """
        let engine = BingEngine()
        let results = engine.parseBingResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Bing Result Title")
        XCTAssertEqual(results[0].url, "https://example.com/bing-result")
        XCTAssertTrue(results[0].snippet.contains("Bing snippet"))
    }

    func testBingParseLineclampSnippet() {
        let html = """
        <li class="b_algo">
            <h2><a href="https://example.com/bing2">Second Bing Result</a></h2>
            <p class="b_lineclamp2">Alternative snippet format.</p>
        </li>
        """
        let engine = BingEngine()
        let results = engine.parseBingResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].snippet.contains("Alternative snippet"))
    }

    // MARK: - Startpage parsing

    func testStartpageParseResultBlock() {
        let html = """
        <div class="w-gl__result">
            <a href="https://example.com/sp-result">
                <span class="w-gl__result-title">Startpage Result Title</span>
            </a>
            <p class="w-gl__description">This is a Startpage snippet.</p>
        </div>
        <div class="w-gl__result">
            <a href="https://example.com/sp-result2">
                <span class="w-gl__result-title">Second SP Result</span>
            </a>
            <p class="w-gl__description">Second description.</p>
        </div>
        """
        let engine = StartpageEngine()
        let results = engine.parseStartpageResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Startpage Result Title")
        XCTAssertEqual(results[0].url, "https://example.com/sp-result")
        XCTAssertTrue(results[0].snippet.contains("Startpage snippet"))
    }

    // MARK: - Brave parsing

    func testBraveParseSnippetBlock() {
        let html = """
        <div class="snippet" data-pos="0">
            <a class="result-header" href="https://example.com/brave-result">
                <span class="snippet-title">Brave Result Title</span>
            </a>
            <p class="snippet-description">This is a Brave snippet.</p>
        </div>
        """
        let engine = BraveEngine()
        let results = engine.parseBraveResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Brave Result Title")
        XCTAssertEqual(results[0].url, "https://example.com/brave-result")
        XCTAssertTrue(results[0].snippet.contains("Brave snippet"))
    }

    // MARK: - Engine type verification

    func testEngineTypesCorrect() {
        XCTAssertEqual(DuckDuckGoEngine().engineType, .duckDuckGo)
        XCTAssertEqual(BraveEngine().engineType, .brave)
        XCTAssertEqual(GoogleEngine().engineType, .google)
        XCTAssertEqual(BingEngine().engineType, .bing)
        XCTAssertEqual(StartpageEngine().engineType, .startpage)
    }
}
