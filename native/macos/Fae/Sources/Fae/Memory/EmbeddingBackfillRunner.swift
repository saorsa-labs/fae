import Foundation

/// Background runner that embeds all memory records and entity facts using the current
/// NeuralEmbeddingEngine. Guarded by `schema_meta["embedding_model_id"]` so work
/// is only repeated when the model changes.
enum EmbeddingBackfillRunner {

    /// Launch backfill in a detached background task (non-blocking).
    static func backfillIfNeeded(
        memoryStore: SQLiteMemoryStore,
        entityStore: EntityStore,
        vectorStore: VectorStore,
        embeddingEngine: NeuralEmbeddingEngine
    ) {
        Task.detached(priority: .background) {
            await performBackfill(
                memoryStore: memoryStore,
                entityStore: entityStore,
                vectorStore: vectorStore,
                embeddingEngine: embeddingEngine
            )
        }
    }

    // MARK: - Private

    private static func performBackfill(
        memoryStore: SQLiteMemoryStore,
        entityStore: EntityStore,
        vectorStore: VectorStore,
        embeddingEngine: NeuralEmbeddingEngine
    ) async {
        // Wait up to 5 minutes for the engine to finish loading.
        var attempts = 0
        while !(await embeddingEngine.isLoaded), attempts < 60 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            attempts += 1
        }
        guard await embeddingEngine.isLoaded else {
            NSLog("EmbeddingBackfillRunner: engine not ready after timeout — aborting")
            return
        }

        let currentModelId = await embeddingEngine.currentModelId
        let currentDim = await embeddingEngine.embeddingDimension

        // Rebuild vector tables if model changed.
        let storedModelId = (try? await memoryStore.readSchemaMeta("embedding_model_id")) ?? ""
        if storedModelId != currentModelId {
            NSLog("EmbeddingBackfillRunner: model changed (%@ → %@) — rebuilding index",
                  storedModelId, currentModelId)
            do {
                try await vectorStore.rebuild(embeddingDim: currentDim)
            } catch {
                // A failed rebuild must NOT update the guard keys below, or the backfill is skipped
                // forever on later launches, permanently degrading ANN recall. Return and retry next launch.
                NSLog("EmbeddingBackfillRunner: index rebuild failed — will retry next launch: %@",
                      error.localizedDescription)
                return
            }
        }

        // Backfill memory records. Count failures so a partial run does not advance the guard keys.
        var offset = 0
        let pageSize = 50
        var recordsEmbedded = 0
        var failureCount = 0

        while true {
            let page: [MemoryRecord]
            do {
                page = try await memoryStore.allActiveRecords(pageSize: pageSize, offset: offset)
            } catch {
                NSLog("EmbeddingBackfillRunner: record page fetch failed at offset %d: %@",
                      offset, error.localizedDescription)
                failureCount += 1
                break
            }
            if page.isEmpty { break }

            for record in page {
                do {
                    let embedding = try await embeddingEngine.embed(text: record.text)
                    try await vectorStore.upsertRecordEmbedding(
                        recordId: record.id,
                        embedding: embedding
                    )
                    recordsEmbedded += 1
                } catch {
                    failureCount += 1
                }
            }
            offset += page.count
            if page.count < pageSize { break }
        }

        // Backfill entity facts.
        var factsEmbedded = 0
        do {
            let facts = try await entityStore.allFactsForEmbedding()
            for (factId, _, key, value) in facts {
                let factText = "\(key): \(value)"
                do {
                    let embedding = try await embeddingEngine.embed(text: factText)
                    try await entityStore.updateFactEmbedding(factId: factId, embedding: embedding)
                    try await vectorStore.upsertFactEmbedding(factId: factId, embedding: embedding)
                    factsEmbedded += 1
                } catch {
                    failureCount += 1
                }
            }
        } catch {
            NSLog("EmbeddingBackfillRunner: fact enumeration failed: %@", error.localizedDescription)
            failureCount += 1
        }

        // Persist model metadata so next launch skips unchanged records — but only when the run was
        // clean. Any failure leaves the guard keys untouched so the next launch retries the backfill.
        guard failureCount == 0 else {
            NSLog("EmbeddingBackfillRunner: %d failures — guard keys not updated, retry next launch (records=%d facts=%d)",
                  failureCount, recordsEmbedded, factsEmbedded)
            return
        }
        try? await memoryStore.writeSchemaMeta("embedding_model_id", value: currentModelId)
        try? await memoryStore.writeSchemaMeta("embedding_model_dim", value: String(currentDim))

        NSLog("EmbeddingBackfillRunner: done — records=%d facts=%d model=%@",
              recordsEmbedded, factsEmbedded, currentModelId)
    }
}
