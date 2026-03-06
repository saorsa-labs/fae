import Foundation

/// Lightweight acoustic wake-word detector based on time-normalized log-mel templates.
///
/// This is intentionally conservative:
/// - it only activates when personalized wake templates exist,
/// - it matches against the *start* of an utterance,
/// - and the text wake matcher remains as a fail-open fallback.
struct WakeWordAcousticDetector {
    struct Template: Codable, Sendable {
        let embedding: [Float]
        let durationSeconds: Float
        let phrase: String
        let source: String
        let createdAt: Date
    }

    struct Detection: Sendable, Equatable {
        let similarity: Float
        let templateCount: Int
        let durationSeconds: Float
        let supportCount: Int
        let consensusSimilarity: Float
        let effectiveThreshold: Float
    }

    static let minTemplateCount = 2
    static let minDurationSeconds: Float = 0.35
    static let maxDurationSeconds: Float = 1.80
    private static let targetFrames = 48
    private static let silenceFloor: Float = 0.008
    private static let supportWindow: Float = 0.035

    static func makeTemplate(samples: [Float], sampleRate: Int) -> Template? {
        guard let prepared = prepare(samples: samples, sampleRate: sampleRate) else { return nil }
        return Template(
            embedding: prepared.embedding,
            durationSeconds: prepared.durationSeconds,
            phrase: "Hey Fae",
            source: "runtime",
            createdAt: Date()
        )
    }

    static func bestDetection(
        samples: [Float],
        sampleRate: Int,
        templates: [Template],
        threshold: Float
    ) -> Detection? {
        guard templates.count >= minTemplateCount else { return nil }
        guard let prepared = prepare(samples: samples, sampleRate: sampleRate) else { return nil }

        let similarities = allSimilarities(embedding: prepared.embedding, templates: templates)
        guard let best = similarities.first else { return nil }

        let supportCutoff = best - supportWindow
        let supportCount = similarities.filter { $0 >= supportCutoff }.count
        let consensusWindow = similarities.prefix(min(3, similarities.count))
        let consensusSimilarity = consensusWindow.reduce(Float.zero, +) / Float(consensusWindow.count)
        let shortPrefixBoost: Float = prepared.durationSeconds < 0.55 ? 0.02 : 0.0
        let effectiveThreshold = min(threshold + shortPrefixBoost, 0.95)

        guard best >= effectiveThreshold else { return nil }
        guard supportCount >= minTemplateCount else { return nil }

        return Detection(
            similarity: best,
            templateCount: templates.count,
            durationSeconds: prepared.durationSeconds,
            supportCount: supportCount,
            consensusSimilarity: consensusSimilarity,
            effectiveThreshold: effectiveThreshold
        )
    }

    static func bestSimilarity(samples: [Float], sampleRate: Int, templates: [Template]) -> Float? {
        guard let prepared = prepare(samples: samples, sampleRate: sampleRate) else { return nil }
        return bestSimilarity(embedding: prepared.embedding, templates: templates)
    }

    private static func bestSimilarity(embedding: [Float], templates: [Template]) -> Float? {
        allSimilarities(embedding: embedding, templates: templates).first
    }

    private static func allSimilarities(embedding: [Float], templates: [Template]) -> [Float] {
        templates
            .filter { $0.embedding.count == embedding.count }
            .map { cosineSimilarity(embedding, $0.embedding) }
            .sorted(by: >)
    }

    private static func prepare(samples: [Float], sampleRate: Int) -> (embedding: [Float], durationSeconds: Float)? {
        let trimmed = trimSilence(samples)
        guard !trimmed.isEmpty else { return nil }

        let durationSeconds = Float(trimmed.count) / Float(sampleRate)
        guard durationSeconds >= minDurationSeconds, durationSeconds <= maxDurationSeconds else {
            return nil
        }

        let (mel, numFrames) = CoreMLSpeakerEncoder.sharedLogMelSpectrogram(
            audio: trimmed,
            sampleRate: sampleRate
        )
        guard !mel.isEmpty, numFrames >= 4 else { return nil }

        let embedding = timeNormalizeMel(
            mel,
            numFrames: numFrames,
            numMels: CoreMLSpeakerEncoder.analysisNumMels,
            targetFrames: targetFrames
        )
        guard !embedding.isEmpty else { return nil }
        let normalized = l2Normalize(meanCenter(embedding))
        guard !normalized.isEmpty else { return nil }
        return (normalized, durationSeconds)
    }

    private static func trimSilence(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let threshold = max(silenceFloor, peak * 0.12)
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold })
        else {
            return samples
        }

        let padding = max(1, samples.count / 30)
        let start = max(0, first - padding)
        let end = min(samples.count - 1, last + padding)
        return Array(samples[start...end])
    }

    private static func timeNormalizeMel(
        _ mel: [Float],
        numFrames: Int,
        numMels: Int,
        targetFrames: Int
    ) -> [Float] {
        guard numFrames > 0, numMels > 0, targetFrames > 1 else { return [] }
        var output = [Float](repeating: 0, count: numMels * targetFrames)
        let denominator = max(targetFrames - 1, 1)
        let sourceMax = Float(max(numFrames - 1, 0))

        for melIndex in 0..<numMels {
            let bandOffset = melIndex * numFrames
            let outOffset = melIndex * targetFrames

            for frameIndex in 0..<targetFrames {
                let position = Float(frameIndex) * sourceMax / Float(denominator)
                let left = Int(position.rounded(.down))
                let right = min(left + 1, numFrames - 1)
                let alpha = position - Float(left)
                let lhs = mel[bandOffset + left]
                let rhs = mel[bandOffset + right]
                output[outOffset + frameIndex] = lhs + (rhs - lhs) * alpha
            }
        }

        return output
    }

    private static func meanCenter(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let mean = values.reduce(Float.zero, +) / Float(values.count)
        return values.map { $0 - mean }
    }

    private static func l2Normalize(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let norm = sqrt(values.reduce(Float.zero) { $0 + ($1 * $1) })
        guard norm > 1e-6 else { return [] }
        return values.map { $0 / norm }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.greatestFiniteMagnitude }
        var sum: Float = 0
        for i in lhs.indices {
            sum += lhs[i] * rhs[i]
        }
        return sum
    }
}
