# Fae Deep Analysis: Security, Memory, and the Local-First Paradigm

*Reviewed by Gemini 3.1 Pro High*

This report focuses specifically on the durability of the memory systems and the unique security posture of a 100% local assistant like Fae, specifically accounting for the fact that the context window and memory database may contain highly sensitive plaintext data like API keys and passwords.

## 1. Memory Reliability and Backups

The memory system is the most stateful and critical component of Fae. If the SQLite database corrupts, Fae loses her identity and context. The implementation shows production-grade safeguards.

*   **SQLite Resiliency (`SQLiteMemoryStore.swift`):**
    *   **Write-Ahead Logging (WAL):** The database enforces `PRAGMA journal_mode = WAL`. This is the gold standard for SQLite concurrency. It means Fae can read memories for context injection (Recall) at the exact same time the background scheduler is writing new extracted memories (Capture) without locked database errors.
    *   **Foreign Key Integrity:** `PRAGMA foreign_keys = ON` is enforced, ensuring that the relational entity graph (`entities` -> `entity_facts` -> `entity_mentions`) cannot be orphaned if a deletion occurs.
*   **Atomic Backups (`MemoryBackup.swift`):**
    *   **`VACUUM INTO`:** The daily backup task (`fae_backup_YYYYMMDD-HHmmss.db`) uses the SQLite `VACUUM INTO` command. This creates a highly compact, perfectly consistent snapshot of the database while it is live, without blocking the main event loop. This is far superior to standard file copies.
    *   **Rotation:** Backups are aggressively rotated (keeping the last 7 by default) to prevent the disk from silently filling up over months of operation.
*   **Pipeline Fault Isolation (`MemoryOrchestrator.swift`):**
    *   Memory extraction is complex (parsing dates, people, promises). The `capture()` method correctly wraps these extractions in isolated `do-catch` blocks. If the LLM produces strange text that crashes a memory parser, the orchestrator logs the error but does not crash the `PipelineCoordinator` actor.

## 2. Security in a 100% Local Context

In a cloud-based AI, having passwords in the context window is a massive liability. **In Fae's 100% local architecture, it is an intended capability.** Because inference and storage happen entirely on Apple Silicon, Fae *can* know your passwords without compromising them. The threat model therefore shifts entirely from *inference leakage* to *data exfiltration and destructive action*.

### Exfiltration Defense-in-Depth

If an attacker attempts a prompt injection attack (e.g., getting Fae to read a secret file and `curl` it to an external server), Fae uses a 4-layer execution guard located directly in `PipelineCoordinator.executeTool()`.

1.  **The Outbound Exfiltration Guard (`OutboundExfiltrationGuard`):**
    *   Before any tool executes, it is evaluated by this guard. This explicitly looks for network exfiltration patterns across arguments. If the LLM attempts to send data to a novel recipient via bash or web endpoints, this guard trips and triggers the `ActionBroker`.
2.  **The Action Broker & Intent Evaluation:**
    *   Every tool execution generates an `ActionIntent` containing the risk level, the current speaker's verified identity (via `ECAPA-TDNN` CoreML Liveness Score), and the autonomous policy profile.
    *   The `ActionBroker` evaluates the intent and forces a deterministic `ApprovalManager` prompt if the action is destructive or exfiltrative. The LLM *cannot* bypass this UI prompt programmatically.
3.  **Path and Input Sanitization (`PathPolicy` & `InputSanitizer`):**
    *   Read tools are unrestricted, which is conceptually sound for a local assistant.
    *   Write tasks are heavily restricted. Fae cannot modify system routes (`/bin`, `/Library`), dotfiles (`~/.ssh`, `~/.bashrc`), or her own `config.toml`.
    *   The `FetchURLTool` has a hardcoded blocklist preventing SSFR attacks against cloud metadata endpoints (`169.254.169.254`), showing the developers are aware of advanced pivot attacks.
4.  **Process Group Isolation (`BashTool`):**
    *   The `BashTool` isolates spawned commands. If a command times out (30s) or attempts to hang, `kill(-pid, SIGTERM)` takes down the entire process tree, preventing Fae from leaving persistent rogue processes running in the background. Furthermore, `stderr` is wiped from the context window to prevent attackers from using error logs to re-inject adversarial prompts if their payload fails.

## Summary Conclusion

Fae's memory resilience is exceptional, actively leveraging SQLite's best advanced features (`VACUUM INTO`, `WAL`) rather than treating it like a flat file. 

From a security perspective, the architecture correctly shifts focus to exfiltration defense. Since the context window is completely local, it is safe to process sensitive data, provided the `ActionBroker` and `ApprovalManager` remain uncompromised. The presence of the `OutboundExfiltrationGuard` in the central loop confirms this is a highly defensible, production-ready design for local autonomous agents.
