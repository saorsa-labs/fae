import Foundation

/// One-time background migration of existing `.person` memory records → entity graph.
///
/// Runs at startup via `FaeCore.start()` after the memory store is open.
/// Guards against double-running via `schema_meta["entity_backfill_done"]`.
actor EntityBackfillRunner {

    /// Entry point called from FaeCore after memory store opens.
    /// Runs in a detached background Task — never blocks startup.
    static func backfillIfNeeded(
        memoryStore: SQLiteMemoryStore,
        entityLinker: EntityLinker,
        entityStore: EntityStore
    ) {
        Task.detached(priority: .background) {
            do {
                // Guard: never run twice.
                if let done = try await entityStore.metaValue(key: "entity_backfill_done"),
                   done == "1"
                {
                    return
                }

                let records = try await memoryStore.findPersonRecords(limit: 1000)
                guard !records.isEmpty else {
                    try await entityStore.setMetaValue(key: "entity_backfill_done", value: "1")
                    return
                }

                NSLog("EntityBackfillRunner: backfilling %d person records", records.count)
                var linked = 0
                for record in records {
                    await entityLinker.linkPersonRecord(
                        text: record.text,
                        recordId: record.id,
                        turnId: record.sourceTurnId ?? "backfill"
                    )
                    linked += 1
                }

                try await entityStore.setMetaValue(key: "entity_backfill_done", value: "1")
                NSLog("EntityBackfillRunner: complete — linked %d records", linked)
            } catch {
                NSLog("EntityBackfillRunner: error: %@", error.localizedDescription)
            }
        }
    }
}
