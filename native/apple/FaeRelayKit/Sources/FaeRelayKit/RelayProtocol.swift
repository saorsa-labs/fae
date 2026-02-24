import Foundation
import FaeOrbKit

// MARK: - Relay Service Constants

public enum FaeRelayConstants {
    /// Bonjour service type for Multipeer Connectivity discovery.
    public static let serviceType = "fae-relay"

    /// Protocol version (matches Mode B contract.rs v1).
    public static let protocolVersion: UInt32 = 1
}

// MARK: - JSON Envelope Types (matching Rust contract.rs)

/// Command envelope sent from companion → Mac brain.
public struct CommandEnvelope: Codable, Sendable {
    public let v: UInt32
    public let requestId: String
    public let command: String
    public let payload: [String: AnyCodable]

    public init(command: String, payload: [String: AnyCodable] = [:]) {
        self.v = FaeRelayConstants.protocolVersion
        self.requestId = UUID().uuidString
        self.command = command
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case v
        case requestId = "request_id"
        case command
        case payload
    }
}

/// Response envelope from Mac brain → companion.
public struct ResponseEnvelope: Codable, Sendable {
    public let v: UInt32
    public let requestId: String
    public let ok: Bool
    public let payload: [String: AnyCodable]?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case v
        case requestId = "request_id"
        case ok
        case payload
        case error
    }
}

/// Event envelope from Mac brain → companion (push notification).
public struct EventEnvelope: Codable, Sendable {
    public let v: UInt32
    public let eventId: String
    public let event: String
    public let payload: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case v
        case eventId = "event_id"
        case event
        case payload
    }
}

// MARK: - Orb State Event

/// Parsed orb state from `orb.state` events.
public struct OrbStateEvent: Sendable {
    public let mode: OrbMode
    public let feeling: OrbFeeling
    public let palette: OrbPalette

    public init?(from payload: [String: AnyCodable]) {
        guard let modeStr = payload["mode"]?.stringValue,
              let mode = OrbMode(rawValue: modeStr) else { return nil }
        self.mode = mode
        self.feeling = payload["feeling"]?.stringValue.flatMap { OrbFeeling(rawValue: $0) } ?? .neutral
        self.palette = payload["palette"]?.stringValue.flatMap { OrbPalette(rawValue: $0) } ?? .modeDefault
    }
}

// MARK: - Audio Frame

/// Binary audio frame header (4 bytes + payload).
public struct AudioFrameHeader {
    public let frameType: UInt8
    public let flags: UInt8
    public let payloadLength: UInt16

    /// Mic audio: companion → Mac
    public static let micAudio: UInt8 = 0x01
    /// TTS audio: Mac → companion
    public static let ttsAudio: UInt8 = 0x02
    /// Audio level: Mac → companion
    public static let audioLevel: UInt8 = 0x03

    // Flags
    public static let startOfUtterance: UInt8 = 0x01
    public static let endOfUtterance: UInt8 = 0x02

    public init(frameType: UInt8, flags: UInt8, payloadLength: UInt16) {
        self.frameType = frameType
        self.flags = flags
        self.payloadLength = payloadLength
    }

    public func encode() -> Data {
        var data = Data(capacity: 4)
        data.append(frameType)
        data.append(flags)
        var len = payloadLength.bigEndian
        data.append(Data(bytes: &len, count: 2))
        return data
    }

    public static func decode(from data: Data) -> AudioFrameHeader? {
        guard data.count >= 4 else { return nil }
        let frameType = data[0]
        let flags = data[1]
        let payloadLength = UInt16(data[2]) << 8 | UInt16(data[3])
        return AudioFrameHeader(frameType: frameType, flags: flags, payloadLength: payloadLength)
    }
}

// MARK: - Type-Erased Codable

/// Minimal type-erased Codable wrapper for JSON payload values.
public struct AnyCodable: Codable, Sendable {
    public let value: Any

    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var doubleValue: Double? { value as? Double }
    public var boolValue: Bool? { value as? Bool }

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str; return }
        if let int = try? container.decode(Int.self) { value = int; return }
        if let dbl = try? container.decode(Double.self) { value = dbl; return }
        if let bool = try? container.decode(Bool.self) { value = bool; return }
        if let dict = try? container.decode([String: AnyCodable].self) { value = dict; return }
        if let arr = try? container.decode([AnyCodable].self) { value = arr; return }
        if container.decodeNil() { value = NSNull(); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let dbl as Double: try container.encode(dbl)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        case let arr as [AnyCodable]: try container.encode(arr)
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }
}
