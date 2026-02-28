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
            try? await vectorStore.rebuild(embeddingDim: currentDim)
        }

        // Backfill memory records.
        var offset = 0
        let pageSize = 50
        var recordsEmbedded = 0

        while true {
            guard let page = try? await memoryStore.allActiveRecords(pageSize: pageSize, offset: offset),
                  !page.isEmpty
            else { break }

            for record in page {
                if let embedding = try? await embeddingEngine.embed(text: record.text) {
                    try? await vectorStore.upsertRecordEmbedding(
                        recordId: record.id,
                        embedding: embedding
                    )
                    recordsEmbedded += 1
                }
            }
            offset += page.count
            if page.count < pageSize { break }
        }

        // Backfill entity facts.
        var factsEmbedded = 0
        if let facts = try? await entityStore.allFactsForEmbedding() {
            for (factId, _, key, value) in facts {
                let factText = "\(key): \(value)"
                if let embedding = try? await embeddingEngine.embed(text: factText) {
                    try? await entityStore.updateFactEmbedding(factId: factId, embedding: embedding)
                    try? await vectorStore.upsertFactEmbedding(factId: factId, embedding: embedding)
                    factsEmbedded += 1
                }
            }
        }

        // Persist model metadata so next launch skips unchanged records.
        try? await memoryStore.writeSchemaMeta("embedding_model_id", value: currentModelId)
        try? await memoryStore.writeSchemaMeta("embedding_model_dim", value: String(currentDim))

        NSLog("EmbeddingBackfillRunner: done — records=%d facts=%d model=%@",
              recordsEmbedded, factsEmbedded, currentModelId)
    }
}
