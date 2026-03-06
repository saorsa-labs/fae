import Foundation
import SileroVAD

/// Thin adapter around the Silero VAD CoreML package.
///
/// Fae keeps segmentation/state logic in `VoiceActivityDetector`; this wrapper is
/// only responsible for loading the model and producing speech probabilities for
/// 16 kHz mono audio. It tolerates non-576-sized caller chunks by buffering until
/// enough samples are available for the underlying model.
final class SileroVADEngine {
    static let sampleRate = SileroVAD.sampleRate
    static let chunkSize = SileroVAD.chunkSize

    private let model: SileroVAD
    private var pendingSamples: [Float] = []

    init() throws {
        self.model = try SileroVAD()
        pendingSamples.reserveCapacity(Self.chunkSize * 2)
    }

    func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
        model.reset()
    }

    /// Process arbitrary 16 kHz mono samples and return the highest speech
    /// probability observed across any complete 576-sample Silero frames.
    ///
    /// If there are not yet enough buffered samples for a full frame, returns nil.
    func process(samples: [Float]) throws -> Float? {
        guard !samples.isEmpty else { return nil }

        pendingSamples.append(contentsOf: samples)
        var maxProbability: Float?

        while pendingSamples.count >= Self.chunkSize {
            let frame = Array(pendingSamples.prefix(Self.chunkSize))
            pendingSamples.removeFirst(Self.chunkSize)
            let probability = try model.process(frame)
            maxProbability = max(maxProbability ?? probability, probability)
        }

        return maxProbability
    }
}
