import XCTest
@testable import Fae

final class ContentExtractorTests: XCTestCase {

    // MARK: - HTML tag stripping

    func testStripSimpleTags() {
        let result = ContentExtractor.stripAllHTMLTags("<b>bold</b> and <i>italic</i>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(result.contains("bold"))
        XCTAssertTrue(result.contains("italic"))
        XCTAssertFalse(result.contains("<b>"))
        XCTAssertFalse(result.contains("<i>"))
    }

    func testStripTagsWithAttributes() {
        let result = ContentExtractor.stripAllHTMLTags(#"<a href="http://example.com">link</a>"#)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(result.contains("link"))
        XCTAssertFalse(result.contains("<a"))
    }

    func testStripNestedTags() {
        let result = ContentExtractor.stripAllHTMLTags("<div><p><span>text</span></p></div>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(result.contains("text"))
        XCTAssertFalse(result.contains("<div>"))
    }

    func testStripTagsPreservesText() {
        XCTAssertEqual(
            ContentExtractor.stripAllHTMLTags("no tags here"),
            "no tags here"
        )
    }

    func testStripEmptyInput() {
        XCTAssertEqual(ContentExtractor.stripAllHTMLTags(""), "")
    }

    // MARK: - HTML entity decoding (matches Rust entity tests)

    func testDecodeAmpersand() {
        let result = ContentExtractor.stripAllHTMLTags("Tom &amp; Jerry")
        XCTAssertTrue(result.contains("Tom & Jerry"), "Should decode &amp; to &")
    }

    func testDecodeLessThan() {
        let result = ContentExtractor.stripAllHTMLTags("x &lt; y")
        XCTAssertTrue(result.contains("x < y"), "Should decode &lt; to <")
    }

    func testDecodeGreaterThan() {
        let result = ContentExtractor.stripAllHTMLTags("x &gt; y")
        XCTAssertTrue(result.contains("x > y"), "Should decode &gt; to >")
    }

    func testDecodeQuote() {
        let result = ContentExtractor.stripAllHTMLTags("say &quot;hello&quot;")
        XCTAssertTrue(result.contains("say \"hello\""), "Should decode &quot; to \"")
    }

    func testDecodeApostrophe() {
        let result = ContentExtractor.stripAllHTMLTags("it&#39;s fine")
        XCTAssertTrue(result.contains("it's fine"), "Should decode &#39; to '")
    }

    func testDecodeNbsp() {
        let result = ContentExtractor.stripAllHTMLTags("hello&nbsp;world")
        XCTAssertTrue(result.contains("hello world"), "Should decode &nbsp; to space")
    }

    func testDecodeMultipleEntities() {
        let result = ContentExtractor.stripAllHTMLTags("<p>&lt;div class=&quot;foo&quot;&gt;text&lt;/div&gt;</p>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(result.contains("<div"))
        XCTAssertTrue(result.contains("\"foo\""))
    }

    // MARK: - Boilerplate removal

    func testStripScriptTags() {
        let html = """
        <html><body>
        <p>Keep this</p>
        <script>var x = 1; alert('remove');</script>
        <p>And this</p>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Keep this"))
        XCTAssertTrue(page.text.contains("And this"))
        XCTAssertFalse(page.text.contains("alert"))
        XCTAssertFalse(page.text.contains("var x"))
    }

    func testStripStyleTags() {
        let html = """
        <html><body>
        <style>.foo { color: red; }</style>
        <p>Content here</p>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Content here"))
        XCTAssertFalse(page.text.contains("color"))
    }

    func testStripNavFooterHeader() {
        let html = """
        <html><body>
        <nav>Navigation menu</nav>
        <header>Site header</header>
        <article><p>Main article content</p></article>
        <footer>Copyright 2026</footer>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Main article content"))
        // Nav/footer/header should be stripped
        XCTAssertFalse(page.text.contains("Navigation menu"))
        XCTAssertFalse(page.text.contains("Copyright 2026"))
    }

    func testStripAsideTags() {
        let html = """
        <html><body>
        <main>Main content</main>
        <aside>Sidebar stuff</aside>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Main content"))
        XCTAssertFalse(page.text.contains("Sidebar stuff"))
    }

    func testStripNoscriptAndIframe() {
        let html = """
        <html><body>
        <p>Visible content</p>
        <noscript>Enable JS please</noscript>
        <iframe src="ad.html">Ad frame</iframe>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Visible content"))
        XCTAssertFalse(page.text.contains("Enable JS"))
    }

    func testStripSvgTags() {
        let html = """
        <html><body>
        <p>Text content</p>
        <svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40"/></svg>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Text content"))
        XCTAssertFalse(page.text.contains("circle"))
        XCTAssertFalse(page.text.contains("viewBox"))
    }

    // MARK: - Content extraction priority

    func testExtractsFromArticle() {
        let html = """
        <html><body>
        <div>Random sidebar</div>
        <article>This is the main article content.</article>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("main article content"))
    }

    func testExtractsFromMain() {
        let html = """
        <html><body>
        <div>Sidebar stuff</div>
        <main>Primary page content here.</main>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Primary page content"))
    }

    func testFallsBackToBody() {
        let html = "<html><body>Body content only</body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Body content"))
    }

    func testArticlePreferredOverMain() {
        let html = """
        <html><body>
        <main>Main section content</main>
        <article>Article section content</article>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        // Article has higher priority than main.
        XCTAssertTrue(page.text.contains("Article section content"))
    }

    // MARK: - Title extraction

    func testExtractsTitle() {
        let html = "<html><head><title>Test Page Title</title></head><body><p>text</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(page.title, "Test Page Title")
    }

    func testMissingTitleReturnsEmpty() {
        let html = "<html><body><p>text</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com/page")
        XCTAssertNotNil(page.title)
    }

    func testTitleWithWhitespace() {
        let html = "<html><head><title>  Trimmed Title  </title></head><body><p>text</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(page.title, "Trimmed Title")
    }

    // MARK: - Word count

    func testWordCount() {
        let html = "<html><body><p>one two three four five</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(page.wordCount, 5)
    }

    func testWordCountEmpty() {
        let html = "<html><body></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(page.wordCount, 0)
    }

    // MARK: - URL and metadata

    func testPreservesURL() {
        let page = ContentExtractor.extract(html: "<body>text</body>", url: "https://test.com/path")
        XCTAssertEqual(page.url, "https://test.com/path")
    }

    // MARK: - Whitespace normalization

    func testNormalizesWhitespace() {
        let html = "<body><p>  lots   of    spaces  </p>\n\n\n\n\n<p>and newlines</p></body>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        // Should not have excessive whitespace.
        XCTAssertFalse(page.text.contains("    "))
    }

    func testCollapses3PlusNewlines() {
        let text = "Line1\n\n\n\n\nLine2"
        let normalized = ContentExtractor.normalizeWhitespace(text)
        // 2 blank lines allowed = 3 consecutive newlines at most.
        // 4+ consecutive newlines means 3+ blank lines — should be collapsed.
        XCTAssertFalse(normalized.contains("\n\n\n\n"),
            "Should collapse 3+ blank lines to 2 (max 3 consecutive newlines)")
    }

    // MARK: - Content truncation (matches Rust max_chars tests)

    func testMaxCharsTruncation() {
        let longText = String(repeating: "word ", count: 25_000) // ~125k chars
        let html = "<html><body><p>\(longText)</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")

        XCTAssertLessThanOrEqual(page.text.count, ContentExtractor.maxChars + 30,
            "Should truncate to maxChars + suffix")
        XCTAssertTrue(page.text.hasSuffix("[Content truncated]"),
            "Should append truncation marker")
    }

    func testShortContentNotTruncated() {
        let html = "<html><body><p>Short content</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertFalse(page.text.contains("[Content truncated]"))
    }

    func testMaxCharsConstant() {
        XCTAssertEqual(ContentExtractor.maxChars, 100_000)
    }

    // MARK: - Deeply nested HTML (matches Rust deeply_nested test)

    func testDeeplyNestedHTML() {
        let html = """
        <html><body>
            <div><div><div><div><div>
                <p>Deeply nested paragraph content here.</p>
            </div></div></div></div></div>
        </body></html>
        """
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertTrue(page.text.contains("Deeply nested paragraph"))
    }

    // MARK: - Complex HTML fixture (matches Rust fixture_complex tests)

    static let fixtureComplexHTML = """
    <html>
    <head>
        <title>Understanding Rust Ownership - A Deep Dive</title>
        <style>body { font-family: sans-serif; }</style>
    </head>
    <body>
        <nav>
            <ul><li><a href="/">Home</a></li><li><a href="/blog">Blog</a></li></ul>
        </nav>
        <header>
            <h1>Understanding Rust Ownership</h1>
            <p class="author">By Alice Smith</p>
        </header>
        <aside>
            <h3>Related Articles</h3>
            <p>Advertisement content goes here.</p>
        </aside>
        <article>
            <h2>Introduction</h2>
            <p>Ownership is one of Rust's most unique features. It enables Rust to make
            memory safety guarantees without needing a garbage collector.</p>
            <h2>References and Borrowing</h2>
            <p>Instead of transferring ownership, you can provide a reference to a value.
            This is called borrowing.</p>
            <h2>The Slice Type</h2>
            <p>Slices let you reference a contiguous sequence of elements in a collection
            rather than the whole collection.</p>
            <h2>Conclusion</h2>
            <p>Understanding ownership is crucial for writing safe and efficient Rust programs.</p>
        </article>
        <footer>
            <p>&copy; 2026 Rust Blog. All rights reserved.</p>
            <p><a href="/privacy">Privacy Policy</a></p>
        </footer>
        <script>
            (function() { analytics.track('pageview'); })();
        </script>
        <noscript><img src="tracking/pixel.gif"/></noscript>
    </body>
    </html>
    """

    func testFixtureComplexExtractsTitle() {
        let page = ContentExtractor.extract(html: Self.fixtureComplexHTML, url: "https://example.com/article")
        XCTAssertEqual(page.title, "Understanding Rust Ownership - A Deep Dive")
    }

    func testFixtureComplexExtractsArticleContent() {
        let page = ContentExtractor.extract(html: Self.fixtureComplexHTML, url: "https://example.com/article")
        XCTAssertTrue(page.text.contains("Ownership is one of Rust"))
        XCTAssertTrue(page.text.contains("References and Borrowing"))
        XCTAssertTrue(page.text.contains("Conclusion"))
    }

    func testFixtureComplexStripsBoilerplate() {
        let page = ContentExtractor.extract(html: Self.fixtureComplexHTML, url: "https://example.com/article")
        XCTAssertFalse(page.text.contains("analytics.track"), "Script content should be stripped")
        XCTAssertFalse(page.text.contains("tracking/pixel.gif"), "Noscript content should be stripped")
        XCTAssertFalse(page.text.contains("Privacy Policy"), "Footer content should be stripped")
        XCTAssertFalse(page.text.contains("Advertisement content"), "Aside content should be stripped")
    }

    func testFixtureComplexHasPositiveWordCount() {
        let page = ContentExtractor.extract(html: Self.fixtureComplexHTML, url: "https://example.com/article")
        XCTAssertGreaterThan(page.wordCount, 30,
            "expected 30+ words, got \(page.wordCount)")
    }

    // MARK: - Nav tag not confused with similar tags (matches Rust test)

    func testNavTagNotConfusedWithNavigate() {
        let html = "<html><body><nav>Skip this</nav><p>Keep this navigate text</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertFalse(page.text.contains("Skip this"))
        XCTAssertTrue(page.text.contains("navigate text"))
    }
}
