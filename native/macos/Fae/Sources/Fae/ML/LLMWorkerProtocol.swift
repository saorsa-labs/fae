import Foundation

enum WorkerProcessRole: String, Codable, Sendable {
    case operatorModel = "operator"
    case conciergeModel = "concierge"
}

enum WorkerJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WorkerJSONValue])
    case array([WorkerJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: WorkerJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([WorkerJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported WorkerJSONValue payload")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return Int(value)
            }
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .array(let value):
            return value.map(\.anyValue)
        case .null:
            return NSNull()
        }
    }

    var sendableValue: any Sendable {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.sendableValue)
        case .array(let value):
            return value.map(\.sendableValue)
        case .null:
            return NSNull()
        }
    }

    static func from(any value: Any) -> WorkerJSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let int8 as Int8:
            return .number(Double(int8))
        case let int16 as Int16:
            return .number(Double(int16))
        case let int32 as Int32:
            return .number(Double(int32))
        case let int64 as Int64:
            return .number(Double(int64))
        case let uint as UInt:
            return .number(Double(uint))
        case let uint8 as UInt8:
            return .number(Double(uint8))
        case let uint16 as UInt16:
            return .number(Double(uint16))
        case let uint32 as UInt32:
            return .number(Double(uint32))
        case let uint64 as UInt64:
            return .number(Double(uint64))
        case let float as Float:
            return .number(Double(float))
        case let double as Double:
            return .number(double)
        case let dict as [String: Any]:
            var object: [String: WorkerJSONValue] = [:]
            for (key, nested) in dict {
                guard let converted = WorkerJSONValue.from(any: nested) else { return nil }
                object[key] = converted
            }
            return .object(object)
        case let array as [Any]:
            var values: [WorkerJSONValue] = []
            for nested in array {
                guard let converted = WorkerJSONValue.from(any: nested) else { return nil }
                values.append(converted)
            }
            return .array(values)
        case let dict as [String: any Sendable]:
            var object: [String: WorkerJSONValue] = [:]
            for (key, nested) in dict {
                guard let converted = WorkerJSONValue.from(any: nested) else { return nil }
                object[key] = converted
            }
            return .object(object)
        case let array as [any Sendable]:
            var values: [WorkerJSONValue] = []
            for nested in array {
                guard let converted = WorkerJSONValue.from(any: nested) else { return nil }
                values.append(converted)
            }
            return .array(values)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

struct WorkerLLMMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
    let toolCallID: String?
    let name: String?
    let tag: String?
}

struct WorkerGenerationOptions: Codable, Sendable {
    var temperature: Float
    var topP: Float
    var maxTokens: Int
    var repetitionPenalty: Float?
    var suppressThinking: Bool
    var tools: [[String: WorkerJSONValue]]?
    var turnContextPrefix: String?
    var contextLimitTokens: Int?
    var maxKVSize: Int?
    var kvBits: Int?
    var kvGroupSize: Int
    var quantizedKVStart: Int
    var repetitionContextSize: Int
    var prefillStepSize: Int?
}

struct LLMWorkerRequest: Codable, Sendable {
    let requestID: String
    let command: String
    let role: WorkerProcessRole
    let modelID: String?
    let messages: [WorkerLLMMessage]?
    let systemPrompt: String?
    let options: WorkerGenerationOptions?
}

struct LLMWorkerResponse: Codable, Sendable {
    let requestID: String
    let type: String
    let role: WorkerProcessRole
    let text: String?
    let error: String?
    let toolName: String?
    let toolArguments: [String: WorkerJSONValue]?
}

extension WorkerLLMMessage {
    init(_ message: LLMMessage) {
        self.init(
            role: message.role.rawValue,
            content: message.content,
            toolCallID: message.toolCallID,
            name: message.name,
            tag: message.tag
        )
    }

    var llmMessage: LLMMessage {
        LLMMessage(
            role: LLMMessage.Role(rawValue: role) ?? .user,
            content: content,
            toolCallID: toolCallID,
            name: name,
            tag: tag
        )
    }
}

extension WorkerGenerationOptions {
    init(_ options: GenerationOptions) {
        self.init(
            temperature: options.temperature,
            topP: options.topP,
            maxTokens: options.maxTokens,
            repetitionPenalty: options.repetitionPenalty,
            suppressThinking: options.suppressThinking,
            tools: options.tools?.compactMap { spec in
                var object: [String: WorkerJSONValue] = [:]
                for (key, value) in spec {
                    guard let converted = WorkerJSONValue.from(any: value) else { return nil }
                    object[key] = converted
                }
                return object
            },
            turnContextPrefix: options.turnContextPrefix,
            contextLimitTokens: options.contextLimitTokens,
            maxKVSize: options.maxKVSize,
            kvBits: options.kvBits,
            kvGroupSize: options.kvGroupSize,
            quantizedKVStart: options.quantizedKVStart,
            repetitionContextSize: options.repetitionContextSize,
            prefillStepSize: options.prefillStepSize
        )
    }

    var generationOptions: GenerationOptions {
        GenerationOptions(
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            repetitionPenalty: repetitionPenalty,
            suppressThinking: suppressThinking,
            tools: tools?.map { object in
                object.mapValues(\.sendableValue)
            },
            turnContextPrefix: turnContextPrefix,
            contextLimitTokens: contextLimitTokens,
            maxKVSize: maxKVSize,
            kvBits: kvBits,
            kvGroupSize: kvGroupSize,
            quantizedKVStart: quantizedKVStart,
            repetitionContextSize: repetitionContextSize,
            prefillStepSize: prefillStepSize
        )
    }
}
