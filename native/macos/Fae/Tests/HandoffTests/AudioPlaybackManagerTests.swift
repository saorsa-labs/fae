import XCTest
@testable import Fae

final class AudioPlaybackManagerTests: XCTestCase {

    func testSetupConfiguresPlaybackGraphOnce() async throws {
        let playback = AudioPlaybackManager()

        try await playback.setup()
        try await playback.setup()

        let configurationCount = await playback.debugGraphConfigurationCount
        XCTAssertEqual(configurationCount, 1)
        await playback.stop()
    }
}
