import Foundation
import TokiUsageCore

struct CopilotOTELRecord: Decodable {
    private let type: String?
    private let name: String?
    private let traceID: String?
    private let spanID: String?
    private let spanContext: CopilotSpanContext?
    private let startTime: CopilotTimestamp?
    private let endTime: CopilotTimestamp?
    private let hrTime: CopilotTimestamp?
    private let alternateHRTime: CopilotTimestamp?
    private let time: CopilotTimestamp?
    private let timestampValue: CopilotTimestamp?
    private let observedTimestamp: CopilotTimestamp?
    private let timeUnixNano: CopilotTimestamp?
    let attributes: CopilotOTELAttributes

    enum CodingKeys: String, CodingKey {
        case type, name, traceID = "traceId", spanID = "spanId", spanContext, startTime, endTime, hrTime
        case alternateHRTime = "_hrTime"
        case time
        case timestampValue = "timestamp"
        case observedTimestamp, timeUnixNano, attributes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        traceID = try? container.decodeIfPresent(String.self, forKey: .traceID)
        spanID = try? container.decodeIfPresent(String.self, forKey: .spanID)
        spanContext = try? container.decodeIfPresent(CopilotSpanContext.self, forKey: .spanContext)
        startTime = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .startTime)
        endTime = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .endTime)
        hrTime = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .hrTime)
        alternateHRTime = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .alternateHRTime)
        time = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .time)
        timestampValue = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .timestampValue)
        observedTimestamp = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .observedTimestamp)
        timeUnixNano = try? container.decodeIfPresent(CopilotTimestamp.self, forKey: .timeUnixNano)
        attributes = (try? container.decodeIfPresent(CopilotOTELAttributes.self, forKey: .attributes))
            ?? CopilotOTELAttributes()
    }

    var usageSource: CopilotUsageSource? {
        let operation = attributes.operationName?.trimmedNonEmpty
        if type == "span" {
            if operation == "chat" || name?.hasPrefix("chat ") == true {
                return .chatSpan
            }
            if operation == "invoke_agent" || name?.hasPrefix("invoke_agent ") == true {
                return .agentSummarySpan
            }
            return nil
        }

        if attributes.eventName == "gen_ai.client.inference.operation.details" {
            return .inferenceLog
        }
        if attributes.eventName == "copilot_chat.agent.turn" {
            return .agentTurnLog
        }
        return nil
    }

    var validTraceID: String? {
        validSpanIdentity(traceID) ?? validSpanIdentity(spanContext?.traceID)
    }

    var validSpanID: String? {
        validSpanIdentity(spanID) ?? validSpanIdentity(spanContext?.spanID)
    }

    var timestamp: Date? {
        [
            startTime,
            endTime,
            hrTime,
            alternateHRTime,
            time,
            timestampValue,
            observedTimestamp,
            timeUnixNano,
        ].compactMap { $0?.date }.first
    }
}

func copilotBodyUsageSource(in data: Data) -> CopilotUsageSource? {
    let inferenceMarker = Array("GenAI inference:".utf8)
    let agentTurnMarker = Array("copilot_chat.agent.turn".utf8)

    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var depth = 0
        var index = 0

        func stringEnd(after start: Int) -> Int? {
            var cursor = start + 1
            var escaped = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }

        func skipsWhitespace(from start: Int) -> Int {
            var cursor = start
            while cursor < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[cursor]) {
                cursor += 1
            }
            return cursor
        }

        func matches(_ marker: [UInt8], at start: Int) -> Bool {
            guard start + marker.count <= bytes.count else { return false }
            return marker.indices.allSatisfy { bytes[start + $0] == marker[$0] }
        }

        while index < bytes.count {
            switch bytes[index] {
            case 0x7B, 0x5B:
                depth += 1
                index += 1
            case 0x7D, 0x5D:
                depth -= 1
                index += 1
            case 0x22:
                guard let end = stringEnd(after: index) else { return nil }
                guard depth == 1 else {
                    index = end + 1
                    continue
                }
                let key = bytes[(index + 1)..<end]
                let isBodyKey = key.elementsEqual("body".utf8) || key.elementsEqual("_body".utf8)
                guard isBodyKey else {
                    index = end + 1
                    continue
                }
                var valueStart = skipsWhitespace(from: end + 1)
                guard valueStart < bytes.count, bytes[valueStart] == 0x3A else {
                    index = end + 1
                    continue
                }
                valueStart = skipsWhitespace(from: valueStart + 1)
                guard valueStart < bytes.count, bytes[valueStart] == 0x22 else {
                    index = end + 1
                    continue
                }
                let contentStart = valueStart + 1
                if matches(inferenceMarker, at: contentStart) {
                    return .inferenceLog
                }
                if matches(agentTurnMarker, at: contentStart) {
                    return .agentTurnLog
                }
                index = end + 1
            default:
                index += 1
            }
        }
        return nil
    }
}

struct CopilotOTELAttributes: Decodable {
    let operationName: String?
    let eventName: String?
    let responseID: String?
    let responseModel: String?
    let requestModel: String?
    let provider: String?
    let conversationID: String?
    let copilotSessionID: String?
    let copilotChatSessionID: String?
    let sessionID: String?
    let interactionID: String?
    let inputTokens: Int?
    let outputTokens: Int?
    private let cacheReadDotted: Int?
    private let cacheReadUnderscored: Int?
    private let cacheWriteDotted: Int?
    private let cacheCreationDotted: Int?
    private let cacheWriteUnderscored: Int?
    private let cacheCreationUnderscored: Int?
    private let reasoningOutputTokens: Int?
    private let reasoningTokensValue: Int?

    enum CodingKeys: String, CodingKey {
        case operationName = "gen_ai.operation.name"
        case eventName = "event.name"
        case responseID = "gen_ai.response.id"
        case responseModel = "gen_ai.response.model"
        case requestModel = "gen_ai.request.model"
        case provider = "gen_ai.provider.name"
        case conversationID = "gen_ai.conversation.id"
        case copilotSessionID = "copilot_chat.session_id"
        case copilotChatSessionID = "copilot_chat.chat_session_id"
        case sessionID = "session.id"
        case interactionID = "github.copilot.interaction_id"
        case inputTokens = "gen_ai.usage.input_tokens"
        case outputTokens = "gen_ai.usage.output_tokens"
        case cacheReadDotted = "gen_ai.usage.cache_read.input_tokens"
        case cacheReadUnderscored = "gen_ai.usage.cache_read_input_tokens"
        case cacheWriteDotted = "gen_ai.usage.cache_write.input_tokens"
        case cacheCreationDotted = "gen_ai.usage.cache_creation.input_tokens"
        case cacheWriteUnderscored = "gen_ai.usage.cache_write_input_tokens"
        case cacheCreationUnderscored = "gen_ai.usage.cache_creation_input_tokens"
        case reasoningOutputTokens = "gen_ai.usage.reasoning.output_tokens"
        case reasoningTokensValue = "gen_ai.usage.reasoning_tokens"
    }

    init() {
        operationName = nil
        eventName = nil
        responseID = nil
        responseModel = nil
        requestModel = nil
        provider = nil
        conversationID = nil
        copilotSessionID = nil
        copilotChatSessionID = nil
        sessionID = nil
        interactionID = nil
        inputTokens = nil
        outputTokens = nil
        cacheReadDotted = nil
        cacheReadUnderscored = nil
        cacheWriteDotted = nil
        cacheCreationDotted = nil
        cacheWriteUnderscored = nil
        cacheCreationUnderscored = nil
        reasoningOutputTokens = nil
        reasoningTokensValue = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationName = try? container.decodeIfPresent(String.self, forKey: .operationName)
        eventName = try? container.decodeIfPresent(String.self, forKey: .eventName)
        responseID = try? container.decodeIfPresent(String.self, forKey: .responseID)
        responseModel = try? container.decodeIfPresent(String.self, forKey: .responseModel)
        requestModel = try? container.decodeIfPresent(String.self, forKey: .requestModel)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        conversationID = try? container.decodeIfPresent(String.self, forKey: .conversationID)
        copilotSessionID = try? container.decodeIfPresent(String.self, forKey: .copilotSessionID)
        copilotChatSessionID = try? container.decodeIfPresent(String.self, forKey: .copilotChatSessionID)
        sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
        interactionID = try? container.decodeIfPresent(String.self, forKey: .interactionID)
        inputTokens = container.flexibleInt(forKey: .inputTokens)
        outputTokens = container.flexibleInt(forKey: .outputTokens)
        cacheReadDotted = container.flexibleInt(forKey: .cacheReadDotted)
        cacheReadUnderscored = container.flexibleInt(forKey: .cacheReadUnderscored)
        cacheWriteDotted = container.flexibleInt(forKey: .cacheWriteDotted)
        cacheCreationDotted = container.flexibleInt(forKey: .cacheCreationDotted)
        cacheWriteUnderscored = container.flexibleInt(forKey: .cacheWriteUnderscored)
        cacheCreationUnderscored = container.flexibleInt(forKey: .cacheCreationUnderscored)
        reasoningOutputTokens = container.flexibleInt(forKey: .reasoningOutputTokens)
        reasoningTokensValue = container.flexibleInt(forKey: .reasoningTokensValue)
    }

    var cacheReadTokens: Int? {
        firstPositive(cacheReadDotted, cacheReadUnderscored)
    }

    var cacheWriteTokens: Int? {
        firstPositive(
            cacheWriteDotted,
            cacheCreationDotted,
            cacheWriteUnderscored,
            cacheCreationUnderscored)
    }

    var reasoningTokens: Int? {
        firstPositive(reasoningOutputTokens, reasoningTokensValue)
    }
}

private struct CopilotSpanContext: Decodable {
    let traceID: String?
    let spanID: String?

    enum CodingKeys: String, CodingKey {
        case traceID = "traceId"
        case spanID = "spanId"
    }
}

private enum CopilotTimestamp: Decodable {
    case secondsAndNanoseconds(Int64, Int64)
    case scalar(Int64)

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            let seconds = try container.decode(Int64.self)
            let nanoseconds = try container.decode(Int64.self)
            self = .secondsAndNanoseconds(seconds, nanoseconds)
            return
        }
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .scalar(value)
            return
        }
        let value = try container.decode(String.self)
        guard let integer = Int64(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an integer timestamp")
        }
        self = .scalar(integer)
    }

    var date: Date? {
        let seconds: TimeInterval
        switch self {
        case let .secondsAndNanoseconds(rawSeconds, nanoseconds):
            seconds = TimeInterval(rawSeconds) + TimeInterval(nanoseconds) / 1_000_000_000
        case let .scalar(raw):
            guard raw > 0 else { return nil }
            switch raw {
            case 100_000_000_000_000_000...:
                seconds = TimeInterval(raw) / 1_000_000_000
            case 100_000_000_000_000...:
                seconds = TimeInterval(raw) / 1_000_000
            case 100_000_000_000...:
                seconds = TimeInterval(raw) / 1000
            default:
                seconds = TimeInterval(raw)
            }
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

private func validSpanIdentity(_ value: String?) -> String? {
    guard let value = value?.trimmedNonEmpty,
          value.contains(where: { $0 != "0" }) else {
        return nil
    }
    return value
}

private func firstPositive(_ values: Int?...) -> Int? {
    values.compactMap { $0 }.first { $0 > 0 }
}

private extension KeyedDecodingContainer {
    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}
