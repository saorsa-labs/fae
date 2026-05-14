import XCTest
@testable import Fae

final class WorkflowTraceStoreStaticTests: XCTestCase {

    // MARK: - newID

    func testNewId() {
        let id = WorkflowTraceStore.newID(prefix: "run")
        XCTAssertTrue(id.hasPrefix("run_"))
    }

    // MARK: - unixTimestamp

    func testUnixTimestamp() {
        let date = Date(timeIntervalSince1970: 1609459200)
        let ts = WorkflowTraceStore.unixTimestamp(date)
        XCTAssertEqual(ts, 1609459200)
    }

    // MARK: - trimmed

    func testTrimmed() {
        let result = WorkflowTraceStore.trimmed("  hello world  ", limit: 5)
        XCTAssertEqual(result, "hello")
    }

    func testTrimmedNoLimit() {
        let result = WorkflowTraceStore.trimmed("hello", limit: 100)
        XCTAssertEqual(result, "hello")
    }

    // MARK: - redactedAndTrimmed

    func testRedactedAndTrimmed() {
        let result = WorkflowTraceStore.redactedAndTrimmed("  secret: abc123  ", limit: 10)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - optionalTrimmed

    func testOptionalTrimmedNil() {
        XCTAssertNil(WorkflowTraceStore.optionalTrimmed(nil, limit: 10))
    }

    func testOptionalTrimmedValue() {
        let result = WorkflowTraceStore.optionalTrimmed("hello", limit: 3)
        XCTAssertEqual(result, "hel")
    }

    // MARK: - optionalRedactedAndTrimmed

    func testOptionalRedactedAndTrimmedNil() {
        XCTAssertNil(WorkflowTraceStore.optionalRedactedAndTrimmed(nil, limit: 10))
    }

    func testOptionalRedactedAndTrimmedValue() {
        let result = WorkflowTraceStore.optionalRedactedAndTrimmed("hello", limit: 3)
        XCTAssertEqual(result, "hel")
    }

    // MARK: - optionalInt

    func testOptionalIntTrue() {
        XCTAssertEqual(WorkflowTraceStore.optionalInt(true), 1)
    }

    func testOptionalIntFalse() {
        XCTAssertEqual(WorkflowTraceStore.optionalInt(false), 0)
    }

    func testOptionalIntNil() {
        XCTAssertNil(WorkflowTraceStore.optionalInt(nil))
    }
}
