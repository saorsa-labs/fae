import Testing
@testable import Fae

@Suite("ShadowWakeWordEvaluator")
struct ShadowWakeWordEvaluatorTests {

    @Test("Initial state: not promoted, zero attempts")
    func initialState() async {
        let e = ShadowWakeWordEvaluator()
        #expect(await e.isPromoted == false)
        #expect(await e.totalAttempts == 0)
        #expect(await e.isPaused == false)
    }

    @Test("Results ignored while paused")
    func pausedIgnoresResults() async {
        let e = ShadowWakeWordEvaluator()
        await e.pause()
        for _ in 0..<50 { await e.recordResult(acousticDetected: true, textDetected: true) }
        #expect(await e.totalAttempts == 0)
    }

    @Test("Resume allows recording")
    func resumeAllows() async {
        let e = ShadowWakeWordEvaluator()
        await e.pause()
        await e.resume()
        await e.recordResult(acousticDetected: true, textDetected: true)
        #expect(await e.totalAttempts == 1)
    }

    @Test("Pause/resume toggle")
    func pauseResumeToggle() async {
        let e = ShadowWakeWordEvaluator()
        await e.pause()
        #expect(await e.isPaused == true)
        await e.resume()
        #expect(await e.isPaused == false)
    }

    @Test("No promotion before 200 attempts")
    func noEarlyPromotion() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<199 { await e.recordResult(acousticDetected: true, textDetected: true) }
        #expect(await e.isPromoted == false)
    }

    @Test("Promotion after 200 perfect attempts")
    func promotionAfterMinAttempts() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<200 { await e.recordResult(acousticDetected: true, textDetected: true) }
        #expect(await e.isPromoted == true)
    }

    @Test("No promotion when FP rate too high")
    func noPromotionHighFP() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<5 { await e.recordResult(acousticDetected: true, textDetected: false) }
        for _ in 0..<195 { await e.recordResult(acousticDetected: false, textDetected: false) }
        #expect(await e.isPromoted == false)
    }

    @Test("No promotion when FN rate too high")
    func noPromotionHighFN() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<20 { await e.recordResult(acousticDetected: true, textDetected: true) }
        for _ in 0..<20 { await e.recordResult(acousticDetected: false, textDetected: true) }
        for _ in 0..<160 { await e.recordResult(acousticDetected: false, textDetected: false) }
        #expect(await e.isPromoted == false)
    }

    @Test("Post-promotion demotion on high FP")
    func demotionOnHighFP() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<200 { await e.recordResult(acousticDetected: true, textDetected: true) }
        #expect(await e.isPromoted == true)
        // 2 FP + 48 TN in window of 50 = 4% > 2%
        for _ in 0..<2 { await e.recordResult(acousticDetected: true, textDetected: false) }
        for _ in 0..<48 { await e.recordResult(acousticDetected: false, textDetected: false) }
        #expect(await e.isPromoted == false)
    }

    @Test("No demotion at exactly 2% FP rate")
    func noDemotionAtExactThreshold() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<200 { await e.recordResult(acousticDetected: true, textDetected: true) }
        // 1 FP + 49 TN = 2% = threshold (not exceeded)
        await e.recordResult(acousticDetected: true, textDetected: false)
        for _ in 0..<49 { await e.recordResult(acousticDetected: false, textDetected: false) }
        #expect(await e.isPromoted == true)
    }

    @Test("Demotion resets counters")
    func demotionResets() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<200 { await e.recordResult(acousticDetected: true, textDetected: true) }
        for _ in 0..<2 { await e.recordResult(acousticDetected: true, textDetected: false) }
        for _ in 0..<48 { await e.recordResult(acousticDetected: false, textDetected: false) }
        #expect(await e.isPromoted == false)
        let d = await e.diagnostics
        #expect(d.totalAttempts == 0)
        #expect(d.truePositives == 0)
    }

    @Test("FP rate zero with no attempts")
    func fpRateZeroEmpty() async {
        let e = ShadowWakeWordEvaluator()
        #expect(await e.falsePositiveRate == 0)
    }

    @Test("FP rate calculation correct")
    func fpRateCalc() async {
        let e = ShadowWakeWordEvaluator()
        for _ in 0..<2 { await e.recordResult(acousticDetected: true, textDetected: false) }
        for _ in 0..<8 { await e.recordResult(acousticDetected: false, textDetected: false) }
        #expect(abs(await e.falsePositiveRate - 0.2) < 0.001)
    }

    @Test("FN rate calculation correct")
    func fnRateCalc() async {
        let e = ShadowWakeWordEvaluator()
        await e.recordResult(acousticDetected: true, textDetected: true)
        await e.recordResult(acousticDetected: false, textDetected: true)
        #expect(abs(await e.falseNegativeRate - 0.5) < 0.001)
    }

    @Test("Diagnostics summary reflects state")
    func diagnosticsReflect() async {
        let e = ShadowWakeWordEvaluator()
        await e.recordResult(acousticDetected: true, textDetected: true)
        await e.recordResult(acousticDetected: true, textDetected: false)
        await e.recordResult(acousticDetected: false, textDetected: true)
        await e.recordResult(acousticDetected: false, textDetected: false)
        let d = await e.diagnostics
        #expect(d.totalAttempts == 4)
        #expect(d.truePositives == 1)
        #expect(d.falsePositives == 1)
        #expect(d.falseNegatives == 1)
        #expect(d.trueNegatives == 1)
    }

    @Test("Mixed results accumulate correctly")
    func mixedResults() async {
        let e = ShadowWakeWordEvaluator()
        await e.recordResult(acousticDetected: true, textDetected: true)
        await e.recordResult(acousticDetected: true, textDetected: false)
        await e.recordResult(acousticDetected: false, textDetected: true)
        await e.recordResult(acousticDetected: false, textDetected: false)
        await e.recordResult(acousticDetected: true, textDetected: true)
        let d = await e.diagnostics
        #expect(d.totalAttempts == 5)
        #expect(d.truePositives == 2)
        #expect(d.falsePositives == 1)
    }
}
