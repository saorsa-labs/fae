import Foundation

/// Outcome of a single tool execution through ``ToolExecutor``.
///
/// Carries the tool result alongside metadata that the caller may need
/// to update its own state (e.g. workflow trace contexts).
struct ToolExecutorResult: Sendable {
    /// The tool's output (success or error).
    let result: ToolResult

    /// Whether the user explicitly approved this tool invocation via the
    /// approval overlay. `nil` if approval was not required.
    let approvedByUser: Bool?

    /// Whether `DamageControlPolicy` intervened (block, disaster, or
    /// confirmManual) during evaluation.
    let damageControlIntervened: Bool

    /// Tool execution latency in milliseconds. Measured from the start of
    /// the outer `execute()` call (includes all security checks, approval
    /// wait, and actual tool invocation). `nil` only for early rejections
    /// that never reach the tool.
    let latencyMs: Int?
}

/// Operations that ``ToolExecutor`` delegates back to its owner because they
/// require state or capabilities that live outside the executor (e.g. model
/// loading, audio playback).
protocol ToolExecutorDelegate: AnyObject, Sendable {
    /// Provide a VLM provider closure for vision tools. Returns `nil` if
    /// vision is not available. The caller is responsible for loading the
    /// VLM engine if needed.
    func toolExecutorVLMProvider() async -> VLMProvider?

    /// Speak text directly through the audio playback pipeline (used for
    /// non-manual approval prompts).
    func toolExecutorSpeakDirect(_ text: String) async
}
