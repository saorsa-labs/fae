import Testing
@testable import Fae

@Suite("WakeWordScoreFusion")
struct WakeWordScoreFusionTests {

    // MARK: - Fused mode (classifier + templates)

    @Test("Fused score uses weighted formula")
    func fusedScoreWeightedFormula() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.8,
            templateSimilarities: [0.6, 0.5]
        )
        // 0.7 * 0.8 + 0.3 * 0.6 = 0.56 + 0.18 = 0.74
        #expect(abs(result.score - 0.74) < 1e-5)
        #expect(result.isActivated == true)
        #expect(result.mode == .fused)
    }

    @Test("Fused score picks max template similarity")
    func fusedScorePicksMaxTemplate() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.5,
            templateSimilarities: [0.2, 0.9, 0.4]
        )
        // 0.7 * 0.5 + 0.3 * 0.9 = 0.35 + 0.27 = 0.62
        #expect(abs(result.score - 0.62) < 1e-5)
        #expect(result.isActivated == true)
        #expect(result.mode == .fused)
    }

    @Test("Fused score below threshold is not activated")
    func fusedScoreBelowThresholdNotActivated() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.5,
            templateSimilarities: [0.2]
        )
        // 0.7 * 0.5 + 0.3 * 0.2 = 0.35 + 0.06 = 0.41
        #expect(abs(result.score - 0.41) < 1e-5)
        #expect(result.isActivated == false)
        #expect(result.mode == .fused)
    }

    @Test("Fused score at exactly threshold activates")
    func fusedScoreAtThreshold() {
        // 0.7 * 0.6 + 0.3 * 0.6 = 0.42 + 0.18 = 0.60
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.6,
            templateSimilarities: [0.6]
        )
        #expect(result.isActivated == true)
        #expect(result.mode == .fused)
    }

    @Test("Fused score just below threshold does not activate")
    func fusedScoreJustBelowThreshold() {
        // 0.7 * 0.5 + 0.3 * 0.5 = 0.35 + 0.15 = 0.50
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.5,
            templateSimilarities: [0.5]
        )
        #expect(result.score < WakeWordScoreFusion.fusedThreshold)
        #expect(result.isActivated == false)
    }

    @Test("Fused mode with empty templates uses classifier only")
    func fusedModeEmptyTemplates() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.9,
            templateSimilarities: []
        )
        // 0.7 * 0.9 + 0.3 * 0 = 0.63
        #expect(abs(result.score - 0.63) < 1e-5)
        #expect(result.isActivated == true)
        #expect(result.mode == .fused)
    }

    @Test("High template but zero classifier produces low fused score")
    func highTemplateLowClassifier() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: 0.0,
            templateSimilarities: [1.0]
        )
        // 0.7 * 0.0 + 0.3 * 1.0 = 0.30
        #expect(abs(result.score - 0.30) < 1e-5)
        #expect(result.isActivated == false)
        #expect(result.mode == .fused)
    }

    // MARK: - Template-only mode (no classifier)

    @Test("Template-only activates above 0.7")
    func templateOnlyActivates() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: nil,
            templateSimilarities: [0.8]
        )
        #expect(abs(result.score - 0.8) < 1e-5)
        #expect(result.isActivated == true)
        #expect(result.mode == .templateOnly)
    }

    @Test("Template-only below 0.7 does not activate")
    func templateOnlyBelowThreshold() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: nil,
            templateSimilarities: [0.69]
        )
        #expect(result.isActivated == false)
        #expect(result.mode == .templateOnly)
    }

    @Test("Template-only at exactly 0.7 activates")
    func templateOnlyAtThreshold() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: nil,
            templateSimilarities: [0.7]
        )
        #expect(result.isActivated == true)
        #expect(result.mode == .templateOnly)
    }

    @Test("Template-only picks max from multiple")
    func templateOnlyPicksMax() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: nil,
            templateSimilarities: [0.3, 0.75, 0.5]
        )
        #expect(abs(result.score - 0.75) < 1e-5)
        #expect(result.isActivated == true)
        #expect(result.mode == .templateOnly)
    }

    @Test("Template-only with all zeros falls to none")
    func templateOnlyAllZeros() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: nil,
            templateSimilarities: [0.0, 0.0]
        )
        #expect(result.score == 0)
        #expect(result.isActivated == false)
        #expect(result.mode == .none)
    }

    // MARK: - None mode

    @Test("Both unavailable returns zero")
    func bothUnavailable() {
        let result = WakeWordScoreFusion.fuse(
            classifierScore: nil,
            templateSimilarities: []
        )
        #expect(result.score == 0)
        #expect(result.isActivated == false)
        #expect(result.mode == .none)
    }
}
