import XCTest
@testable import Fae

final class SearchCacheTests: XCTestCase {

    // MARK: - Basic get/insert

    func testInsertAndGet() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "Test", url: "https://test.com", snippet: "A snippet", engine: "duckDuckGo")]
        await cache.insert(key: "test-key", results: results)
        let cached = await cache.get(key: "test-key", ttlSeconds: 600)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(cached?.first?.title, "Test")
    }

    func testMissReturnsNil() async {
        let cache = SearchCache()
        let cached = await cache.get(key: "nonexistent", ttlSeconds: 600)
        XCTAssertNil(cached)
    }

    // MARK: - TTL expiry

    func testExpiredEntryReturnsNil() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "Old", url: "https://old.com", snippet: "Old", engine: "bing")]
        await cache.insert(key: "old-key", results: results)
        // Request with TTL of 0 — should be expired immediately.
        let cached = await cache.get(key: "old-key", ttlSeconds: 0)
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

    // MARK: - Clear

    func testClearRemovesAll() async {
        let cache = SearchCache()
        let results = [SearchResult(title: "A", url: "https://a.com", snippet: "a", engine: "google")]
        await cache.insert(key: "k1", results: results)
        await cache.insert(key: "k2", results: results)
        await cache.clear()
        XCTAssertNil(await cache.get(key: "k1", ttlSeconds: 600))
        XCTAssertNil(await cache.get(key: "k2", ttlSeconds: 600))
    }
}
