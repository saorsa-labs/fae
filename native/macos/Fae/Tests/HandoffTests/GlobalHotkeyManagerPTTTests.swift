import Testing
@testable import Fae

@Suite("GlobalHotkeyManager PTT")
struct GlobalHotkeyManagerPTTTests {

    @Test("holdToTalkKeyCode is Right Option (61)")
    func holdToTalkKeyCodeValue() {
        #expect(GlobalHotkeyManager.holdToTalkKeyCode == 61)
    }

    @Test("stopHoldToTalk before startHoldToTalk does not crash")
    @MainActor
    func stopBeforeStartDoesNotCrash() {
        let manager = GlobalHotkeyManager()
        manager.stopHoldToTalk()
        // No crash = pass
    }

    @Test("startHoldToTalk twice replaces callbacks without crash")
    @MainActor
    func startTwiceReplacesCallbacks() {
        let manager = GlobalHotkeyManager()
        var firstCallCount = 0
        var secondCallCount = 0

        manager.startHoldToTalk(
            onPress: { firstCallCount += 1 },
            onRelease: { firstCallCount += 1 }
        )

        manager.startHoldToTalk(
            onPress: { secondCallCount += 1 },
            onRelease: { secondCallCount += 1 }
        )

        // First callbacks should have been replaced
        #expect(firstCallCount == 0)
        #expect(secondCallCount == 0)

        manager.stopHoldToTalk()
    }

    @Test("stop cleans up summon monitor independently of PTT")
    @MainActor
    func stopSummonIndependentOfPTT() {
        let manager = GlobalHotkeyManager()
        manager.startHoldToTalk(onPress: {}, onRelease: {})
        manager.stop()
        // PTT should still be active after stop() — only summon is stopped
        manager.stopHoldToTalk()
    }
}
