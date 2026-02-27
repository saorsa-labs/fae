import Foundation

/// Multi-engine search orchestrator.
///
/// Queries engines concurrently, deduplicates by normalized URL,
/// applies position-decay + engine-weight scoring, cross-engine boost,
/// and returns ranked results. Uses circuit breaker for fault tolerance
/// and in-memory cache for performance.
actor SearchOrchestrator {
    private let cache = SearchCache()

    /// Concrete engine instances.
    private let engineImpls: [SearchEngine: any SearchEngineProtocol] = [
        .duckDuckGo: DuckDuckGoEngine(),
        .brave: BraveEngine(),
        .google: GoogleEngine(),
        .bing: BingEngine(),
        .startpage: StartpageEngine(),
    ]

    // MARK: - Public API

    /// Search with full configuration.
    func search(query: String, config: SearchConfig = .default) async throws -> [SearchResult] {
        try config.validate()

        // Check cache first.
        let cacheKey = SearchCache.makeKey(query: query, engines: config.engines)
        if let cached = await cache.get(key: cacheKey, ttlSeconds: config.cacheTTLSeconds) {
            return cached
        }

        // Select engines via circuit breaker.
        let engines = await selectEngines(config: config)
        guard !engines.isEmpty else {
            throw SearchError.allEnginesFailed("No engines available")
        }

        // Query all engines concurrently with jitter.
        let allResults = await queryAllEngines(engines: engines, query: query, config: config)

        guard !allResults.isEmpty else {
            throw SearchError.allEnginesFailed("All engines returned empty results for '\(query)'")
        }

        // Score results per engine (position-decay).
        let scored = scoreResults(allResults)

        // Deduplicate by normalized URL.
        let deduped = deduplicate(scored)

        // Apply cross-engine boost.
        let boosted = applyCrossEngineBoost(deduped)

        // Sort by score descending and truncate.
        var final = boosted.sorted { $0.score > $1.score }
        if final.count > config.maxResults {
            final = Array(final.prefix(config.maxResults))
        }

        // Cache results.
        await cache.insert(key: cacheKey, results: final)

        return final
    }

    /// Search with default configuration.
    func searchDefault(query: String) async throws -> [SearchResult] {
        try await search(query: query, config: .default)
    }

    /// Fetch and extract content from a URL.
    func fetchPageContent(urlString: String, config: SearchConfig = .default) async throws -> PageContent {
        guard let url = URL(string: urlString) else {
            throw SearchError.http("Invalid URL: \(urlString)")
        }

        let request = SearchHTTPClient.getRequest(url: url, config: config)
        let session = URLSession(configuration: SearchHTTPClient.sessionConfiguration(config: config))
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SearchError.http("Fetch returned status \(code) for \(urlString)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parse("Response not valid UTF-8 for \(urlString)")
        }

        return ContentExtractor.extract(html: html, url: urlString)
    }

    /// Clear the result cache.
    func clearCache() async {
        await cache.clear()
    }

    // MARK: - Engine Selection

    /// Select engines that the circuit breaker allows. Falls back to all configured if all tripped.
    private func selectEngines(config: SearchConfig) async -> [SearchEngine] {
        var available: [SearchEngine] = []
        for engine in config.engines {
            if await GlobalCircuitBreaker.shared.shouldAttempt(engine) {
                available.append(engine)
            }
        }

        if available.isEmpty {
            // All tripped — try all anyway (better to try than return nothing).
            NSLog("SearchOrchestrator: all circuit breakers tripped, falling back to all engines")
            return config.engines
        }

        return available
    }

    // MARK: - Concurrent Querying

    /// Query all engines concurrently with jitter delays.
    private func queryAllEngines(engines: [SearchEngine], query: String, config: SearchConfig) async -> [SearchResult] {
        await withTaskGroup(of: [SearchResult].self) { group in
            for (index, engine) in engines.enumerated() {
                guard let impl = engineImpls[engine] else { continue }

                group.addTask {
                    // Apply jitter delay for engines after the first.
                    if index > 0 {
                        let delayMs = UInt64.random(in: config.requestDelayMs.0...config.requestDelayMs.1)
                        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    }

                    do {
                        let results = try await impl.search(query: query, config: config)
                        await GlobalCircuitBreaker.shared.recordSuccess(engine)
                        return results
                    } catch {
                        NSLog("SearchOrchestrator: %@ failed: %@", engine.rawValue, error.localizedDescription)
                        await GlobalCircuitBreaker.shared.recordFailure(engine)
                        return []
                    }
                }
            }

            var allResults: [SearchResult] = []
            for await results in group {
                allResults.append(contentsOf: results)
            }
            return allResults
        }
    }

    // MARK: - Scoring

    /// Apply position-decay scoring to results from each engine.
    ///
    /// Formula: `score = engine_weight * (1.0 / (1.0 + position * 0.1))`
    private func scoreResults(_ results: [SearchResult]) -> [SearchResult] {
        // Group by engine to apply position-based scoring per engine.
        var byEngine: [String: [SearchResult]] = [:]
        for result in results {
            byEngine[result.engine, default: []].append(result)
        }

        var scored: [SearchResult] = []
        for (engineName, engineResults) in byEngine {
            let weight = SearchEngine(rawValue: engineName)?.weight ?? 1.0
            for (position, var result) in engineResults.enumerated() {
                let decay = 1.0 / (1.0 + Double(position) * 0.1)
                result.score = weight * decay
                scored.append(result)
            }
        }

        return scored
    }

    // MARK: - Deduplication

    /// Deduplicate results by normalized URL, keeping highest score and tracking contributing engines.
    private func deduplicate(_ results: [SearchResult]) -> [DeduplicatedResult] {
        var seen: [String: DeduplicatedResult] = [:]

        for result in results {
            let normalizedURL = URLNormalizer.normalize(result.url)

            if var existing = seen[normalizedURL] {
                // Keep the higher-scored result.
                if result.score > existing.result.score {
                    existing.result = result
                }
                // Track contributing engine (no duplicates).
                if let engine = SearchEngine(rawValue: result.engine),
                   !existing.engines.contains(engine)
                {
                    existing.engines.append(engine)
                }
                seen[normalizedURL] = existing
            } else {
                let engine = SearchEngine(rawValue: result.engine)
                seen[normalizedURL] = DeduplicatedResult(
                    result: result,
                    engines: engine.map { [$0] } ?? []
                )
            }
        }

        return Array(seen.values)
    }

    // MARK: - Cross-Engine Boost

    /// Boost results that appear in multiple engines.
    ///
    /// Formula: `boosted_score = base_score * (1.0 + 0.2 * (engine_count - 1))`
    private func applyCrossEngineBoost(_ deduped: [DeduplicatedResult]) -> [SearchResult] {
        deduped.map { entry in
            var result = entry.result
            let boost = 1.0 + 0.2 * Double(max(entry.engines.count, 1) - 1)
            result.score *= boost
            return result
        }
    }
}

/// Internal type for tracking which engines contributed a result.
private struct DeduplicatedResult {
    var result: SearchResult
    var engines: [SearchEngine]
}
