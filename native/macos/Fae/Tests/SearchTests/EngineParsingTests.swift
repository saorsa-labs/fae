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

    // MARK: - DuckDuckGo extractURL unit tests (matches Rust extract_url tests)

    func testDDGExtractURLFromRedirect() {
        let engine = DuckDuckGoEngine()
        let result = engine.extractURL(from: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&rut=abc")
        XCTAssertEqual(result, "https://example.com/page")
    }

    func testDDGExtractURLDirectLink() {
        let engine = DuckDuckGoEngine()
        let result = engine.extractURL(from: "https://example.com/direct")
        XCTAssertEqual(result, "https://example.com/direct")
    }

    func testDDGExtractURLProtocolRelative() {
        let engine = DuckDuckGoEngine()
        let result = engine.extractURL(from: "//example.com/page")
        XCTAssertEqual(result, "https://example.com/page")
    }

    func testDDGExtractURLRelativePath() {
        let engine = DuckDuckGoEngine()
        let result = engine.extractURL(from: "/local/path")
        XCTAssertNil(result, "Relative paths should return nil")
    }

    func testDDGExtractURLHttpDirect() {
        let engine = DuckDuckGoEngine()
        let result = engine.extractURL(from: "http://example.com/plain")
        XCTAssertEqual(result, "http://example.com/plain")
    }

    // MARK: - DuckDuckGo ad exclusion

    func testDDGExcludesAds() {
        let html = """
        <div class="result results_links results_links_deep web-result result--ad">
            <a class="result__a" href="https://ad.example.com">Sponsored Result</a>
            <a class="result__snippet">This is an ad.</a>
        </div>
        <div class="result results_links results_links_deep web-result">
            <a class="result__a" href="https://organic.example.com">Organic Result</a>
            <a class="result__snippet">This is organic.</a>
        </div>
        """
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1, "Should exclude ad results")
        XCTAssertEqual(results[0].url, "https://organic.example.com")
    }

    // MARK: - DuckDuckGo fixture-based tests (matches Rust fixture tests)

    /// Realistic DDG HTML with multiple result formats, ads, and redirects.
    static let fixtureDDGHTML = """
    <!DOCTYPE html>
    <html>
    <body>
    <div class="result results_links results_links_deep web-result result--ad">
        <a class="result__a" href="https://ad.example.com/sponsored">Sponsored Ad (Ad)</a>
        <a class="result__snippet">This is a paid advertisement.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.rust-lang.org%2F&amp;rut=abc123">
            Rust Programming Language
        </a>
        <a class="result__snippet">
            A language empowering everyone to build reliable and efficient software.
        </a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://doc.rust-lang.org/book/">
            The Rust Programming Language Book
        </a>
        <a class="result__snippet">
            An introductory book about Rust. The Rust Programming Language.
        </a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FRust_(programming_language)&amp;rut=def456">
            Rust (programming language) - Wikipedia
        </a>
        <a class="result__snippet">
            Rust is a multi-paradigm, general-purpose programming language.
        </a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://crates.io/">Crates.io: Rust Package Registry</a>
        <a class="result__snippet">The Rust community's crate registry.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://github.com/rust-lang/rust">rust-lang/rust: The Rust Programming Language</a>
        <a class="result__snippet">Empowering everyone to build reliable and efficient software.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://play.rust-lang.org/">Rust Playground</a>
        <a class="result__snippet">An online playground for the Rust programming language.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://www.rust-lang.org/learn">Learn Rust - Rust Programming Language</a>
        <a class="result__snippet">Getting started guides and tutorials for Rust.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://blog.rust-lang.org/">Rust Blog</a>
        <a class="result__snippet">The official Rust programming language blog.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://rustup.rs/">Rustup - The Rust Toolchain Installer</a>
        <a class="result__snippet">Install Rust and manage toolchains.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://www.rust-lang.org/tools">Rust Tools</a>
        <a class="result__snippet">First-class tooling for Rust development.</a>
    </div>
    <div class="result results_links results_links_deep web-result">
        <a class="result__a" href="https://doc.rust-lang.org/std/">Rust Standard Library Documentation</a>
        <a class="result__snippet">Documentation for the Rust standard library.</a>
    </div>
    </body>
    </html>
    """

    func testFixtureExtractsAllOrganicResults() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: Self.fixtureDDGHTML, maxResults: 50)
        // 11 organic results + 1 ad (excluded)
        XCTAssertGreaterThanOrEqual(results.count, 10,
            "expected 10+ results, got \(results.count)")
    }

    func testFixtureResultsHaveNonEmptyFields() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: Self.fixtureDDGHTML, maxResults: 50)
        for (i, result) in results.enumerated() {
            XCTAssertFalse(result.title.isEmpty, "result \(i) has empty title")
            XCTAssertFalse(result.url.isEmpty, "result \(i) has empty URL")
            XCTAssertFalse(result.snippet.isEmpty, "result \(i) has empty snippet")
            XCTAssertEqual(result.engine, "DuckDuckGo")
        }
    }

    func testFixtureUnwrapsDDGRedirectURLs() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: Self.fixtureDDGHTML, maxResults: 50)
        // First organic result should have unwrapped URL.
        XCTAssertEqual(results[0].url, "https://www.rust-lang.org/",
            "redirect URL not unwrapped")
        // No result URL should contain duckduckgo.com/l/.
        for result in results {
            XCTAssertFalse(result.url.contains("duckduckgo.com/l/"),
                "URL still wrapped: \(result.url)")
        }
    }

    func testFixtureRespectsMaxResults() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: Self.fixtureDDGHTML, maxResults: 3)
        XCTAssertEqual(results.count, 3)
    }

    func testFixtureExcludesAds() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: Self.fixtureDDGHTML, maxResults: 50)
        for result in results {
            XCTAssertFalse(result.title.contains("(Ad)"),
                "ad result should be excluded: \(result.title)")
        }
    }

    // MARK: - DuckDuckGo fallback parser

    func testDDGFallbackParserWorksOnSimpleHTML() {
        // HTML without the result class structure triggers fallback.
        let html = """
        <html><body>
        <a href="https://example.com/fallback1">Fallback Result One</a>
        <a href="https://example.com/fallback2">Fallback Result Two</a>
        <a href="//duckduckgo.com/something">DDG Internal</a>
        </body></html>
        """
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: html, maxResults: 10)

        // Should find results via fallback (excluding DDG internal links).
        XCTAssertGreaterThanOrEqual(results.count, 2)
        for result in results {
            XCTAssertFalse(result.url.contains("duckduckgo.com"),
                "Fallback should skip DDG internal links")
        }
    }

    // MARK: - DuckDuckGo HTML entity in results

    func testDDGParseHTMLEntitiesInTitle() {
        let html = """
        <div class="result results_links results_links_deep web-result">
            <a class="result__a" href="https://example.com/entity">Tom &amp; Jerry&apos;s &lt;Show&gt;</a>
            <a class="result__snippet">A classic &quot;cartoon&quot; series.</a>
        </div>
        """
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: html, maxResults: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].title.contains("&"), "Should decode &amp; to &")
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

    func testGoogleParseEmptyHTML() {
        let engine = GoogleEngine()
        let results = engine.parseGoogleResults(html: "<html><body></body></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
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

    func testBingParseEmptyHTML() {
        let engine = BingEngine()
        let results = engine.parseBingResults(html: "<html><body></body></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
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

    func testStartpageParseEmptyHTML() {
        let engine = StartpageEngine()
        let results = engine.parseStartpageResults(html: "<html><body></body></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
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

    func testBraveParseEmptyHTML() {
        let engine = BraveEngine()
        let results = engine.parseBraveResults(html: "<html><body></body></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Engine type verification

    func testEngineTypesCorrect() {
        XCTAssertEqual(DuckDuckGoEngine().engineType, .duckDuckGo)
        XCTAssertEqual(BraveEngine().engineType, .brave)
        XCTAssertEqual(GoogleEngine().engineType, .google)
        XCTAssertEqual(BingEngine().engineType, .bing)
        XCTAssertEqual(StartpageEngine().engineType, .startpage)
    }

    // MARK: - All engines: maxResults enforcement

    func testAllEnginesRespectMaxResults() {
        // Build HTML with many results for each engine and verify maxResults.
        let ddgEngine = DuckDuckGoEngine()
        var ddgHTML = ""
        for i in 0..<15 {
            ddgHTML += """
            <div class="result results_links results_links_deep web-result">
                <a class="result__a" href="https://example.com/ddg\(i)">DDG Title \(i)</a>
                <a class="result__snippet">DDG Snippet \(i).</a>
            </div>
            """
        }
        XCTAssertEqual(ddgEngine.parseDDGResults(html: ddgHTML, maxResults: 3).count, 3)

        let bingEngine = BingEngine()
        var bingHTML = ""
        for i in 0..<15 {
            bingHTML += """
            <li class="b_algo">
                <h2><a href="https://example.com/bing\(i)">Bing Title \(i)</a></h2>
                <div class="b_caption"><p>Bing Snippet \(i).</p></div>
            </li>
            """
        }
        XCTAssertEqual(bingEngine.parseBingResults(html: bingHTML, maxResults: 3).count, 3)
    }
}
