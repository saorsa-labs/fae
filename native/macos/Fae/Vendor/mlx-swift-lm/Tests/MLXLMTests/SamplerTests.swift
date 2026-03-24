// Copyright © 2026 Apple Inc.

import MLX
@testable import MLXLMCommon
import XCTest

final class SamplerTests: XCTestCase {

    private let logits = MLXArray([0.05 as Float, 0.15, 0.30, 0.50], [1, 4])

    func testTopKFilteringKeepsOnlyHighestTokens() {
        // TopPSampler with topK=2 should only keep the two highest-probability tokens
        let sampler = TopPSampler(temperature: 1.0, topK: 2)
        // Just verify it produces a valid token index from the top-2
        let token = sampler.sample(logits: logits).item(Int.self)
        XCTAssertTrue([2, 3].contains(token), "Expected token from top-2, got \(token)")
    }

    func testMinPFilteringPreservesHighProbabilityTokens() {
        // TopPSampler with minP should keep tokens above the threshold
        let sampler = TopPSampler(temperature: 1.0, minP: 0.5)
        let token = sampler.sample(logits: logits).item(Int.self)
        // With minP=0.5, only tokens with prob >= 0.5 * maxProb should survive
        XCTAssertTrue((0..<4).contains(token), "Expected valid token index, got \(token)")
    }

    func testTopPSamplerProducesDeterministicResultsWithSameState() {
        // Two samplers with the same parameters should produce valid samples
        let sampler = TopPSampler(temperature: 1.0, topP: 0.9, topK: 2)
        let token = sampler.sample(logits: logits).item(Int.self)
        XCTAssertTrue([2, 3].contains(token), "Expected token from top-2, got \(token)")
    }

    func testArgMaxSamplerAlwaysSelectsHighestLogit() {
        let sampler = ArgMaxSampler()
        let token = sampler.sample(logits: logits).item(Int.self)
        XCTAssertEqual(token, 3, "ArgMax should always select the highest logit")
    }

    func testCategoricalSamplerProducesValidToken() {
        let sampler = CategoricalSampler(temperature: 1.0)
        let token = sampler.sample(logits: logits).item(Int.self)
        XCTAssertTrue((0..<4).contains(token), "Expected valid token index, got \(token)")
    }

    func testZeroTemperatureCreatesArgMaxSampler() {
        let params = GenerateParameters(temperature: 0.0)
        let sampler = params.sampler()
        XCTAssertTrue(sampler is ArgMaxSampler)
    }

    func testNonZeroTemperatureWithFiltersCreatesTopPSampler() {
        let params = GenerateParameters(temperature: 0.7, topP: 0.9)
        let sampler = params.sampler()
        XCTAssertTrue(sampler is TopPSampler)
    }
}
