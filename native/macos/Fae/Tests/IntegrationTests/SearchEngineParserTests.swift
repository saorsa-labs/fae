import XCTest
@testable import Fae

/// Coverage for two 0%-covered search-engine parsers (BraveEngine + StartpageEngine).
/// parseBraveResults / parseStartpageResults are PURE HTML parsers (no network) —
/// ideal for fixture-based testing. extractByClass/extractFirstHref also exercised.
final class SearchEngineParserTests: XCTestCase {

    // MARK: - BraveEngine.parseBraveResults

    func testParseBraveResultsExtractsOneResult() {
        let html = """
        <div class="snippet" data-pos="1">
          <div class="snippet-title"><a href="https://example.com/page">Example Page</a></div>
          <div class="snippet-description">A useful example page about things.</div>
        </div>
        <div class="fdb">footer</div>
        """
        let results = BraveEngine().parseBraveResults(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://example.com/page")
        XCTAssertEqual(results.first?.engine, "Brave")
        XCTAssertTrue(results.first?.title.contains("Example") ?? false)
    }

    func testParseBraveResultsRespectsMaxResults() {
        var blocks = ""
        for i in 1...5 {
            blocks += """
            <div class="snippet" data-pos="\(i)">
              <div class="snippet-title"><a href="https://example.com/\(i)">Title \(i)</a></div>
              <div class="snippet-description">Desc \(i)</div>
            </div>
            """
        }
        blocks += "<div class=\"fdb\">footer</div>"
        let results = BraveEngine().parseBraveResults(html: blocks, maxResults: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testParseBraveResultsSkipsStandaloneSnippets() {
        let html = """
        <div class="snippet standalone" data-pos="1">
          <div class="snippet-title"><a href="https://example.com/x">Standalone</a></div>
        </div>
        <div class="fdb">footer</div>
        """
        let results = BraveEngine().parseBraveResults(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 0)
    }

    func testParseBraveResultsSkipsNonHttpHref() {
        let html = """
        <div class="snippet" data-pos="1">
          <div class="snippet-title"><a href="/relative/path">Relative</a></div>
        </div>
        <div class="fdb">footer</div>
        """
        let results = BraveEngine().parseBraveResults(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 0)
    }

    func testParseBraveResultsEmptyHtml() {
        XCTAssertTrue(BraveEngine().parseBraveResults(html: "", maxResults: 5).isEmpty)
    }

    // MARK: - StartpageEngine.parseStartpageResults

    func testParseStartpageResultsExtractsOneResult() {
        let html = """
        <div class="w-gl__result">
          <a class="w-gl__result-title" href="https://example.org/start">Startpage Result</a>
          <div class="w-gl__description">A description here.</div>
        </div>
        """
        let results = StartpageEngine().parseStartpageResults(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://example.org/start")
        XCTAssertEqual(results.first?.engine, "Startpage")
    }

    func testParseStartpageResultsRespectsMaxResults() {
        var blocks = ""
        for i in 1...4 {
            blocks += """
            <div class="w-gl__result">
              <a class="w-gl__result-title" href="https://example.org/\(i)">R\(i)</a>
            </div>
            """
        }
        let results = StartpageEngine().parseStartpageResults(html: blocks, maxResults: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testParseStartpageResultsSkipsMissingTitle() {
        let html = """
        <div class="w-gl__result">
          <a href="https://example.org/no-title">No title class</a>
        </div>
        """
        let results = StartpageEngine().parseStartpageResults(html: html, maxResults: 5)
        XCTAssertEqual(results.count, 0)
    }

    func testParseStartpageResultsEmptyHtml() {
        XCTAssertTrue(StartpageEngine().parseStartpageResults(html: "", maxResults: 5).isEmpty)
    }
}
