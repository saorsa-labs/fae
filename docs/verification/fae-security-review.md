# Fae Deep Analysis: Security, Memory, and the Local-First Paradigm

*Reviewed by Gemini 3.1 Pro High*

This report focuses specifically on the durability of the memory systems and the unique security posture of Fae, a local-first conversational assistant with tool-use capabilities. Unlike cloud-based assistants where credential leakage is a primary risk during model training and inference, Fae's 100% local paradigm (where inference, speech synthesis/recognition, and memory persistence happen entirely on-device) changes the threat landscape. Here, sensitive plaintext data (such as API keys, passwords, and calendar entries) can reside in the context window safely. Thus, the security focus shifts from *inference leakage* to *network data exfiltration* and *unauthorized destructive actions* by autonomous tools.

This analysis incorporates the recent "Permissions Great Purge," which removed legacy, redundant security stores (`OutboundExfiltrationGuard`, `ApprovedToolsStore`, and `ToolToggleStore`) and consolidated security rules into a centralized core-enforced security spine.

---

## 1. Memory Reliability and Backups

The memory system is Fae's identity and state. Corrupting or losing the database resets the assistant. Fae uses a robust memory architecture built on [GRDB](https://github.com/groue/GRDB.swift) and SQLite.

### 1.1. SQLite Resiliency (`SQLiteMemoryStore.swift`)
Fae implements production-grade relational database configurations:
*   **Write-Ahead Logging (WAL):** The database enforces `PRAGMA journal_mode = WAL`. By writing to a separate write-ahead log rather than directly mutating the database file, Fae enables concurrent reads and writes. The background scheduler can capture new memories or perform migrations without blocking user-facing context queries (Recall).
*   **Foreign Key Constraints:** `PRAGMA foreign_keys = ON` is configured on every connection. This ensures referential integrity across relational tables (e.g., `entities` -> `entity_mentions` -> `entity_facts`), preventing orphaned records when data is forgotten or superseded.
*   **Schema Migration Engine:** Schema migrations (currently at version 9) are handled sequentially in Swift. The system dynamically creates search indices, triggers to sync the FTS5 full-text search index (`memory_fts`), and updates tables safely on startup.
*   **Integrity Verification:** On launch, Fae runs `PRAGMA quick_check` to verify database sanity. Any integrity issues are logged immediately.

### 1.2. Atomic Backups (`MemoryBackup.swift`)
Database backups are executed by a background scheduler:
*   **`VACUUM INTO` Backups:** Daily backups use the native SQLite `VACUUM INTO` command. Unlike standard file copies, which can result in corruption if a write transaction is active, `VACUUM INTO` creates an atomic, consistent, and defragmented copy of the database while it is live.
*   **Rotation Policies:** The scheduler rotates backups daily, retaining only the last 7 files by default to limit disk usage while maintaining recovery coverage.
*   **Vault Backup (`vault_backup`):** Fae performs daily rolling Git-based backups of the user's local workspace secrets and settings to `~/.fae-vault/`, ensuring configuration history is preserved.

### 1.3. Pipeline Fault Isolation (`MemoryOrchestrator.swift`)
Memory extraction is inherently complex as it depends on unstructured LLM output. The `MemoryOrchestrator` wraps memory capturing tasks in isolated `do-catch` blocks. If the LLM generates malformed JSON or triggers parsing exceptions during memory consolidation, the system logs the incident but continues execution without halting the conversation pipeline.

---

## 2. Centralized Core-Enforced Security Spine

Fae replaces prompt-only guardrails with a core-enforced security layer centered on `DamageControlPolicy` and `ToolExecutorContext`.

```
                  [ LLM Tool Request ]
                           │
                           ▼
              ┌────────────────────────┐
              │  DamageControlPolicy   │ ◄── [ ModelLocality Context ]
              └────────────┬───────────┘
                           │ (Allow / Block / Confirm)
                           ▼
              ┌────────────────────────┐
              │  TrustedActionBroker   │ ◄── [ Verified Speaker Identity ]
              └────────────┬───────────┘
                           │ (Execute Tool)
                           ▼
                  [ Target System ]
```

### 2.1. Dual-Trust Model (`ModelLocality`)
Fae categorizes model execution into two trust classes:
1.  **Local Model (`.local`):** The default state where weights are running on-device via Apple's Neural Engine (MLX). Local models are granted full local read/write capabilities (subject to default authorization prompts).
2.  **Non-Local/Co-Work Model (`.nonLocal`):** Applied when external API models or remote providers are connected. External models operate under zero-trust constraints for local resources.

### 2.2. Zero-Access Path Rules
For non-local models, `DamageControlPolicy` enforces a hard block on sensitive local files. Zero-access paths are blocked for both read and write operations. The path rules include:
*   **Cryptographic Keys:** `~/.ssh`, `~/.gnupg`
*   **Cloud & Package Credentials:** `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker/config.json`, `~/.npmrc`, `~/.pypirc`, `~/.netrc`
*   **Environment Secrets:** `~/.secrets`, `~/.env`, `~/.envrc`, `~/.saorsa-keys` (blocked globally for both local and non-local models)
*   **Fae Internal Configuration:** `~/.fae-vault`, `speakers.json`, `directive.md`, `config.toml`, `soul.md`

This ensures that even if a remote provider is compromised or suffers a prompt injection, it cannot read the user's SSH keys or Fae's internal state.

### 2.3. Three-Tier Damage Control
To prevent catastrophic system damage from autonomous commands, `DamageControlPolicy` intercepts tool invocations (especially `bash` and file mutations) and runs them through a deterministic regex filter:

| Action Level | UX Behavior | Examples Covered |
| :--- | :--- | :--- |
| **Block** | Hard deny, immediate termination, no override. | `rm -rf /`, `diskutil erase`, raw disk writes (`dd of=/dev/...`), root permission stripping (`chmod -R 000 /`) |
| **Disaster** | Red-border warning, requires physical button click, voice/agent bypass blocked. | Recursive deletion of user directories (`rm -rf ~`, `rm -rf ~/Documents`, `rm -rf ~/Library`) |
| **Confirm Manual**| Orange-border confirmation, requires physical button click, no voice bypass. | Commands invoking `sudo rm`, execution of remote scripts (`curl \| bash`), launchd changes, AppleScript UI control |

---

## 3. CoWork Security Gateway (`CoworkToolExecutor.swift`)

When users route queries to non-local providers via the CoWork UI interface, Fae wraps the connection in the `CoworkToolExecutor` actor to prevent data exfiltration.

*   **Pre-Flight Path Check:** The executor forces `locality: .nonLocal` during evaluation, triggering the zero-access path block rules.
*   **Outbound Privacy Filters:** Outbound prompts are scanned for Personally Identifiable Information (PII) before egress. If PII is detected, Fae generates a `.coworkPIIRedacted` event and logs the warning.
*   **Inbound Injection Scanning:** Fae scans responses returned from external APIs for prompt injection signatures (e.g., `"ignore previous instructions"`, `"disregard all prior"`). If a match is found, the execution is terminated immediately, throwing an `.inboundScanFlagged` error to protect the local context.

---

## 4. Agent Client Protocol (ACP) Session Safety

Fae integrates with external local/remote agents using the Agent Client Protocol (ACP) via `ACPSessionManager.swift` and `AgentSessionTool.swift`.

```
                    [ ACP Agent CLI ]
                           │
                           ├─► [ Tool Call Request ]
                           │          │
                           ▼          ▼
            ┌──────────────────────────────┐
            │      ACPSessionManager       │
            ├──────────────────────────────┤
            │  ApprovalPolicy Evaluation   │
            └──────────────┬───────────────┘
                           │
             ┌─────────────┴─────────────┐
             ▼                           ▼
      [ Read-Only Tool ]          [ Write/Exec Tool ]
      (e.g., fetch_url)            (e.g., bash, click)
             │                           │
             ▼                           ▼
      [ Auto-Approve ]            [ User Confirmation / Deny ]
```

### 4.1. Intent-Based Approval Policies
When launching an external agent session, Fae requires the definition of an `ApprovalPolicy`:
*   `denyAll`: Rejects all tool permission requests.
*   `approveAll`: Auto-approves all tool actions requested by the agent (high risk).
*   `approveReads`: Auto-approves read-only operations while prompting for any mutation.

### 4.2. Read-Only Verification Allowlist
Under the default `approveReads` policy, Fae maps requests against a static allowlist (`ACPSessionManager.readOnlyTools`):
```swift
private static let readOnlyTools: Set<String> = [
    "read", "window_control", "session_search", "web_search", "fetch_url",
    "calendar", "reminders", "contacts", "mail", "notes",
    "scheduler_list", "roleplay", "activate_skill", "input_request",
    "find_element", "voice_identity", "till_done"
]
```
Any command not in this allowlist (such as `bash`, `write`, `edit`, `click`, or `manage_skill`) is denied auto-approval and must be explicitly authorized by the user.

### 4.3. Process and Context Constraints
*   **Process Isolation:** Agent execution is sandboxed, enforcing path resolution rules to keep the agent in the specified working directory (`cwd`) and preventing path escape (`..`).
*   **Resource Ceilings:** The session manager enforces a limit of **5 concurrent sessions** to prevent resource exhaustion.
*   **Turn Timeouts:** Session calls default to a 600-second execution timeout, after which Fae terminates the agent's subprocess.

---

## 5. Security Auditing (`SecurityEventLogger.swift`)

Fae implements an append-only JSONL security log (`~/Library/Application Support/fae/security/audit.jsonl`).
*   **Structured Traces:** Every tool execution evaluates a verdict (allow, block, flag, confirm) that is appended to the log along with details like verified speaker ID, model name, and tool arguments.
*   **Data Redaction:** The logger automatically redacts potential secrets and passwords from arguments before writing to disk, ensuring that the security log itself does not become a target for credential theft.
*   **Developer Dashboard:** Diagnostics are rendered in the application's developer dashboard to visualize allow/deny distribution, reason codes, and threat vectors.

---

## 6. Summary Conclusion

Fae's security posture is highly robust for a local-first application. By shifting the threat model away from *local context exposure* and concentrating defenses on *outbound network exfiltration* and *unauthorized tool execution*, Fae strikes a balance between agent capability and safety. 

The integration of `DamageControlPolicy` as a core chokepoint ensures that destructive system commands are blocked regardless of LLM behavior, while the strict allowlist filtering in `ACPSessionManager` prevents third-party ACP agents from abusing local shell or filesystem access. Coupled with SQLite `VACUUM INTO` backups and WAL residency, Fae's state and security remain reliable and production-ready.
