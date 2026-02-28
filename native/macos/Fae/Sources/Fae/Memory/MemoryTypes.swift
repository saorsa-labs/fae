import Foundation

// MARK: - Enums

/// Memory record category.
enum MemoryKind: String, Sendable, Codable, CaseIterable {
    case profile = "profile"
    case episode = "episode"
    case fact = "fact"
    case event = "event"
    case person = "person"
    case interest = "interest"
    case commitment = "commitment"
}

/// Memory record lifecycle status.
enum MemoryStatus: String, Sendable, Codable {
    case active = "active"
    case superseded = "superseded"
    case invalidated = "invalidated"
    case forgotten = "forgotten"
}

/// Audit operation type.
enum MemoryAuditOp: String, Sendable, Codable {
    case insert = "insert"
    case patch = "patch"
    case supersede = "supersede"
    case invalidate = "invalidate"
    case forgetSoft = "forget_soft"
    case forgetHard = "forget_hard"
    case migrate = "migrate"
}

// MARK: - Structs

struct MemoryRecord: Sendable {
    var id: String
    var kind: MemoryKind
    var status: MemoryStatus = .active
    var text: String
    var confidence: Float = 0.5
    var sourceTurnId: String?
    var tags: [String] = []
    var supersedes: String?
    var createdAt: UInt64 = 0
    var updatedAt: UInt64 = 0
    var importanceScore: Float?
    var staleAfterSecs: UInt64?
    var metadata: String?
    var cachedEmbedding: [Float]?
    var speakerId: String?
}

struct MemoryAuditEntry: Sendable {
    var id: String
    var op: MemoryAuditOp
    var targetId: String?
    var note: String
    var at: UInt64 = 0
}

struct MemorySearchHit: Sendable {
    var record: MemoryRecord
    var score: Float
}

struct MemoryCaptureReport: Sendable {
    var episodeId: String?
    var extractedCount: Int = 0
    var supersededCount: Int = 0
    var forgottenCount: Int = 0
}

// MARK: - Constants

enum MemoryConstants {
    static let schemaVersion: UInt32 = 7
    static let maxRecordTextLen: Int = 32_768
    static let truncationSuffix: String = " [truncated]"

    // Confidence thresholds
    static let profileNameConfidence: Float = 0.98
    static let profilePreferenceConfidence: Float = 0.86
    static let factRememberConfidence: Float = 0.80
    static let factConversationalConfidence: Float = 0.75
    static let episodeConfidence: Float = 0.55

    // Lexical scoring
    static let scoreEmptyQueryBaseline: Float = 0.20
    static let scoreConfidenceWeight: Float = 0.20
    static let scoreImportanceWeight: Float = 0.15
    static let scoreFreshnessWeight: Float = 0.10
    static let scoreKindBonusProfile: Float = 0.05
    static let scoreKindBonusFact: Float = 0.03

    // Hybrid scoring
    static let hybridSemanticWeight: Float = 0.60
    static let hybridConfidenceWeight: Float = 0.20
    static let hybridFreshnessWeight: Float = 0.10
    static let hybridKindBonusProfile: Float = 0.10
    static let hybridKindBonusFact: Float = 0.06

    // Episode relevance
    static let episodeThresholdHybrid: Float = 0.40
    static let episodeThresholdLexical: Float = 0.60

    static let secsPerDay: Float = 86_400.0

    // Entity relationship system
    static let entityStrengthDecayHalfLifeDays: Float = 60.0
    static let entityMaxContextChars: Int = 800
}

// MARK: - Scoring

/// Tokenize text for lexical scoring (ASCII alphanumeric + apostrophe + hyphen, min length 2).
func tokenizeForSearch(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""

    for ch in text {
        if ch.isASCII, ch.isLetter || ch.isNumber || ch == "'" || ch == "-" {
            current.append(Character(ch.lowercased()))
        } else if !current.isEmpty {
            if current.count > 1 { tokens.append(current) }
            current = ""
        }
    }
    if current.count > 1 { tokens.append(current) }
    return tokens
}

/// Lexical score for a memory record against query tokens.
func scoreRecord(_ record: MemoryRecord, queryTokens: [String]) -> Float {
    var score: Float = 0.0

    if queryTokens.isEmpty {
        score += MemoryConstants.scoreEmptyQueryBaseline
    } else {
        let textTokens = Set(tokenizeForSearch(record.text))
        let overlap = queryTokens.filter { textTokens.contains($0) }.count
        if overlap > 0 {
            score += Float(overlap) / Float(queryTokens.count)
        }
    }

    score += MemoryConstants.scoreConfidenceWeight * min(max(record.confidence, 0), 1)

    // Importance scoring — use stored importanceScore when available.
    if let importance = record.importanceScore {
        score += MemoryConstants.scoreImportanceWeight * min(max(importance, 0), 1)
    }

    // Exponential temporal decay with kind-gated half-lives.
    let now = UInt64(Date().timeIntervalSince1970)
    if record.updatedAt > 0, record.updatedAt <= now {
        let ageDays = Float(now - record.updatedAt) / MemoryConstants.secsPerDay
        let halfLife: Float = switch record.kind {
        case .episode: 30
        case .fact, .interest, .commitment, .event, .person: 180
        case .profile: 365
        }
        let decay = exp(-0.693 * ageDays / halfLife)
        let freshness = 0.7 + 0.3 * decay  // floors at 0.7 so old memories still surface
        score += MemoryConstants.scoreFreshnessWeight * freshness
    }

    switch record.kind {
    case .profile:
        score += MemoryConstants.scoreKindBonusProfile
    case .fact, .event, .commitment, .person, .interest:
        score += MemoryConstants.scoreKindBonusFact
    case .episode:
        break
    }

    return score
}

// MARK: - ID Generation

private var idCounter: UInt64 = 0

func newMemoryId(prefix: String) -> String {
    let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    idCounter += 1
    return "\(prefix)-\(nanos)-\(idCounter)"
}
