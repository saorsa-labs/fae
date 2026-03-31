# Quality Patterns Review
**Date**: 2026-03-30
**Mode**: gsd — Phase 1.1

## Error types in FaeInference:

## MLEngineError cases (used by MLXLLMEngine):
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:122:public enum MLEngineError: LocalizedError {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:124:    case loadFailed(String, Error)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaePerceptionBenchmark/main.swift:24:    case terminalError
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaePerceptionBenchmark/main.swift:85:        case loadError = "load_error"
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaePerceptionBenchmark/main.swift:256:    case .terminalError:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaePerceptionBenchmark/main.swift:346:    case .terminalError: return "Terminal — swift build"
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/TestServer.swift:1102:        case 500: statusText = "Internal Server Error"
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Pipeline/CorrectionDetector.swift:17:        case nameError
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Pipeline/CorrectionDetector.swift:257:        case .nameError:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Pipeline/CorrectionDetector.swift:283:        case .nameError:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Tools/ReceiptStore.swift:222:    case databaseError(String)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/CanvasController.swift:13:    case toolResult(name: String, isError: Bool)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/QualityMetricTypes.swift:28:    case sttErrorCount
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/QualityMetricTypes.swift:29:    case llmErrorCount
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/QualityMetricTypes.swift:30:    case ttsErrorCount
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/QualityMetricTypes.swift:31:    case toolErrorCount
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/QualityMetricTypes.swift:46:        case .sttErrorCount, .llmErrorCount, .ttsErrorCount, .toolErrorCount:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/QualityMetricTypes.swift:63:        case .sttErrorCount, .llmErrorCount, .ttsErrorCount, .toolErrorCount:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/PipelineInstrumentation.swift:122:        case "stt": metric = .sttErrorCount
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Quality/PipelineInstrumentation.swift:123:        case "llm": metric = .llmErrorCount

## Sendable conformances in FaeInference:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:136:public struct LLMMessage: Sendable, Codable, Equatable {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:137:    public enum Role: String, Sendable, Codable {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:165:public enum LLMStreamEvent: Sendable {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:171:public struct GenerationOptions: Sendable {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:179:    /// Native tool specs for MLX tool calling (ToolSpec = `[String: any Sendable]`).
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:181:    public var tools: [[String: any Sendable]]?
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:221:        tools: [[String: any Sendable]]? = nil,
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/LLMShared.swift:248:public enum MLEngineLoadState: Sendable {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift:6:private final class UnsafeBox<T>: @unchecked Sendable {
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift:24:    private struct GenerationSetup: Sendable {

## Actor usage:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift:15:public actor MLXLLMEngine: LLMEngine {

## Good Patterns Found
- MLXLLMEngine correctly uses Swift actor for thread safety (no NSLock needed)
- MLEngineError used consistently for typed errors
- All async throws methods properly propagate errors
- UnsafeBox documented as intentional escape hatch

## Anti-Patterns / Concerns
- [CRITICAL] Plan spec for unloadAdapter uses force-unwrap 'self.currentAdapter!' — must use guard let when implementing
- [HIGH] Plan spec does NOT define a typed error for adapter loading failures. Must add MLAdapterError or extend MLEngineError with adapter-specific cases: .adapterNotFound, .adapterConfigMissing, .adapterIncompatible
- [MEDIUM] Plan Task 4 says guard 'must not be called during active generation' but gives no implementation detail. Need isGenerating flag or actor-level check.

## Grade: INCOMPLETE (existing patterns good; plan spec has anti-patterns to fix at implementation time)
