import AVFoundation
import Foundation
import SoundAnalysis

/// Uses Apple's SoundAnalysis framework to classify audio as speech vs non-speech.
///
/// This acts as a pre-filter before speaker verification:
/// 1. Reject music, TV, environmental noise
/// 2. Only pass through audio classified as human speech
/// 3. Then speaker verification distinguishes between different humans
///
/// Apple's classifier can detect 300+ sound types including:
/// - `speech` — human speech (what we want)
/// - `music` — background music, TV shows with music
/// - `singing` — singing voices (different from speech)
/// - Environmental sounds (dogs, cars, appliances, etc.)
actor AppleSpeechClassifier {
    
    // MARK: - Configuration
    
    /// Minimum confidence to accept a classification.
    static let confidenceThreshold: Double = 0.5
    
    /// Sound types that indicate human speech.
    static let speechIdentifiers: Set<String> = ["speech"]
    
    /// Sound types to explicitly reject (even if speech is also detected).
    /// TV/radio often has both speech and music; we reject if music dominates.
    static let rejectIdentifiers: Set<String> = ["music", "singing", "television"]
    
    // MARK: - State
    
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var resultObserver: ResultObserver?
    
    /// Most recent classification result.
    private(set) var lastResult: ClassificationResult?
    
    /// Whether the classifier is ready to process audio.
    private(set) var isReady: Bool = false
    
    // MARK: - Types
    
    struct ClassificationResult: Sendable {
        let isSpeech: Bool
        let isMusic: Bool
        let speechConfidence: Double
        let musicConfidence: Double
        let topClassification: String
        let topConfidence: Double
        let timestamp: Date
        
        /// Whether this audio should be processed by speaker verification.
        var shouldProcessForSpeaker: Bool {
            // Accept if speech is dominant and music is not
            isSpeech && speechConfidence > musicConfidence
        }
    }
    
    // MARK: - Lifecycle
    
    /// Initialize the classifier for the given audio format.
    func setup(format: AVAudioFormat) throws {
        // Create the analyzer for streaming audio
        analyzer = SNAudioStreamAnalyzer(format: format)
        
        // Create the Apple sound classification request
        request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request?.overlapFactor = 0.5
        
        // Create the result observer
        let observer = ResultObserver { [weak self] result in
            Task { await self?.handleResult(result) }
        }
        resultObserver = observer
        
        // Add the request to the analyzer
        guard let analyzer, let request, let resultObserver else {
            throw ClassifierError.setupFailed
        }
        
        try analyzer.add(request, withObserver: resultObserver)
        isReady = true
        
        NSLog("AppleSpeechClassifier: ready (303 sound types)")
    }
    
    /// Analyze an audio buffer for speech classification.
    func analyze(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard isReady, let analyzer else { return }
        analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
    }
    
    /// Analyze raw audio samples (convenience wrapper).
    func analyze(samples: [Float], sampleRate: Int) {
        guard isReady, let analyzer else { return }
        
        // Create AVAudioPCMBuffer from samples
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return }
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                channelData[i] = samples[i]
            }
        }
        
        // Use frame position 0 for simplicity (we're doing one-shot analysis)
        analyzer.analyze(buffer, atAudioFramePosition: 0)
    }
    
    /// Synchronously classify a speech segment.
    ///
    /// Returns the classification result after processing the entire segment.
    /// Use this for completed VAD segments rather than streaming analysis.
    func classify(segment: SpeechSegment) async -> ClassificationResult? {
        guard isReady else { return nil }
        
        // Reset state
        lastResult = nil
        
        // Analyze the segment
        analyze(samples: segment.samples, sampleRate: segment.sampleRate)
        
        // Wait briefly for the async result
        // SoundAnalysis processes asynchronously via the observer
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        return lastResult
    }
    
    /// Check if the most recent audio was classified as speech.
    var isSpeechDetected: Bool {
        lastResult?.shouldProcessForSpeaker ?? false
    }
    
    /// Reset the classifier state.
    func reset() {
        lastResult = nil
    }
    
    /// Teardown the classifier.
    func teardown() {
        if let analyzer, let request {
            analyzer.remove(request)
        }
        analyzer = nil
        request = nil
        resultObserver = nil
        isReady = false
    }
    
    // MARK: - Private
    
    private func handleResult(_ result: SNClassificationResult) {
        var speechConfidence: Double = 0
        var musicConfidence: Double = 0
        var topClassification = ""
        var topConfidence: Double = 0
        
        for classification in result.classifications {
            let id = classification.identifier
            let conf = classification.confidence
            
            if conf > topConfidence {
                topConfidence = conf
                topClassification = id
            }
            
            if Self.speechIdentifiers.contains(id) {
                speechConfidence = max(speechConfidence, conf)
            }
            
            if Self.rejectIdentifiers.contains(id) {
                musicConfidence = max(musicConfidence, conf)
            }
        }
        
        lastResult = ClassificationResult(
            isSpeech: speechConfidence >= Self.confidenceThreshold,
            isMusic: musicConfidence >= Self.confidenceThreshold,
            speechConfidence: speechConfidence,
            musicConfidence: musicConfidence,
            topClassification: topClassification,
            topConfidence: topConfidence,
            timestamp: Date()
        )
    }
    
    // MARK: - Errors
    
    enum ClassifierError: Error {
        case setupFailed
        case notReady
    }
    
    // MARK: - Result Observer
    
    private class ResultObserver: NSObject, SNResultsObserving {
        let handler: (SNClassificationResult) -> Void
        
        init(handler: @escaping (SNClassificationResult) -> Void) {
            self.handler = handler
        }
        
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classificationResult = result as? SNClassificationResult else { return }
            handler(classificationResult)
        }
        
        func request(_ request: SNRequest, didFailWithError error: Error) {
            NSLog("AppleSpeechClassifier: error — %@", error.localizedDescription)
        }
        
        func requestDidComplete(_ request: SNRequest) {
            // Analysis complete
        }
    }
}
