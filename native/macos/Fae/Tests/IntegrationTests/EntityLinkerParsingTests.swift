import XCTest
import GRDB
@testable import Fae

/// Coverage for EntityLinker.swift (was 0% covered). extractFields,
/// extractEdges, and extractFirstName are pure string-parsing actor methods —
/// no DB, no network. Testing them covers the file's parsing core.
final class EntityLinkerParsingTests: XCTestCase {

    private func makeLinker() throws -> EntityLinker {
        let store = EntityStore(dbQueue: try DatabaseQueue())
        return EntityLinker(entityStore: store)
    }
    // MARK: - extractFields

    func testExtractFieldsDetectsRelationAndName() async throws {
        let linker = try makeLinker()
        let extraction = await linker.extractFields(from: "User knows: my sister Alice lives in Edinburgh")
        XCTAssertEqual(extraction.relationType, .family)
        XCTAssertEqual(extraction.relationLabel, "sister")
        XCTAssertNotNil(extraction.canonicalName)
    }

    func testExtractFieldsStripsUserKnowsPrefix() async throws {
        let linker = try makeLinker()
        let extraction = await linker.extractFields(from: "User knows: my brother Bob is a doctor")
        XCTAssertEqual(extraction.relationType, .family)
        XCTAssertEqual(extraction.relationLabel, "brother")
    }

    func testExtractFieldsRomanticRelation() async throws {
        let linker = try makeLinker()
        let extraction = await linker.extractFields(from: "my wife Carol")
        XCTAssertEqual(extraction.relationType, RelationType.romantic)
    }

    func testExtractFieldsColleagueRelation() async throws {
        let linker = try makeLinker()
        let extraction = await linker.extractFields(from: "my colleague Dave from work")
        XCTAssertEqual(extraction.relationType, RelationType.colleague)
    }

    func testExtractFieldsFriendRelation() async throws {
        let linker = try makeLinker()
        let extraction = await linker.extractFields(from: "my friend Eve")
        XCTAssertEqual(extraction.relationType, RelationType.friend)
    }

    func testExtractFieldsNoRelationDetected() async throws {
        let linker = try makeLinker()
        let extraction = await linker.extractFields(from: "A person named Frank")
        XCTAssertNil(extraction.relationType)
    }

    // MARK: - extractEdges

    func testExtractEdgesDetectsWorkplace() async throws {
        let linker = try makeLinker()
        let edges = await linker.extractEdges(from: "Alice works at Acme Corp")
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.relationType, "works_at")
        XCTAssertEqual(edges.first?.targetName, "Acme Corp")
        XCTAssertEqual(edges.first?.targetEntityType, .organisation)
    }

    func testExtractEdgesDetectsEmployedBy() async throws {
        let linker = try makeLinker()
        let edges = await linker.extractEdges(from: "Bob is employed by Globex Inc.")
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.targetName, "Globex Inc")
    }

    func testExtractEdgesDetectsLocation() async throws {
        let linker = try makeLinker()
        let edges = await linker.extractEdges(from: "Carol lives in Paris")
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.relationType, "lives_in")
        XCTAssertEqual(edges.first?.targetName, "Paris")
        XCTAssertEqual(edges.first?.targetEntityType, .location)
    }

    func testExtractEdgesMultiple() async throws {
        let linker = try makeLinker()
        let edges = await linker.extractEdges(from: "Dave works at Acme and lives in Berlin")
        XCTAssertGreaterThanOrEqual(edges.count, 2)
        XCTAssertTrue(edges.contains { $0.relationType == "works_at" })
        XCTAssertTrue(edges.contains { $0.relationType == "lives_in" })
    }

    func testExtractEdgesEmpty() async throws {
        let linker = try makeLinker()
        let edges = await linker.extractEdges(from: "Just a name with no edges")
        XCTAssertTrue(edges.isEmpty)
    }

    // MARK: - extractFirstName

    func testExtractFirstNameSimple() async throws {
        let linker = try makeLinker()
        let name = await linker.extractFirstName(from: "Alice Smith works at Acme")
        XCTAssertNotNil(name)
        XCTAssertTrue(name?.contains("Alice") ?? false)
    }

    func testExtractFirstNameStopsAtVerb() async throws {
        let linker = try makeLinker()
        // "works" is a stop-word — first name should be the capitalized tokens before it.
        let name = await linker.extractFirstName(from: "Bob works at Globex")
        XCTAssertEqual(name, "Bob")
    }

    func testExtractFirstNameEmpty() async throws {
        let linker = try makeLinker()
        let name = await linker.extractFirstName(from: "")
        XCTAssertNil(name)
    }

    func testExtractFirstNameLowercaseTakesLeadingWord() async throws {
        let linker = try makeLinker()
        // The first word is accepted even when lowercase (nameParts.isEmpty &&
        // first.isLetter); the next non-capitalised word stops extraction.
        let name = await linker.extractFirstName(from: "just some words here")
        XCTAssertEqual(name, "just")
    }
}
