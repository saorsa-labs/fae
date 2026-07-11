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

    @Test("Shift then Right Option toggles once without PTT")
    func shiftThenRightOptionTogglesOnceWithoutPTT() {
        var state = RightOptionChordState()

        #expect(state.shiftChanged(isDown: true) == [])
        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: true) == [.toggleVisibility])
        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: true) == [])
        #expect(state.pttDelayElapsed() == [])
        #expect(state.rightOptionChanged(isDown: false, shiftIsDown: true) == [])
        #expect(state.shiftChanged(isDown: false) == [])
    }

    @Test("Right Option then Shift cancels pending PTT and toggles once")
    func shiftDuringPendingPTTCancelsAndTogglesOnce() {
        var state = RightOptionChordState()

        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: false) == [.schedulePTT])
        #expect(state.shiftChanged(isDown: true) == [.cancelScheduledPTT, .toggleVisibility])
        #expect(state.shiftChanged(isDown: true) == [])
        #expect(state.pttDelayElapsed() == [])
        #expect(state.rightOptionChanged(isDown: false, shiftIsDown: true) == [])
    }

    @Test("Right Option alone schedules presses after delay and releases")
    func rightOptionAloneRunsDelayedPTTLifecycle() {
        var state = RightOptionChordState()

        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: false) == [.schedulePTT])
        #expect(state.pttDelayElapsed() == [.pressPTT])
        #expect(state.rightOptionChanged(isDown: false, shiftIsDown: false) == [.releasePTT])
    }

    @Test("Right Option released before delay retains PTT semantics")
    func rightOptionReleasedBeforeDelayRetainsPTTSemantics() {
        var state = RightOptionChordState()

        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: false) == [.schedulePTT])
        #expect(
            state.rightOptionChanged(isDown: false, shiftIsDown: false)
                == [.cancelScheduledPTT, .pressPTT, .releasePTT]
        )
        #expect(state.pttDelayElapsed() == [])
    }

    @Test("Shift after active PTT does not toggle and release still fires")
    func shiftAfterActivePTTDoesNotToggle() {
        var state = RightOptionChordState()

        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: false) == [.schedulePTT])
        #expect(state.pttDelayElapsed() == [.pressPTT])
        #expect(state.shiftChanged(isDown: true) == [])
        #expect(state.rightOptionChanged(isDown: false, shiftIsDown: true) == [.releasePTT])
    }

    @Test("Repeated held events do not duplicate actions")
    func repeatedHeldEventsDoNotDuplicateActions() {
        var chordState = RightOptionChordState()

        #expect(chordState.shiftChanged(isDown: true) == [])
        #expect(chordState.rightOptionChanged(isDown: true, shiftIsDown: true) == [.toggleVisibility])
        #expect(chordState.shiftChanged(isDown: true) == [])
        #expect(chordState.rightOptionChanged(isDown: true, shiftIsDown: true) == [])
        #expect(chordState.rightOptionChanged(isDown: false, shiftIsDown: true) == [])
        #expect(chordState.rightOptionChanged(isDown: false, shiftIsDown: true) == [])

        var pttState = RightOptionChordState()
        #expect(pttState.rightOptionChanged(isDown: true, shiftIsDown: false) == [.schedulePTT])
        #expect(pttState.rightOptionChanged(isDown: true, shiftIsDown: false) == [])
        #expect(pttState.pttDelayElapsed() == [.pressPTT])
        #expect(pttState.pttDelayElapsed() == [])
        #expect(pttState.rightOptionChanged(isDown: false, shiftIsDown: false) == [.releasePTT])
        #expect(pttState.rightOptionChanged(isDown: false, shiftIsDown: false) == [])
    }

    @Test("Right Option visibility chord remains available when PTT is disabled")
    func rightOptionVisibilityChordRemainsAvailableWhenPTTIsDisabled() {
        var state = RightOptionChordState(pttEnabled: false)

        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: false) == [])
        #expect(state.shiftChanged(isDown: true) == [.toggleVisibility])
        #expect(state.shiftChanged(isDown: true) == [])
        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: true) == [])
        #expect(state.rightOptionChanged(isDown: false, shiftIsDown: true) == [])
        #expect(state.shiftChanged(isDown: false) == [])

        #expect(state.shiftChanged(isDown: true) == [])
        #expect(state.rightOptionChanged(isDown: true, shiftIsDown: true) == [.toggleVisibility])
    }
}
