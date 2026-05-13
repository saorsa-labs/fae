import XCTest
@testable import Fae

final class SearchEngineTests: XCTestCase {

    // MARK: - ContentExtractor

    func testContentExtractorStripHTMLTags() {
        let html = "<p>Hello <b>world</b></p>"
        let text = ContentExtractor.stripAllHTMLTags(html)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertFalse(text.contains("<"))
    }

    func testContentExtractorStripTag() {
        let html = "<body><script>alert('xss')</script><p>Safe</p></body>"
        let cleaned = ContentExtractor.stripTag(from: html, tag: "script")
        XCTAssertFalse(cleaned.contains("alert"))
        XCTAssertTrue(cleaned.contains("Safe"))
    }

    func testContentExtractorStripMultipleTags() {
        var html = "<div><style>.red{color:red}</style><p>Text</p><nav>Menu</nav></div>"
        html = ContentExtractor.stripTag(from: html, tag: "style")
        html = ContentExtractor.stripTag(from: html, tag: "nav")
        XCTAssertFalse(html.contains(".red"))
        XCTAssertFalse(html.contains("Menu"))
        XCTAssertTrue(html.contains("Text"))
    }

    func testContentExtractorExtractTagContent() {
        let html = "<html><head><title>My Page</title></head><body>Content</body></html>"
        let title = ContentExtractor.extractTagContent(from: html, tag: "title")
        XCTAssertEqual(title, "My Page")
    }

    func testContentExtractorExtractTagNotFound() {
        let html = "<p>No article here</p>"
        XCTAssertNil(ContentExtractor.extractTagContent(from: html, tag: "article"))
    }

    func testContentExtractorNormalizeWhitespace() {
        let text = "  Hello   world  \n\n\n\n\nNew paragraph  "
        let normalized = ContentExtractor.normalizeWhitespace(text)
        XCTAssertEqual(normalized, "Hello world\n\n\nNew paragraph")
    }

    func testContentExtractorNormalizeSingleLine() {
        let text = "  Multiple   spaces   here  "
        let normalized = ContentExtractor.normalizeWhitespace(text)
        XCTAssertEqual(normalized, "Multiple spaces here")
    }

    func testContentExtractorHTMLEntities() {
        let html = "<p>&lt;script&gt; &amp; &quot;quotes&quot; &#39;apostrophes&#39; &nbsp; space</p>"
        let text = ContentExtractor.stripAllHTMLTags(html)
        XCTAssertTrue(text.contains("<script>"))
        XCTAssertTrue(text.contains("&"))
        XCTAssertTrue(text.contains("\"quotes\""))
        XCTAssertTrue(text.contains("'apostrophes'"))
    }

    func testContentExtractorFullExtract() {
        let html = """
        <html><head><title>Test Page</title></head>
        <body><script>alert('xss')</script>
        <article><p>Main content here</p></article>
        <nav>Skip this</nav></body></html>
        """
        let result = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(result.title, "Test Page")
        XCTAssertTrue(result.text.contains("Main content"))
        XCTAssertFalse(result.text.contains("alert"))
        XCTAssertEqual(result.url, "https://example.com")
    }

    func testContentExtractorPriorityArticleOverMain() {
        let html = """
        <html><body>
        <main>Main section</main>
        <article>Article content</article>
        </body></html>
        """
        let result = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(result.text.contains("Article content"))
    }

    func testContentExtractorFallbackToBody() {
        let html = "<html><body><p>Just body content</p></body></html>"
        let result = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(result.text.contains("Just body content"))
    }

    func testContentExtractorFallbackToFullHTML() {
        let html = "<p>No body tag</p>"
        let result = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(result.text.contains("No body tag"))
    }

    func testContentExtractorWordCount() {
        let html = "<html><body><article><p>Hello world foo bar baz</p></article></body></html>"
        let result = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(result.wordCount, 5)
    }

    // MARK: - BingEngine — parseBingResults

    func testBingParseResults() {
        let engine = BingEngine()
        let html = """
        <html>
        <li class="b_algo">
            <h2><a href="https://example.com/page1">Example Title</a></h2>
            <div class="b_caption"><p>This is a snippet of the page.</p></div>
        </li>
        </html>
        """
        let results = engine.parseBingResults(html: html, maxResults: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Example Title")
        XCTAssertEqual(results[0].url, "https://example.com/page1")
        XCTAssertTrue(results[0].snippet.contains("snippet"))
    }

    func testBingParseMultipleResults() {
        let engine = BingEngine()
        let html = """
        <li class="b_algo">
            <h2><a href="https://example.com/1">Title 1</a></h2>
            <div class="b_caption"><p>Snippet 1.</p></div>
        </li>
        <li class="b_algo">
            <h2><a href="https://example.com/2">Title 2</a></h2>
            <div class="b_caption"><p>Snippet 2.</p></div>
        </li>
        """
        let results = engine.parseBingResults(html: html, maxResults: 10)
        XCTAssertEqual(results.count, 2)
    }

    func testBingParseMaxResults() {
        let engine = BingEngine()
        var html = ""
        for i in 0..<5 {
            html += """
            <li class="b_algo">
                <h2><a href="https://example.com/\(i)">Title \(i)</a></h2>
                <div class="b_caption"><p>Snippet \(i).</p></div>
            </li>
            """
        }
        let results = engine.parseBingResults(html: html, maxResults: 2)
        XCTAssertLessThanOrEqual(results.count, 2)
    }

    func testBingParseEmptyHTML() {
        let engine = BingEngine()
        let results = engine.parseBingResults(html: "<html></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testBingParseSkipsNonHTTPURLs() {
        let engine = BingEngine()
        let html = """
        <li class="b_algo">
            <h2><a href="javascript:void(0)">Bad Link</a></h2>
            <div class="b_caption"><p>Snippet.</p></div>
        </li>
        """
        let results = engine.parseBingResults(html: html, maxResults: 10)
        XCTAssertTrue(results.isEmpty) // javascript: URLs are skipped
    }

    func testBingParseSkipsMissingTitle() {
        let engine = BingEngine()
        let html = """
        <li class="b_algo">
            <div class="b_caption"><p>No title here.</p></div>
        </li>
        """
        let results = engine.parseBingResults(html: html, maxResults: 10)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - SearchResult

    func testSearchResultInit() {
        let result = SearchResult(
            title: "Test",
            url: "https://example.com",
            snippet: "A snippet",
            engine: "bing"
        )
        XCTAssertEqual(result.title, "Test")
        XCTAssertEqual(result.url, "https://example.com")
        XCTAssertEqual(result.engine, "bing")
    }

    // MARK: - SearchEngine

    func testSearchEngineCases() {
        XCTAssertEqual(SearchEngine.bing.rawValue, "bing")
        XCTAssertEqual(SearchEngine.google.rawValue, "google")
        XCTAssertEqual(SearchEngine.duckDuckGo.rawValue, "duckduckgo")
    }

    // MARK: - GoogleEngine — parseGoogleResults

    func testGoogleParseResults() {
        let engine = GoogleEngine()
        let html = """
        <div class="g">
            <h3><a href="/url?q=https://example.com/page">Example Title</a></h3>
            <span class="VwiC3b">This is a snippet.</span>
        </div>
        """
        let results = engine.parseGoogleResults(html: html, maxResults: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Example Title")
        XCTAssertEqual(results[0].url, "https://example.com/page")
        XCTAssertTrue(results[0].snippet.contains("snippet"))
    }

    func testGoogleParseEmpty() {
        let engine = GoogleEngine()
        let results = engine.parseGoogleResults(html: "<html></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testGoogleUnwrapRedirect() {
        let engine = GoogleEngine()
        let url = engine.unwrapGoogleRedirect("/url?q=https://example.com&r=ab")
        XCTAssertEqual(url, "https://example.com")
    }

    func testGoogleUnwrapDirectURL() {
        let engine = GoogleEngine()
        let url = engine.unwrapGoogleRedirect("https://example.com/direct")
        XCTAssertEqual(url, "https://example.com/direct")
    }

    // MARK: - DuckDuckGoEngine — parseDDGResults

    func testDDGParseResults() {
        let engine = DuckDuckGoEngine()
        let html = """
        <div class="result results_links_deep">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com">Example Title</a>
            <a class="result__snippet">This is a snippet.</a>
        </div>
        """
        let results = engine.parseDDGResults(html: html, maxResults: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Example Title")
        XCTAssertEqual(results[0].url, "https://example.com")
    }

    func testDDGParseEmpty() {
        let engine = DuckDuckGoEngine()
        let results = engine.parseDDGResults(html: "<html></html>", maxResults: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testDDGExtractURLRedirect() {
        let engine = DuckDuckGoEngine()
        let url = engine.extractURL(from: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com")
        XCTAssertEqual(url, "https://example.com")
    }

    func testDDGExtractURLDirect() {
        let engine = DuckDuckGoEngine()
        let url = engine.extractURL(from: "https://example.com/direct")
        XCTAssertEqual(url, "https://example.com/direct")
    }

    func testDDGExtractURLProtocolRelative() {
        let engine = DuckDuckGoEngine()
        let url = engine.extractURL(from: "//example.com/path")
        XCTAssertEqual(url, "https://example.com/path")
    }

    func testDDGExtractURLOtherwise() {
        let engine = DuckDuckGoEngine()
        XCTAssertNil(engine.extractURL(from: "relative/path"))
    }
}
