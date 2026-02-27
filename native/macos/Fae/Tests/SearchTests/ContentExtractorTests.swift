import XCTest
@testable import Fae

final class ContentExtractorTests: XCTestCase {

    // MARK: - HTML tag stripping

    func testStripSimpleTags() {
        XCTAssertEqual(
            ContentExtractor.stripAllHTMLTags("<b>bold</b> and <i>italic</i>"),
            "bold and italic"
        )
    }

    func testStripTagsWithAttributes() {
        XCTAssertEqual(
            ContentExtractor.stripAllHTMLTags(#"<a href="http://example.com">link</a>"#),
            "link"
        )
    }

    func testStripNestedTags() {
        XCTAssertEqual(
            ContentExtractor.stripAllHTMLTags("<div><p><span>text</span></p></div>"),
            "text"
        )
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

    // MARK: - Title extraction

    func testExtractsTitle() {
        let html = "<html><head><title>Test Page Title</title></head><body><p>text</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(page.title, "Test Page Title")
    }

    func testMissingTitleFallsBackToURL() {
        let html = "<html><body><p>text</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com/page")
        XCTAssertEqual(page.title, "https://example.com/page")
    }

    // MARK: - Word count

    func testWordCount() {
        let html = "<html><body><p>one two three four five</p></body></html>"
        let page = ContentExtractor.extract(html: html, url: "https://example.com")
        XCTAssertEqual(page.wordCount, 5)
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
        // Should not have excessive whitespace
        XCTAssertFalse(page.text.contains("    "))
    }
}
