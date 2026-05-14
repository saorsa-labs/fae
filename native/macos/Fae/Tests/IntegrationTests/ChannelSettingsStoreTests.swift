import XCTest
@testable import Fae

final class ChannelSettingsStoreTests: XCTestCase {

    // MARK: - normalizeChannelKey

    func testNormalizeChannelKeyDiscord() {
        let key = ChannelSettingsStore.normalizeChannelKey("discord")
        XCTAssertEqual(key, "discord")
    }

    func testNormalizeChannelKeyWhitespace() {
        let key = ChannelSettingsStore.normalizeChannelKey("  Discord  ")
        XCTAssertEqual(key, "discord")
    }

    // MARK: - normalizeFieldID

    func testNormalizeFieldID() {
        let id = ChannelSettingsStore.normalizeFieldID("Some_Field_ID")
        XCTAssertFalse(id.isEmpty)
    }

    // MARK: - parseList

    func testParseListValid() {
        let list = ChannelSettingsStore.parseList("item1, item2, item3")
        XCTAssertEqual(list.count, 3)
    }

    func testParseListEmpty() {
        let list = ChannelSettingsStore.parseList("")
        XCTAssertTrue(list.isEmpty)
    }

    func testParseListNil() {
        let list = ChannelSettingsStore.parseList(nil)
        XCTAssertTrue(list.isEmpty)
    }

    // MARK: - parsePort

    func testParsePortValid() {
        let port = ChannelSettingsStore.parsePort("8080")
        XCTAssertEqual(port, 8080)
    }

    func testParsePortInvalid() {
        let port = ChannelSettingsStore.parsePort("not-a-port")
        XCTAssertNil(port)
    }

    func testParsePortNil() {
        let port = ChannelSettingsStore.parsePort(nil)
        XCTAssertNil(port)
    }

    // MARK: - serialize

    func testSerializeString() {
        XCTAssertEqual(ChannelSettingsStore.serialize("hello"), "hello")
    }

    func testSerializeList() {
        let result = ChannelSettingsStore.serialize(["a", "b", "c"])
        XCTAssertEqual(result, "a,b,c")
    }

    func testSerializeEmptyString() {
        XCTAssertNil(ChannelSettingsStore.serialize("   "))
    }

    func testSerializeEmptyList() {
        XCTAssertNil(ChannelSettingsStore.serialize([] as [String]))
    }
}
