import Foundation
import MLX
import Testing

@testable import MLXLMCommon

// MARK: - Helper

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("safetensors")
}

/// Assert two arrays of MLXArray are element-wise close
private func assertArraysClose(_ lhs: [MLXArray], _ rhs: [MLXArray], label: String = "") {
    #expect(lhs.count == rhs.count, "state count mismatch \(label)")
    for (i, (a, b)) in zip(lhs, rhs).enumerated() {
        #expect(a.shape == b.shape, "shape mismatch at index \(i) \(label)")
        let close = allClose(a, b).item(Bool.self)
        #expect(close, "values not close at index \(i) \(label)")
    }
}

// MARK: - Original parameterized test (updated with value assertions)

@Test(
    .serialized,
    arguments: [
        ({ KVCacheSimple() }),
        ({ RotatingKVCache(maxSize: 32) }),
        ({ QuantizedKVCache() }),
        ({ ChunkedKVCache(chunkSize: 16) }),
        ({ ArraysCache(size: 2) }),
        ({ MambaCache() }),
    ])
func testCacheSerialization(creator: (() -> any KVCache)) async throws {
    let cache = (0 ..< 10).map { _ in creator() }
    let keys = MLXArray.ones([1, 8, 32, 64], dtype: .bfloat16)
    let values = MLXArray.ones([1, 8, 32, 64], dtype: .bfloat16)
    for item in cache {
        switch item {
        case let arrays as ArraysCache:
            arrays[0] = keys
            arrays[1] = values
        case let quantized as QuantizedKVCache:
            _ = quantized.updateQuantized(keys: keys, values: values)
        default:
            _ = item.update(keys: keys, values: values)
        }
    }

    let url = tempURL()

    try savePromptCache(url: url, cache: cache, metadata: [:])
    let (loadedCache, _) = try loadPromptCache(url: url)

    #expect(cache.count == loadedCache.count)
    for (lhs, rhs) in zip(cache, loadedCache) {
        #expect(type(of: lhs) == type(of: rhs))
        #expect(lhs.metaState == rhs.metaState)
        assertArraysClose(lhs.state, rhs.state)
    }
}

// MARK: - ArraysCache sparse slot round-trip

@Test func testArraysCacheSparseSlots() throws {
    let cache = ArraysCache(size: 3)
    let a = MLXArray.ones([2, 4], dtype: .float32) * 3.0
    let b = MLXArray.ones([2, 4], dtype: .float32) * 7.0
    cache[0] = a
    // slot 1 stays nil
    cache[2] = b

    let url = tempURL()
    try savePromptCache(url: url, cache: [cache], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)

    #expect(loaded.count == 1)
    let restored = try #require(loaded[0] as? ArraysCache)
    #expect(restored.slotCount == 3)
    #expect(restored[0] != nil)
    #expect(restored[1] == nil)
    #expect(restored[2] != nil)
    #expect(allClose(restored[0]!, a).item(Bool.self))
    #expect(allClose(restored[2]!, b).item(Bool.self))
}

// MARK: - ArraysCache leftPadding round-trip

@Test func testArraysCacheLeftPadding() throws {
    let cache = ArraysCache(size: 2, leftPadding: [0, 5])
    let a = MLXArray.ones([2, 4], dtype: .float32)
    let b = MLXArray.ones([2, 4], dtype: .float32) * 2.0
    cache[0] = a
    cache[1] = b

    let url = tempURL()
    try savePromptCache(url: url, cache: [cache], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)

    let restored = try #require(loaded[0] as? ArraysCache)
    #expect(restored.leftPaddingValues == [0, 5])
    assertArraysClose(restored.state, cache.state)
}

// MARK: - MambaCache type preservation

@Test func testMambaCacheRoundTrip() throws {
    let cache = MambaCache()
    let a = MLXArray.ones([2, 4], dtype: .float32) * 5.0
    let b = MLXArray.ones([2, 4], dtype: .float32) * 9.0
    cache[0] = a
    cache[1] = b

    let url = tempURL()
    try savePromptCache(url: url, cache: [cache], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)

    #expect(loaded.count == 1)
    let restored = try #require(loaded[0] as? MambaCache)
    #expect(restored.slotCount == 2)
    assertArraysClose(restored.state, cache.state)
}

// MARK: - CacheList with KV caches

@Test func testCacheListKVCaches() throws {
    let simple = KVCacheSimple()
    let rotating = RotatingKVCache(maxSize: 32)

    let keys = MLXArray.ones([1, 8, 16, 64], dtype: .bfloat16)
    let values = MLXArray.ones([1, 8, 16, 64], dtype: .bfloat16)
    _ = simple.update(keys: keys, values: values)
    _ = rotating.update(keys: keys * 2.0, values: values * 2.0)

    let cacheList = CacheList(simple, rotating)

    let url = tempURL()
    try savePromptCache(url: url, cache: [cacheList], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)

    #expect(loaded.count == 1)
    let restored = try #require(loaded[0] as? CacheList)
    let child0 = try #require(restored[0] as? KVCacheSimple)
    let child1 = try #require(restored[1] as? RotatingKVCache)

    assertArraysClose(child0.state, simple.state, label: "child0")
    assertArraysClose(child1.state, rotating.state, label: "child1")
    #expect(child1.metaState == rotating.metaState)
}

// MARK: - CacheList with hybrid (MambaCache + KVCacheSimple)

@Test func testCacheListHybrid() throws {
    let mamba = MambaCache()
    mamba[0] = MLXArray.ones([2, 4], dtype: .float32) * 3.0
    mamba[1] = MLXArray.ones([2, 4], dtype: .float32) * 4.0

    let simple = KVCacheSimple()
    let keys = MLXArray.ones([1, 8, 16, 64], dtype: .bfloat16)
    let values = MLXArray.ones([1, 8, 16, 64], dtype: .bfloat16)
    _ = simple.update(keys: keys, values: values)

    let cacheList = CacheList(mamba, simple)

    let url = tempURL()
    try savePromptCache(url: url, cache: [cacheList], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)

    #expect(loaded.count == 1)
    let restored = try #require(loaded[0] as? CacheList)
    let restoredMamba = try #require(restored[0] as? MambaCache)
    let restoredSimple = try #require(restored[1] as? KVCacheSimple)

    assertArraysClose(restoredMamba.state, mamba.state, label: "mamba")
    assertArraysClose(restoredSimple.state, simple.state, label: "simple")
}

// MARK: - Simple cache round-trip with value assertions

@Test func testSimpleCacheRoundTrip() throws {
    let cache = KVCacheSimple()
    let keys = MLXArray.ones([1, 8, 16, 64], dtype: .bfloat16)
    let values = MLXArray.ones([1, 8, 16, 64], dtype: .bfloat16)
    _ = cache.update(keys: keys, values: values)

    let url = tempURL()
    try savePromptCache(url: url, cache: [cache], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)
    #expect(loaded.count == 1)
    assertArraysClose(loaded[0].state, cache.state)
}

// MARK: - ArraysCache fully populated round-trip

@Test func testArraysCacheFullyPopulated() throws {
    let cache = ArraysCache(size: 2)
    cache[0] = MLXArray.ones([2, 4], dtype: .float32)
    cache[1] = MLXArray.ones([2, 4], dtype: .float32) * 2.0

    let url = tempURL()
    try savePromptCache(url: url, cache: [cache], metadata: [:])
    let (loaded, _) = try loadPromptCache(url: url)

    #expect(loaded.count == 1)
    let restored = try #require(loaded[0] as? ArraysCache)
    #expect(restored.slotCount == 2)
    assertArraysClose(restored.state, cache.state)
}
