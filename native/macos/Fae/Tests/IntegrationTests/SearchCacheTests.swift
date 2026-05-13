import XCTest
@testable import Fae

final class SearchCacheTests: XCTestCase {

    // MARK: - SearchCache.makeKey

    func testMakeKeyNormalizesQuery() {
        let key1 = SearchCache.makeKey(query: "  Hello World  ", engines: [.bing])
        let key2 = SearchCache.makeKey(query: "hello world", engines: [.bing])
        XCTAssertEqual(key1.query, key2.query)
    }

    func testMakeKeySortsEngines() {
        let key1 = SearchCache.makeKey(query: "test", engines: [.bing, .google])
        let key2 = SearchCache.makeKey(query: "test", engines: [.google, .bing])
        XCTAssertEqual(key1.engineHash, key2.engineHash)
    }

    func testMakeKeyDifferentEngines() {
        let key1 = SearchCache.makeKey(query: "test", engines: [.bing])
        let key2 = SearchCache.makeKey(query: "test", engines: [.google])
        XCTAssertNotEqual(key1.engineHash, key2.engineHash)
    }

    // MARK: - SearchConfig

    func testSearchConfigDefault() {
        let config = SearchConfig.default
        XCTAssertFalse(config.engines.isEmpty)
        XCTAssertGreaterThan(config.maxResults, 0)
        try? config.validate()
    }

    // MARK: - SearchError

    func testSearchErrorHttp() {
        let error: Error = SearchError.http("Bad request")
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    func testSearchErrorParse() {
        let error: Error = SearchError.parse("Invalid HTML")
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    func testSearchErrorAllEnginesFailed() {
        let error: Error = SearchError.allEnginesFailed("No results")
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
}
