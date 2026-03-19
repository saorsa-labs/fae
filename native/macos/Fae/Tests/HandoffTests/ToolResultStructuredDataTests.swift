import XCTest
@testable import Fae

/// Tests for the structured tool result primitives introduced in Phase 2.1.
///
/// Validates that:
/// - Existing prose-only `ToolResult` flows are unaffected.
/// - Structured data can be attached and serialised.
/// - The script envelope combines prose + structured data for JSC callers.
/// - Edge cases (nil data, invalid JSON, special characters) are handled gracefully.
final class ToolResultStructuredDataTests: XCTestCase {

    // MARK: - Prose-Only (Backward Compatibility)

    func testProseOnlySuccessHasNilStructuredData() {
        let result = ToolResult.success("File contents here")
        XCTAssertEqual(result.output, "File contents here")
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.structuredData)
    }

    func testProseOnlyErrorHasNilStructuredData() {
        let result = ToolResult.error("Something went wrong")
        XCTAssertEqual(result.output, "Something went wrong")
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.structuredData)
    }

    func testProseOnlySerialiseStructuredDataReturnsNil() {
        let result = ToolResult.success("hello")
        XCTAssertNil(result.serialiseStructuredData())
    }

    // MARK: - Structured Data

    func testSuccessWithStructuredData() {
        let data: [String: any Sendable] = ["count": 42, "name": "test"]
        let result = ToolResult.success("Found 42 items", structuredData: data)

        XCTAssertEqual(result.output, "Found 42 items")
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.structuredData)
        XCTAssertEqual(result.structuredData?["count"] as? Int, 42)
        XCTAssertEqual(result.structuredData?["name"] as? String, "test")
    }

    func testInitWithStructuredData() {
        let data: [String: any Sendable] = ["key": "value"]
        let result = ToolResult(output: "ok", isError: false, structuredData: data)

        XCTAssertEqual(result.output, "ok")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structuredData?["key"] as? String, "value")
    }

    // MARK: - Serialisation

    func testSerialiseStructuredDataProducesValidJSON() throws {
        let data: [String: any Sendable] = ["count": 3, "label": "test"]
        let result = ToolResult.success("ok", structuredData: data)

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(json.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(parsed["count"] as? Int, 3)
        XCTAssertEqual(parsed["label"] as? String, "test")
    }

    func testSerialiseStructuredDataWithNestedObject() throws {
        let nested: [String: any Sendable] = ["x": 1, "y": 2]
        let data: [String: any Sendable] = ["point": nested, "label": "origin"]
        let result = ToolResult.success("ok", structuredData: data)

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(json.utf8)
            ) as? [String: Any]
        )
        let point = try XCTUnwrap(parsed["point"] as? [String: Any])
        XCTAssertEqual(point["x"] as? Int, 1)
        XCTAssertEqual(point["y"] as? Int, 2)
    }

    func testSerialiseStructuredDataWithArray() throws {
        let items: [any Sendable] = ["a", "b", "c"]
        let data: [String: any Sendable] = ["items": items]
        let result = ToolResult.success("ok", structuredData: data)

        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(json.utf8)
            ) as? [String: Any]
        )
        let parsedItems = try XCTUnwrap(parsed["items"] as? [String])
        XCTAssertEqual(parsedItems, ["a", "b", "c"])
    }

    func testSerialiseUsesStableSortedKeys() throws {
        let data: [String: any Sendable] = ["z": 1, "a": 2, "m": 3]
        let result = ToolResult.success("ok", structuredData: data)

        let json = try XCTUnwrap(result.serialiseStructuredData())
        // With .sortedKeys, "a" should appear before "m" before "z".
        let aIdx = try XCTUnwrap(json.range(of: "\"a\""))
        let mIdx = try XCTUnwrap(json.range(of: "\"m\""))
        let zIdx = try XCTUnwrap(json.range(of: "\"z\""))
        XCTAssertTrue(aIdx.lowerBound < mIdx.lowerBound)
        XCTAssertTrue(mIdx.lowerBound < zIdx.lowerBound)
    }

    // MARK: - Script Envelope

    func testScriptEnvelopeProseOnly() throws {
        let result = ToolResult.success("hello world")
        let envelope = result.scriptEnvelope()

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(envelope.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(parsed["output"] as? String, "hello world")
        XCTAssertEqual(parsed["isError"] as? Bool, false)
        // No "data" key when structuredData is nil.
        XCTAssertNil(parsed["data"])
    }

    func testScriptEnvelopeWithStructuredData() throws {
        let data: [String: any Sendable] = ["count": 5, "items": ["a", "b"] as [any Sendable]]
        let result = ToolResult.success("Found 5 items", structuredData: data)
        let envelope = result.scriptEnvelope()

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(envelope.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(parsed["output"] as? String, "Found 5 items")
        XCTAssertEqual(parsed["isError"] as? Bool, false)
        let envelopeData = try XCTUnwrap(parsed["data"] as? [String: Any])
        XCTAssertEqual(envelopeData["count"] as? Int, 5)
    }

    func testScriptEnvelopeForError() throws {
        let result = ToolResult.error("not found")
        let envelope = result.scriptEnvelope()

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(envelope.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(parsed["output"] as? String, "not found")
        XCTAssertEqual(parsed["isError"] as? Bool, true)
    }

    func testScriptEnvelopeWithSpecialCharacters() throws {
        let result = ToolResult.success("line1\nline2\ttab \"quoted\"")
        let envelope = result.scriptEnvelope()

        // Must be valid JSON.
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(envelope.utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(parsed["output"] as? String, "line1\nline2\ttab \"quoted\"")
    }

    // MARK: - Both Prose and Structured (Dual Path)

    func testToolReturningBothProseAndStructuredData() throws {
        // Simulates a tool that produces prose for LLM and structured data for scripts.
        let structured: [String: any Sendable] = [
            "events": [
                ["title": "Meeting", "time": "10:00"] as [String: any Sendable],
                ["title": "Lunch", "time": "12:30"] as [String: any Sendable],
            ] as [any Sendable],
        ]
        let prose = "You have 2 events today: Meeting at 10:00 and Lunch at 12:30."
        let result = ToolResult.success(prose, structuredData: structured)

        // LLM path: reads .output
        XCTAssertEqual(result.output, prose)

        // Script path: reads structured data
        let json = try XCTUnwrap(result.serialiseStructuredData())
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let events = try XCTUnwrap(parsed["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["title"] as? String, "Meeting")

        // Script envelope: both
        let envelope = result.scriptEnvelope()
        let envParsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        )
        XCTAssertEqual(envParsed["output"] as? String, prose)
        XCTAssertNotNil(envParsed["data"])
    }

    // MARK: - Edge Cases

    func testEmptyStructuredData() throws {
        let result = ToolResult.success("ok", structuredData: [:])

        // Empty dict is still valid JSON.
        let json = try XCTUnwrap(result.serialiseStructuredData())
        XCTAssertEqual(json, "{}")

        let envelope = result.scriptEnvelope()
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        )
        let envelopeData = try XCTUnwrap(parsed["data"] as? [String: Any])
        XCTAssertTrue(envelopeData.isEmpty)
    }

    func testEmptyOutput() throws {
        let result = ToolResult.success("")
        let envelope = result.scriptEnvelope()
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["output"] as? String, "")
    }

    func testDefaultInitPreservesBackwardCompat() {
        // The default init with just output + isError should still work.
        let result = ToolResult(output: "test", isError: false)
        XCTAssertNil(result.structuredData)
        XCTAssertNil(result.serialiseStructuredData())
    }

    func testSuccessFactoryPreservesBackwardCompat() {
        // Single-arg .success() should produce nil structured data.
        let result = ToolResult.success("test")
        XCTAssertNil(result.structuredData)
    }

    func testErrorFactoryPreservesBackwardCompat() {
        let result = ToolResult.error("fail")
        XCTAssertNil(result.structuredData)
        XCTAssertTrue(result.isError)
    }
}
