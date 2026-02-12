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
//!
//! # Key Types
//!
//! - [`AgentConfig`] — Configuration (limits, timeouts, system prompt)
//! - [`AgentLoop`] — The main loop engine
//! - [`AgentLoopResult`] — Complete output of an agent run
//! - [`TurnResult`] — Output of a single turn (text + tool calls)
//! - [`ExecutedToolCall`] — A tool call with its result and timing
//! - [`StopReason`] — Why the loop stopped
//! - [`StreamAccumulator`] — Collects streaming events into structured data
//! - [`ToolExecutor`] — Executes tools with timeout and cancellation

pub mod accumulator;
pub mod executor;
pub mod loop_engine;
pub mod types;
pub mod validation;

// Re-export key types for convenience
pub use accumulator::{AccumulatedToolCall, AccumulatedTurn, StreamAccumulator};
pub use executor::ToolExecutor;
pub use loop_engine::{build_messages_from_result, AgentLoop};
pub use types::{AgentConfig, AgentLoopResult, ExecutedToolCall, StopReason, TurnResult};
pub use validation::validate_tool_args;
