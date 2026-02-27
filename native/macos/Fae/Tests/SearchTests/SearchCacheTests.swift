import XCTest
@testable import Fae

final class SearchCacheTests: XCTestCase {

    private func key(_ query: String, engines: [SearchEngine] = [.duckDuckGo]) -> SearchCache.CacheKey {
        SearchCache.makeKey(query: query, engines: engines)
    }

    // MARK: - Basic get/insert

    func testInsertAndGet() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "Test", url: "https://test.com", snippet: "A snippet", engine: "DuckDuckGo")]
        await cache.insert(key: key("test"), results: results)
        let cached = await cache.get(key: key("test"), ttlSeconds: 600)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(cached?.first?.title, "Test")
    }

    func testMissReturnsNil() async {
        let cache = SearchCache()
        let cached = await cache.get(key: key("nonexistent"), ttlSeconds: 600)
        XCTAssertNil(cached)
    }

    // MARK: - TTL expiry

    func testExpiredEntryReturnsNil() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "Old", url: "https://old.com", snippet: "Old", engine: "Bing")]
        await cache.insert(key: key("old"), results: results)
        // Request with TTL of 0 — should be expired immediately.
        let cached = await cache.get(key: key("old"), ttlSeconds: 0)
        XCTAssertNil(cached, "Zero TTL should return nil for any entry")
    }

    // MARK: - Cache key generation

    func testMakeKeyDeterministic() {
        let key1 = SearchCache.makeKey(query: "test query", engines: [.duckDuckGo, .brave])
        let key2 = SearchCache.makeKey(query: "test query", engines: [.duckDuckGo, .brave])
        XCTAssertEqual(key1, key2)
    }

    func testMakeKeyDiffersForDifferentQueries() {
        let key1 = SearchCache.makeKey(query: "hello", engines: [.duckDuckGo])
        let key2 = SearchCache.makeKey(query: "world", engines: [.duckDuckGo])
        XCTAssertNotEqual(key1, key2)
    }

    func testMakeKeyDiffersForDifferentEngines() {
        let key1 = SearchCache.makeKey(query: "test", engines: [.duckDuckGo])
        let key2 = SearchCache.makeKey(query: "test", engines: [.brave])
        XCTAssertNotEqual(key1, key2)
    }

    func testMakeKeyCaseInsensitive() {
        let key1 = SearchCache.makeKey(query: "Test Query", engines: [.duckDuckGo])
        let key2 = SearchCache.makeKey(query: "test query", engines: [.duckDuckGo])
        XCTAssertEqual(key1, key2, "Keys should be case-insensitive")
    }

    func testMakeKeyOrderIndependent() {
        let key1 = SearchCache.makeKey(query: "test", engines: [.duckDuckGo, .brave])
        let key2 = SearchCache.makeKey(query: "test", engines: [.brave, .duckDuckGo])
        XCTAssertEqual(key1, key2, "Engine order should not affect key")
    }

    // MARK: - Clear

    func testClearRemovesAll() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "A", url: "https://a.com", snippet: "a", engine: "Google")]
        await cache.insert(key: key("k1"), results: results)
        await cache.insert(key: key("k2"), results: results)
        await cache.clear()
        let r1 = await cache.get(key: key("k1"), ttlSeconds: 600)
        let r2 = await cache.get(key: key("k2"), ttlSeconds: 600)
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    // MARK: - LRU eviction

    func testCountTracksEntries() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "A", url: "https://a.com", snippet: "a", engine: "Google")]
        await cache.insert(key: key("a"), results: results)
        await cache.insert(key: key("b"), results: results)
        let count = await cache.count
        XCTAssertEqual(count, 2)
    }
}
