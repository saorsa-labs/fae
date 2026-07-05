import XCTest
@testable import Fae

// MARK: - UX W6: x0x contact exchange
//
// WHY these tests matter: a pasted x0x card is a ~20 KB blob. If it ever reaches
// the LLM it wastes context and risks leaking credential-shaped bytes. The
// interception + PasteRegistry contract is the safety boundary; the append-list
// action is the consent gate that turns an imported contact into an inbound peer.
// Each test encodes one of those invariants, not just mechanics.

final class X0xContactExchangeTests: XCTestCase {

    /// Mutable clock so TTL/cap behaviour is deterministic without sleeping.
    private final class Clock {
        var date: Date
        init(_ start: Date) { date = start }
    }

    private func makeRegistry(_ clock: Clock) -> (PasteRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-tests-\(UUID().uuidString)", isDirectory: true)
        let registry = PasteRegistry(spillDirectory: dir, now: { clock.date })
        return (registry, dir)
    }

    // MARK: PasteRegistry — store / resolve

    func testStoreAndResolveRoundTrips() async {
        let clock = Clock(Date())
        let (registry, dir) = makeRegistry(clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blob = "x0x://agent/" + String(repeating: "A", count: 20_000)
        let id = await registry.store(blob)
        let resolved = await registry.resolve(id)
        XCTAssertEqual(resolved, blob, "A stashed blob must round-trip byte-for-byte")
    }

    func testResolveUnknownIDReturnsNil() async {
        let clock = Clock(Date())
        let (registry, dir) = makeRegistry(clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = await registry.resolve("deadbeef")
        XCTAssertNil(missing, "An unknown id must not resolve to anything")
    }

    func testSpillPathPointsAtReadableFileWithContent() async throws {
        let clock = Clock(Date())
        let (registry, dir) = makeRegistry(clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blob = "x0x://agent/CARD_BYTES"
        let id = await registry.store(blob)
        let path = await registry.spillPath(id)
        let unwrapped = try XCTUnwrap(path, "A live entry must expose a spill-file path")
        let onDisk = try String(contentsOfFile: unwrapped, encoding: .utf8)
        XCTAssertEqual(onDisk, blob, "The spill file the skill reads must hold the real card")
    }

    // MARK: PasteRegistry — TTL

    func testEntryExpiresAfterTTL() async {
        let start = Date()
        let clock = Clock(start)
        let (registry, dir) = makeRegistry(clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = await registry.store("x0x://agent/EXPIRES")
        clock.date = start.addingTimeInterval(PasteRegistry.ttl + 60) // past 24h
        let resolved = await registry.resolve(id)
        XCTAssertNil(resolved, "An entry older than the TTL must not resolve")
        let path = await registry.spillPath(id)
        XCTAssertNil(path, "An expired entry must not expose a spill path")
    }

    // MARK: PasteRegistry — cap

    func testCapEvictsOldestEntries() async {
        let start = Date()
        let clock = Clock(start)
        let (registry, dir) = makeRegistry(clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        var ids: [String] = []
        for i in 0..<(PasteRegistry.maxEntries + 3) {
            clock.date = start.addingTimeInterval(Double(i)) // strictly increasing ages
            ids.append(await registry.store("card-\(i)"))
        }
        let count = await registry.liveCount()
        XCTAssertEqual(count, PasteRegistry.maxEntries, "Live entries must be capped")

        // The three oldest ids are evicted; the newest survives.
        let oldest = await registry.resolve(ids[0])
        XCTAssertNil(oldest, "The oldest paste must be evicted when over cap")
        let newest = await registry.resolve(ids.last!)
        XCTAssertNotNil(newest, "The newest paste must survive eviction")
    }

    // MARK: reference / id parsing (the card_ref mechanism)

    func testReferenceRoundTrip() {
        let ref = PasteRegistry.reference(for: "abc123def456")
        XCTAssertEqual(ref, "paste:abc123def456")
        XCTAssertEqual(PasteRegistry.id(fromReference: ref), "abc123def456")
    }

    func testIDFromReferenceRejectsNonReferences() {
        XCTAssertNil(PasteRegistry.id(fromReference: "not a ref"))
        XCTAssertNil(PasteRegistry.id(fromReference: "paste:"), "Empty id is invalid")
        XCTAssertNil(
            PasteRegistry.id(fromReference: "paste:has spaces"),
            "An id with disallowed characters must be rejected")
        XCTAssertEqual(
            PasteRegistry.id(fromReference: "  paste:trim_me  "), "trim_me",
            "Surrounding whitespace is tolerated")
    }

    // MARK: interception — detectX0xCard

    func testDetectsBareCardLink() {
        let link = "x0x://agent/" + String(repeating: "b", count: 500)
        XCTAssertEqual(
            PipelineCoordinator.detectX0xCard(in: link), link,
            "A bare pasted card must be detected so the blob never reaches the LLM")
    }

    func testDetectsCardWithShortSurroundingText() {
        let link = "x0x://agent/CARDDATA123"
        let pasted = "here's my card: \(link)"
        XCTAssertEqual(
            PipelineCoordinator.detectX0xCard(in: pasted), link,
            "A card wrapped in <=40 chars of chatter is still a card")
    }

    func testNormalTextIsNotDetectedAsCard() {
        XCTAssertNil(
            PipelineCoordinator.detectX0xCard(in: "What's the weather in Glasgow today?"),
            "Ordinary prose must pass through untouched")
    }

    func testProseMentioningCardAmidLotsOfTextIsNotIntercepted() {
        // A long message that merely references a link should reach the LLM as-is,
        // otherwise real conversation gets swallowed.
        let link = "x0x://agent/SHORTID"
        let longPrefix = String(repeating: "please remember to ", count: 5) // >40 chars
        let text = longPrefix + link + " thanks so much for helping me out here"
        XCTAssertNil(
            PipelineCoordinator.detectX0xCard(in: text),
            "A link buried in long prose is not a bare card paste")
    }

    func testTwoLinksAreNotTreatedAsASingleCard() {
        let text = "x0x://agent/AAA and x0x://agent/BBB"
        XCTAssertNil(
            PipelineCoordinator.detectX0xCard(in: text),
            "Exactly one link is required to treat a paste as a card")
    }

    // MARK: SelfConfigTool — append_list_value validation (the consent gate)

    func testIsHex64Validation() {
        XCTAssertTrue(SelfConfigTool.isHex64(String(repeating: "a", count: 64)))
        XCTAssertTrue(SelfConfigTool.isHex64(String(repeating: "0", count: 64)))
        XCTAssertFalse(SelfConfigTool.isHex64(String(repeating: "a", count: 63)), "Too short")
        XCTAssertFalse(SelfConfigTool.isHex64(String(repeating: "g", count: 64)), "Non-hex char")
        XCTAssertFalse(
            SelfConfigTool.isHex64(String(repeating: "A", count: 64)),
            "Uppercase is not the canonical lowercased agent id")
    }

    func testAppendableListKeysAreOnlyX0xLists() {
        XCTAssertEqual(SelfConfigTool.appendableListKeys, ["x0x.allowList", "x0x.ownerFleet"])
    }

    func testAppendListValueRejectsForeignKey() async throws {
        let tool = SelfConfigTool()
        let result = try await tool.execute(input: [
            "action": "append_list_value",
            "key": "llm.temperature",
            "value": String(repeating: "a", count: 64),
        ])
        XCTAssertTrue(result.isError, "A non-x0x key must be rejected, got \(result.output)")
        XCTAssertTrue(result.output.contains("x0x."), "Error must name the allowed keys")
    }

    func testAppendListValueRejectsInvalidAgentID() async throws {
        let tool = SelfConfigTool()
        let result = try await tool.execute(input: [
            "action": "append_list_value",
            "key": "x0x.allowList",
            "value": "not-an-agent-id",
        ])
        XCTAssertTrue(result.isError, "An invalid agent id must be rejected, got \(result.output)")
    }

    func testAppendListValueAcceptsValidAgentID() async throws {
        let tool = SelfConfigTool()
        let agentID = String(repeating: "a", count: 64)
        let result = try await tool.execute(input: [
            "action": "append_list_value",
            "key": "x0x.allowList",
            "value": agentID,
        ])
        XCTAssertFalse(result.isError, "A valid append must succeed, got \(result.output)")
        XCTAssertTrue(
            result.output.contains("x0x.allowList"), "Success must confirm the target list")
    }
}
