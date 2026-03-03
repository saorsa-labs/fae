import Foundation

/// Typed event enum replacing the JSON-serialized event system from the Rust core.
///
/// `FaeEventBus` distributes these events via Combine and bridges them to
/// `NotificationCenter` for backward compatibility with existing UI controllers.
enum FaeEvent: Sendable {
    // MARK: Pipeline

    case pipelineStateChanged(FaePipelineState)
    case assistantGenerating(Bool)
    case audioLevel(Float)
    case transcription(text: String, isFinal: Bool)
    case assistantText(text: String, isFinal: Bool)
    case degradedModeChanged(mode: String, context: String)

    // MARK: Runtime

    case runtimeState(FaeRuntimeState)
    case runtimeProgress(stage: String, progress: Double)

    // MARK: Orb

    case orbStateChanged(mode: String, feeling: String, palette: String?)

    // MARK: Approval

    case approvalRequested(id: UInt64, toolName: String, input: String)
    case approvalResolved(id: UInt64, approved: Bool, source: String)

    // MARK: Memory

    case memoryRecalled(count: Int)
    case memoryCaptured(id: String)

    // MARK: Tool Execution

    case toolExecuting(name: String)
    case toolCall(id: String, name: String, inputJSON: String)
    case toolResult(id: String, name: String, success: Bool, output: String)

    // MARK: Auxiliary UI

    case canvasVisibility(Bool)
    case conversationVisibility(Bool)
    case canvasContent(html: String, append: Bool)
    case voiceCommandRecognized(String)

    // MARK: Model

    case modelLoaded(engine: String, modelId: String)

    // MARK: Capability

    case capabilityRequested(capability: String, reason: String)
}

enum FaePipelineState: String, Sendable {
    case stopped, starting, running, stopping, error
}

enum FaeRuntimeState: String, Sendable {
    case starting, started, stopped, error
}
