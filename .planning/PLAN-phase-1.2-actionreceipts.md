# Phase 1.2: ActionReceipts Engine

## Context

Phase 1.1 is complete:
- SOUL.md narration clause added
- HEARTBEAT.md updated with "Invisible Permissions"
- `speakerId: String?` wired through ToolExecutorContext
- `FaeDirectories.receiptsDatabase` path added

Now we build the ActionReceipts Engine: a separate SQLite database (receipts.db)
for storing reversible action records with undo capability.

## Architecture Decisions (from eng review)
- receipts.db is SEPARATE from fae.db (independent failure domain)
- Pre-state blob capped at 50MB (larger files: receipt created but no pre-state)
- ReversibilityEngine extended to SQLite undo (not JSON checkpoint replacement)
- Batch undo in reverse chronological order
- GC piggybacks on memory_gc in FaeScheduler
- receipts.db backed up in GitVaultManager (alongside fae.db, scheduler.db)

## Key Files
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` — NEW actor
- `native/macos/Fae/Sources/Fae/Tools/ToolExecutor.swift` — wire in receipt creation
- `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift` — add GC hook
- `native/macos/Fae/Sources/Fae/Backup/GitVaultManager.swift` — add receipts.db
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift` — init ReceiptStore
- `native/macos/Fae/Sources/Fae/Tools/ReversibilityEngine.swift` — reference only

---

## Task 1: ActionReversibility enum + BashReversibilityClassifier

**What**: Define the reversibility model for all 37 tools, plus bash command classifier.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (new — just the enum + classifier in Task 1)

**Details**:
- `ActionReversibility` enum: `reversible`, `irreversible`, `notApplicable`
  - `reversible`: write, edit, calendar (create/update/delete), reminders (create/update/delete),
    contacts (create/update), bash (allowlist only), notes (create/update/delete)
  - `irreversible`: mail (send), delegate_agent, agent_session, bash (non-allowlist)
  - `notApplicable`: all read-only tools (read, screenshot, camera, web_search, fetch_url,
    contacts read, calendar read, reminders read, voice_identity read, etc.)
- Static func `ActionReversibility.classify(toolName: String, arguments: [String: Any]) -> ActionReversibility`
- `BashReversibilityClassifier`: separate struct with `classify(command: String) -> ActionReversibility`
  - Allowlist for reversible bash: patterns matching `echo ... > file`, `cp `, `mkdir `, `mv `, `touch `
  - Everything else → `.irreversible`

**Tests**: No tests needed for Task 1 (pure logic, covered by Task 9 tests)

---

## Task 2: ReceiptStore actor + schema

**What**: Create the ReceiptStore actor with GRDB DatabaseQueue against receipts.db.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (continue building)

**Details**:
- `actor ReceiptStore`
- `init(path: String) throws` — open receipts.db with WAL + foreign keys
- Schema: single table `action_receipts`
  ```sql
  CREATE TABLE IF NOT EXISTS action_receipts (
    id              TEXT PRIMARY KEY,
    created_at      INTEGER NOT NULL,
    tool_name       TEXT NOT NULL,
    arguments_json  TEXT NOT NULL DEFAULT '{}',
    reversibility   TEXT NOT NULL,  -- 'reversible'|'irreversible'|'not_applicable'
    pre_state_blob  BLOB,           -- nil if >50MB or not_applicable
    pre_state_path  TEXT,           -- original file path for file ops
    speaker_id      TEXT,           -- from ToolExecutorContext.speakerId
    session_id      TEXT,
    turn_id         TEXT,
    undone_at       INTEGER,        -- non-nil if already undone
    undo_error      TEXT            -- last undo error if any
  )
  ```
- `ActionReceiptRecord` struct (Codable, Sendable) mapping the table
- `static let maxPreStateBlobBytes = 50 * 1024 * 1024` (50MB cap)
- `static let maxRetainedReceipts = 10_000`

**Tests**: Build passes

---

## Task 3: createReceipt() method

**What**: Implement `createReceipt()` — captures pre-state and inserts a receipt row.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (add method)

**Details**:
- `func createReceipt(toolName: String, arguments: [String: Any], speakerId: String?, sessionId: String?, turnId: String?) async -> String?`
  - Returns receipt ID (UUID string) or nil on failure (never throws — fire-and-forget safe)
- Classify reversibility with `ActionReversibility.classify(toolName:arguments:)`
- For reversible file tools (`write`, `edit`, `bash` with file path): capture pre-state blob
  - Read file at path from arguments; if exists and size <= 50MB, store as blob
  - Store `pre_state_path` = file path from arguments
- For Apple tools (calendar, reminders, notes): pre-state is nil for now (Phase 1.2 scope note: Apple tool pre-state in Task 8)
- Insert into `action_receipts` with `undone_at = nil`
- Log with NSLog on error; return nil

**Tests**: Build passes

---

## Task 4: undo(receiptId:) method

**What**: Implement `undo(receiptId:)` — restore from pre-state snapshot.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (add method)

**Details**:
- `func undo(receiptId: String) async -> Result<Void, ReceiptStoreError>`
- `ReceiptStoreError: Error` enum with cases: `receiptNotFound`, `alreadyUndone`, `notReversible`, `noPreState`, `restoreFailed(String)`
- Fetch receipt row; guard `undone_at == nil`, `reversibility == "reversible"`, `pre_state_blob != nil || pre_state_path != nil`
- For file pre-states:
  - If `pre_state_blob != nil`: write blob back to `pre_state_path`
  - If `pre_state_blob == nil && pre_state_path != nil` (file was created by tool, didn't exist before): delete the file
- Mark `undone_at = Int(Date().timeIntervalSince1970)` in DB
- Return `.success(())` or `.failure(...)`

**Tests**: Build passes

---

## Task 5: batchUndo(since:) method

**What**: Implement `batchUndo(since:)` — undo all reversible receipts after a given date in reverse chronological order.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (add method)

**Details**:
- `func batchUndo(since: Date) async -> (succeeded: Int, failed: Int)`
- Query: all receipts with `created_at >= Int(since.timeIntervalSince1970)` AND `undone_at IS NULL` AND `reversibility = 'reversible'`
- Sort by `created_at DESC` (reverse chronological)
- Call `undo(receiptId:)` on each; count successes and failures
- Continue even if individual undos fail (best-effort)
- Return (succeeded, failed) counts

**Tests**: Build passes

---

## Task 6: pruneExpired() + GC

**What**: Implement `pruneExpired()` GC method and wire into FaeScheduler.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (add method)
- `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift` (wire GC hook)
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift` (expose receiptStore)

**Details**:
- In ReceiptStore:
  - `func pruneExpired() async -> Int` — deletes rows where `created_at < 7 days ago` AND `undone_at IS NOT NULL`
    (only prune completed undos; keep un-undone receipts for 7 days)
  - Also enforce max 10,000 rows: delete oldest rows beyond the cap
  - Returns count of pruned rows

- In FaeScheduler `runMemoryGC()` (line 377):
  - After existing GC, add: `if let store = receiptStore { let pruned = await store.pruneExpired(); if pruned > 0 { NSLog(...) } }`
  - Add `var receiptStore: ReceiptStore?` weak property to FaeScheduler

- In FaeCore:
  - Add `private(set) var receiptStore: ReceiptStore?`
  - Initialize in `start()` alongside memoryOrchestrator: `receiptStore = try? ReceiptStore(path: FaeDirectories.receiptsDatabase.path)`
  - Wire into FaeScheduler: `scheduler.receiptStore = receiptStore`

**Tests**: Build passes

---

## Task 7: Wire ReceiptStore into ToolExecutor

**What**: Add `receiptStore: ReceiptStore?` to ToolExecutor and call `createReceipt()` after successful execution.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ToolExecutor.swift`
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift` (pass to ToolExecutor init)

**Details**:
- Add `var receiptStore: ReceiptStore?` to ToolExecutor (optional, set after init by FaeCore)
- In ToolExecutor.execute(), after step 15 (post-execution analytics + logging), before returning:
  ```swift
  // ── 16. Action receipt ───────────────────────────────────────────
  if !result.isError, let store = receiptStore {
      await store.createReceipt(
          toolName: call.name,
          arguments: call.arguments,
          speakerId: context.speakerId,
          sessionId: nil,  // Phase 1.3 will add session context
          turnId: context.workflowTurnID
      )
  }
  ```
- In FaeCore `start()`: `toolExecutor.receiptStore = receiptStore`
- Note: `receiptStore` on ToolExecutor is a `var` set post-init (actor isolation ok, set before first call)

**Tests**: Build passes

---

## Task 8: Apple tool pre-state capture (calendar + reminders)

**What**: For calendar and reminders write operations, capture a JSON blob of the current state before mutation.

**Files**:
- `native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift` (extend createReceipt)
- `native/macos/Fae/Sources/Fae/Tools/AppleTools.swift` (read-only reference to understand argument shape)

**Details**:
- Extend `createReceipt()` with Apple tool pre-state logic:
  - For `calendar` with `action: "delete"` or `"update"`: fetch event by `event_id` argument and JSON-encode it as blob
  - For `reminders` with `action: "delete"` or `"update"`: fetch reminder by `reminder_id` and JSON-encode
  - For `notes` with `action: "delete"` or `"update"`: store note title/identifier in blob
  - Keep it simple: encode the arguments themselves as the "what was being changed" blob (full EventKit fetch is complex and out of scope)
  - `pre_state_path = nil` for Apple tools (no file path)
  - If fetching fails, still create receipt with `pre_state_blob = nil` (best-effort)

- The undo for Apple tools is Phase 1.3+ (requires re-creating the EKEvent from JSON)
  - For now: `undo(receiptId:)` returns `.failure(.noPreState)` if no file path

**Tests**: Build passes

---

## Task 9: Wire receipts.db into GitVaultManager backup

**What**: Add receipts.db to the GitVaultManager backup list alongside fae.db and scheduler.db.

**Files**:
- `native/macos/Fae/Sources/Fae/Backup/GitVaultManager.swift`

**Details**:
- In `copySourceFiles(configOnly:)` (line 249):
  - Add `"receipts.db"` to the `dbFile` array: `for dbFile in ["fae.db", "scheduler.db", "receipts.db"]`
- In `listBackupContents()` if such a method exists: also list receipts.db
- That's it — VACUUM INTO handles the rest same as fae.db

**Tests**: Build + swift test pass

---

## Task 10: Final build + test validation

**What**: Full build and test validation for Phase 1.2.

**Files**: All modified files

**Details**:
- `cd native/macos/Fae && swift build 2>&1` — zero warnings, zero errors
- `cd native/macos/Fae && swift test 2>&1` — all existing tests pass
- Verify ReceiptStore compiles cleanly as a standalone actor
- Verify no circular imports (ReceiptStore imports GRDB, Foundation only)

**Tests**: Full validation
