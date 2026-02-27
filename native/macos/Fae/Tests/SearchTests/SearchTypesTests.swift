import XCTest
@testable import Fae

final class SearchTypesTests: XCTestCase {

    // MARK: - SearchEngine

    func testEngineWeights() {
        XCTAssertEqual(SearchEngine.google.weight, 1.2)
        XCTAssertEqual(SearchEngine.duckDuckGo.weight, 1.0)
        XCTAssertEqual(SearchEngine.brave.weight, 1.0)
        XCTAssertEqual(SearchEngine.startpage.weight, 0.9)
        XCTAssertEqual(SearchEngine.bing.weight, 0.8)
    }

    func testEngineRawValues() {
        XCTAssertEqual(SearchEngine.duckDuckGo.rawValue, "DuckDuckGo")
        XCTAssertEqual(SearchEngine.brave.rawValue, "Brave")
        XCTAssertEqual(SearchEngine.google.rawValue, "Google")
        XCTAssertEqual(SearchEngine.bing.rawValue, "Bing")
        XCTAssertEqual(SearchEngine.startpage.rawValue, "Startpage")
    }

    // MARK: - SearchConfig

    func testDefaultConfig() {
        let config = SearchConfig.default
        XCTAssertEqual(config.maxResults, 10)
        XCTAssertEqual(config.timeoutSeconds, 8)
        XCTAssertTrue(config.safeSearch)
        XCTAssertEqual(config.cacheTTLSeconds, 600)
        XCTAssertTrue(config.engines.contains(.duckDuckGo))
        XCTAssertTrue(config.engines.contains(.brave))
        XCTAssertTrue(config.engines.contains(.google))
        XCTAssertTrue(config.engines.contains(.bing))
    }

    func testConfigValidation() {
        var config = SearchConfig.default
        XCTAssertNoThrow(try config.validate())

        config.maxResults = 0
        XCTAssertThrowsError(try config.validate())

        config.maxResults = 10
        config.engines = []
        XCTAssertThrowsError(try config.validate())
    }

    // MARK: - SearchResult

    func testSearchResultCreation() {
        let result = SearchResult(
            title: "Test Title",
            url: "https://test.com",
            snippet: "A test snippet",
            engine: "DuckDuckGo"
        )
        XCTAssertEqual(result.title, "Test Title")
        XCTAssertEqual(result.url, "https://test.com")
        XCTAssertEqual(result.snippet, "A test snippet")
        XCTAssertEqual(result.engine, "DuckDuckGo")
        XCTAssertEqual(result.score, 0.0) // Default score
    }

    // MARK: - PageContent

    func testPageContentCreation() {
        let page = PageContent(
            url: "https://example.com",
            title: "Example",
            text: "Hello world",
            wordCount: 2
        )
        XCTAssertEqual(page.url, "https://example.com")
        XCTAssertEqual(page.title, "Example")
        XCTAssertEqual(page.text, "Hello world")
        XCTAssertEqual(page.wordCount, 2)
    }
}
