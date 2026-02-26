import XCTest
@testable import Fae

final class MLXEmbeddingEngineTests: XCTestCase {

    func testEmbedNonEmptyTextProducesNonZeroVector() async throws {
        let engine = MLXEmbeddingEngine()
        try await engine.load(modelID: "foundation-hash-384")

        let vector = try await engine.embed(text: "hello world")

        XCTAssertEqual(vector.count, 384)
        XCTAssertTrue(vector.contains(where: { $0 != 0 }))
    }

    func testEmbedSameInputDeterministic() async throws {
        let engine = MLXEmbeddingEngine()
        try await engine.load(modelID: "foundation-hash-384")

        let a = try await engine.embed(text: "deterministic input")
        let b = try await engine.embed(text: "deterministic input")

        XCTAssertEqual(a.count, 384)
        XCTAssertEqual(b.count, 384)
        XCTAssertEqual(a, b)
    }

    func testEmbedDifferentInputsDiffer() async throws {
        let engine = MLXEmbeddingEngine()
        try await engine.load(modelID: "foundation-hash-384")

        let a = try await engine.embed(text: "alpha input")
        let b = try await engine.embed(text: "beta input")

        XCTAssertEqual(a.count, 384)
        XCTAssertEqual(b.count, 384)
        XCTAssertNotEqual(a, b)
    }
}
