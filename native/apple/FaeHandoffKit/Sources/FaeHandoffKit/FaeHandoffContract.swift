import Foundation

public enum FaeDeviceTarget: String, Codable, CaseIterable, Sendable {
    case mac
    case iphone
    case watch
}

public struct FaeHandoffPayload: Codable, Equatable, Sendable {
    public var target: FaeDeviceTarget
    public var command: String
    public var issuedAtEpochMs: Int64

    public init(target: FaeDeviceTarget, command: String, issuedAtEpochMs: Int64) {
        self.target = target
        self.command = command
        self.issuedAtEpochMs = issuedAtEpochMs
    }
}

public enum FaeHandoffError: Error, Equatable {
    case missingUserInfo
    case missingField(String)
    case invalidTarget(String)
}

public enum FaeHandoffContract {
    public static let activityType = "com.saorsalabs.fae.session.handoff"

    public static func payload(from userInfo: [AnyHashable: Any]?) throws -> FaeHandoffPayload {
        guard let userInfo else {
            throw FaeHandoffError.missingUserInfo
        }

        guard let targetRaw = userInfo["target"] as? String, !targetRaw.isEmpty else {
            throw FaeHandoffError.missingField("target")
        }
        guard let target = FaeDeviceTarget(rawValue: targetRaw.lowercased()) else {
            throw FaeHandoffError.invalidTarget(targetRaw)
        }

        let command = (userInfo["command"] as? String) ?? ""

        let issuedAt: Int64
        if let int64Value = userInfo["issuedAtEpochMs"] as? Int64 {
            issuedAt = int64Value
        } else if let intValue = userInfo["issuedAtEpochMs"] as? Int {
            issuedAt = Int64(intValue)
        } else if let numberValue = userInfo["issuedAtEpochMs"] as? NSNumber {
            issuedAt = numberValue.int64Value
        } else {
            throw FaeHandoffError.missingField("issuedAtEpochMs")
        }

        return FaeHandoffPayload(
            target: target,
            command: command,
            issuedAtEpochMs: issuedAt
        )
    }

    public static func userInfo(from payload: FaeHandoffPayload) -> [String: Any] {
        [
            "target": payload.target.rawValue,
            "command": payload.command,
            "issuedAtEpochMs": NSNumber(value: payload.issuedAtEpochMs),
        ]
    }

    public static func nowEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
