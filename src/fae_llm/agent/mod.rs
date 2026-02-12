//! Agent loop engine for agentic LLM interactions.
//!
//! This module implements the core agent loop: prompt -> stream -> tool calls
//! -> execute -> continue. It provides safety guards (max turns, max tool
//! calls per turn), timeouts (per-request and per-tool), and cancellation
//! propagation.
//!
//! # Architecture
//!
//! ```text
//! AgentLoop
//!   +-- AgentConfig (limits, timeouts, system prompt)
//!   +-- ProviderAdapter (LLM backend)
//!   +-- ToolRegistry (available tools)
//!   +-- CancellationToken (abort signal)
//! ```
//!
//! # Event Flow
//!
//! ```text
//! 1. Send messages to provider (with timeout)
//! 2. Stream response, accumulate text + tool calls
//! 3. If tool calls: validate args, execute tools, append results, loop
//! 4. If complete: return final result
//! 5. If cancelled or limits hit: return with appropriate StopReason
//! ```

pub mod accumulator;
pub mod types;
