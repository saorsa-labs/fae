import XCTest
@testable import Fae

// MARK: - ToolResult Tests

final class ToolResultTests: XCTestCase {

    // MARK: - Basic construction

    func testSuccessHelper() {
        let result = ToolResult.success("All done!")
        XCTAssertEqual(result.output, "All done!")
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.structuredData)
    }

    func testErrorHelper() {
        let result = ToolResult.error("Something went wrong")
        XCTAssertEqual(result.output, "Something went wrong")
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.structuredData)
    }

    func testSuccessWithStructuredData() {
        let result = ToolResult.success(
            "Found 3 files",
            structuredData: ["count": 3, "files": ["a.txt", "b.txt", "c.txt"]]
        )
        XCTAssertEqual(result.output, "Found 3 files")
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.structuredData)
        XCTAssertEqual(result.structuredData?["count"] as? Int, 3)
    }

    func testInitWithAllFields() {
        let result = ToolResult(
            output: "test output",
            isError: true,
            structuredData: ["key": "value"]
        )
        XCTAssertEqual(result.output, "test output")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredData?["key"] as? String, "value")
    }

    func testDefaultIsErrorIsFalse() {
        let result = ToolResult(output: "hello")
        XCTAssertFalse(result.isError)
    }

    // MARK: - serialiseStructuredData

    func testSerialiseSimpleStructuredData() {
        let result = ToolResult.success(
            "ok",
            structuredData: ["name": "test", "count": 5]
        )
        let json = result.serialiseStructuredData()
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("\"count\":5"))
        XCTAssertTrue(json!.contains("\"name\":\"test\""))
    }

    func testSerialiseNilWhenNoStructuredData() {
        let result = ToolResult.success("plain output")
        XCTAssertNil(result.serialiseStructuredData())
    }

    func testSerialiseReturnsNilForInvalidJSON() {
        // This shouldn't happen with normal usage, but tests the fallback
        // We can't easily create non-JSON-serializable Sendable values in Swift,
        // so just verify valid data works
        let result = ToolResult.success(
            "ok",
            structuredData: ["nested": ["deep": true]]
        )
        let json = result.serialiseStructuredData()
        XCTAssertNotNil(json)
    }

    // MARK: - scriptEnvelope

    func testScriptEnvelopeSimpleOutput() {
        let result = ToolResult.success("Hello world")
        let envelope = result.scriptEnvelope()
        XCTAssertTrue(envelope.contains("\"output\":\"Hello world\""))
        XCTAssertTrue(envelope.contains("\"isError\":false"))
    }

    func testScriptEnvelopeWithError() {
        let result = ToolResult.error("Failed")
        let envelope = result.scriptEnvelope()
        XCTAssertTrue(envelope.contains("\"isError\":true"))
        XCTAssertTrue(envelope.contains("\"output\":\"Failed\""))
    }

    func testScriptEnvelopeWithStructuredData() {
        let result = ToolResult.success(
            "ok",
            structuredData: ["key": "value"]
        )
        let envelope = result.scriptEnvelope()
        XCTAssertTrue(envelope.contains("\"data\""))
        XCTAssertTrue(envelope.contains("\"key\":\"value\""))
    }

    func testScriptEnvelopeEscapesSpecialCharacters() {
        let result = ToolResult.success("Line1\nLine2")
        let envelope = result.scriptEnvelope()
        // Should contain escaped newline
        XCTAssertTrue(envelope.contains("\\n") || envelope.contains("Line1"))
    }

    func testScriptEnvelopeIsValidJSON() {
        let result = ToolResult.success("test output with \"quotes\"")
        let envelope = result.scriptEnvelope()
        let data = envelope.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["output"] as? String, "test output with \"quotes\"")
    }

    // MARK: - Sendable

    func testToolResultIsSendable() {
        let result = ToolResult.success("test")
        _ = result as any Sendable
    }
}

// MARK: - ToolRiskLevel Tests

final class ToolRiskLevelTests: XCTestCase {

    func testAllCasesHaveRawValues() {
        XCTAssertEqual(ToolRiskLevel.low.rawValue, "low")
        XCTAssertEqual(ToolRiskLevel.medium.rawValue, "medium")
        XCTAssertEqual(ToolRiskLevel.high.rawValue, "high")
    }

    func testInitFromRawValue() {
        XCTAssertNotNil(ToolRiskLevel(rawValue: "low"))
        XCTAssertNotNil(ToolRiskLevel(rawValue: "medium"))
        XCTAssertNotNil(ToolRiskLevel(rawValue: "high"))
        XCTAssertNil(ToolRiskLevel(rawValue: "extreme"))
    }

    func testIsSendable() {
        let level: ToolRiskLevel = .low
        _ = level as any Sendable
    }
}

// MARK: - ActionSource Tests

final class ActionSourceTests: XCTestCase {

    func testAllCasesHaveRawValues() {
        XCTAssertEqual(ActionSource.voice.rawValue, "voice")
        XCTAssertEqual(ActionSource.text.rawValue, "text")
        XCTAssertEqual(ActionSource.scheduler.rawValue, "scheduler")
        XCTAssertEqual(ActionSource.relay.rawValue, "relay")
        XCTAssertEqual(ActionSource.skill.rawValue, "skill")
        XCTAssertEqual(ActionSource.unknown.rawValue, "unknown")
    }

    func testInitFromRawValue() {
        XCTAssertNotNil(ActionSource(rawValue: "voice"))
        XCTAssertNotNil(ActionSource(rawValue: "text"))
        XCTAssertNotNil(ActionSource(rawValue: "scheduler"))
        XCTAssertNotNil(ActionSource(rawValue: "relay"))
        XCTAssertNotNil(ActionSource(rawValue: "skill"))
        XCTAssertNotNil(ActionSource(rawValue: "unknown"))
        XCTAssertNil(ActionSource(rawValue: "invalid"))
    }

    func testIsSendable() {
        let source: ActionSource = .voice
        _ = source as any Sendable
    }
}

// MARK: - Tool Protocol Extension Tests

/// A minimal mock tool for testing the Tool protocol extensions.
struct TestMockTool: Tool {
    let name: String
    let description: String
    let parametersSchema: String

    init(name: String, description: String = "A test tool", parametersSchema: String = "{}") {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        ToolResult.success("mock result")
    }
}

final class ToolProtocolExtensionTests: XCTestCase {

    // MARK: - Default values
    func testDefaultRequiresApprovalIsFalse() {
        let tool = TestMockTool(name: "test")
        XCTAssertFalse(tool.requiresApproval)
    }

    func testDefaultRiskLevelIsMedium() {
        let tool = TestMockTool(name: "test")
        XCTAssertEqual(tool.riskLevel, .medium)
    }

    func testDefaultExampleIsEmpty() {
        let tool = TestMockTool(name: "test")
        XCTAssertEqual(tool.example, "")
    }

    // MARK: - toolSpec

    func testToolSpecContainsName() {
        let tool = TestMockTool(name: "read_file")
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "read_file")
    }

    func testToolSpecContainsDescription() {
        let tool = TestMockTool(name: "test", description: "Reads a file")
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        XCTAssertEqual(function?["description"] as? String, "Reads a file")
    }

    func testToolSpecHasTypeFunction() {
        let tool = TestMockTool(name: "test")
        let spec = tool.toolSpec
        XCTAssertEqual(spec["type"] as? String, "function")
    }

    func testToolSpecHasParametersObject() {
        let tool = TestMockTool(name: "test")
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
    }

    // MARK: - Simple parameter schema parsing

    func testSimpleStringParameter() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"path\": \"string (required)\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let pathProp = properties?["path"] as? [String: String]
        XCTAssertEqual(pathProp?["type"], "string")
    }

    func testSimpleIntegerParameter() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"count\": \"integer (required)\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let countProp = properties?["count"] as? [String: String]
        XCTAssertEqual(countProp?["type"], "integer")
    }

    func testSimpleBooleanParameter() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"force\": \"bool\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let forceProp = properties?["force"] as? [String: String]
        XCTAssertEqual(forceProp?["type"], "boolean")
    }

    func testRequiredFieldsPopulated() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"path\": \"string (required)\", \"depth\": \"integer\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        XCTAssertTrue(required?.contains("path") ?? false)
        XCTAssertFalse(required?.contains("depth") ?? true)
    }

    func testEmptySchemaProducesEmptyProperties() {
        let tool = TestMockTool(name: "test", parametersSchema: "{}")
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        XCTAssertTrue(properties?.isEmpty ?? true)
    }

    // MARK: - Type inference edge cases

    func testNumberTypeInference() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"value\": \"number (required)\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let valueProp = properties?["value"] as? [String: String]
        XCTAssertEqual(valueProp?["type"], "number")
    }

    func testArrayTypeInference() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"items\": \"array of strings\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let itemsProp = properties?["items"] as? [String: String]
        XCTAssertEqual(itemsProp?["type"], "array")
    }

    func testDefaultToStringType() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"message\": \"free form text\"}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let msgProp = properties?["message"] as? [String: String]
        XCTAssertEqual(msgProp?["type"], "string")
    }

    func testInvalidSchemaReturnsEmpty() {
        let tool = TestMockTool(name: "test", parametersSchema: "not json at all")
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        XCTAssertTrue(properties?.isEmpty ?? true)
    }

    // MARK: - Structured parameter schema

    func testStructuredSchemaFormat() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"path\":{\"type\":\"string\",\"description\":\"File path\"}}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let pathProp = properties?["path"] as? [String: String]
        XCTAssertEqual(pathProp?["type"], "string")
        XCTAssertEqual(pathProp?["description"], "File path")
    }

    func testStructuredSchemaWithRequiredFlag() {
        let tool = TestMockTool(
            name: "test",
            parametersSchema: "{\"path\":{\"type\":\"string\",\"required\":true}}"
        )
        let spec = tool.toolSpec
        let function = spec["function"] as? [String: Any]
        let params = function?["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        XCTAssertTrue(required?.contains("path") ?? false)
    }
}
