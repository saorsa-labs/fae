import XCTest
@testable import Fae

final class SelfDiagnosticSkillTests: XCTestCase {

    // MARK: - Voice Command Parsing

    func testDiagnoseCommandParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("diagnose"), .runDiagnostics)
    }

    func testRunDiagnosticsCommandParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("run diagnostics"), .runDiagnostics)
    }

    func testRunDiagnosticSingularParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("run diagnostic"), .runDiagnostics)
    }

    func testHealthCheckCommandParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("health check"), .runDiagnostics)
    }

    func testHowAreYouDoingParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("how are you doing"), .runDiagnostics)
    }

    func testAreYouWorkingParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("are you working"), .runDiagnostics)
    }

    func testDiagnoseYourselfParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("diagnose yourself"), .runDiagnostics)
    }

    func testSelfDiagnosticParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("self diagnostic"), .runDiagnostics)
    }

    func testSystemCheckParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("system check"), .runDiagnostics)
    }

    func testCheckYourselfParsed() {
        XCTAssertEqual(VoiceCommandParser.parse("check yourself"), .runDiagnostics)
    }

    func testLongDiagnoseTextNotParsed() {
        // "diagnose" in a long sentence about something else should not trigger
        // (>40 chars threshold for bare "diagnose")
        let result = VoiceCommandParser.parse("Can you diagnose the problem with the server configuration?")
        XCTAssertEqual(result, .none)
    }

    func testShortDiagnoseParsed() {
        // Short "diagnose this" should still trigger (< 40 chars)
        let result = VoiceCommandParser.parse("Fae diagnose this")
        XCTAssertEqual(result, .runDiagnostics)
    }

    // MARK: - Skill Discovery

    func testSelfDiagnosticSkillExists() async {
        let manager = SkillManager()
        let metadata = await manager.promptMetadata()
        let hasSelfDiagnostic = metadata.contains { $0.name == "self-diagnostic" }
        XCTAssertTrue(hasSelfDiagnostic, "self-diagnostic skill should be discoverable in prompt metadata")
    }

    func testSelfDiagnosticSkillActivates() async {
        let manager = SkillManager()
        let body = await manager.activate(skillName: "self-diagnostic")
        XCTAssertNotNil(body, "self-diagnostic skill should activate successfully")
        XCTAssertTrue(body?.contains("Self-Diagnostic") ?? false, "Activated body should contain skill title")
    }

    func testSelfDiagnosticSkillDeactivates() async {
        let manager = SkillManager()
        _ = await manager.activate(skillName: "self-diagnostic")
        await manager.deactivate(skillName: "self-diagnostic")
        let names = await manager.activatedSkillNames()
        XCTAssertFalse(names.contains("self-diagnostic"), "Skill should be deactivated after deactivate()")
    }

    // MARK: - Non-Interference

    func testDiagnosticsDoesNotConflictWithOtherCommands() {
        // Ensure other commands still work.
        XCTAssertEqual(VoiceCommandParser.parse("open settings"), .showSettings)
        XCTAssertEqual(VoiceCommandParser.parse("enable thinking mode"), .setThinking(true))
        XCTAssertEqual(VoiceCommandParser.parse("request camera permission"), .requestPermission("camera"))
    }
}
