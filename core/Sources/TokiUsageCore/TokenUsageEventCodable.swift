import Foundation

extension TokenUsageEvent {
    struct SanitizedTokenCounts {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let reasoning: Int
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, source, model, provider
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens
        case cost, costIsKnown, attribution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decode(Int.self, forKey: .inputTokens)
        let output = try container.decode(Int.self, forKey: .outputTokens)
        let cacheRead = try container.decode(Int.self, forKey: .cacheReadTokens)
        let cacheWrite = try container.decode(Int.self, forKey: .cacheWriteTokens)
        let reasoning = try container.decode(Int.self, forKey: .reasoningTokens)
        guard Self.tokenCountsAreValid(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Token usage counters are outside the supported range"))
        }
        try self.init(
            timestamp: container.decode(Date.self, forKey: .timestamp),
            source: container.decode(String.self, forKey: .source),
            model: container.decodeIfPresent(String.self, forKey: .model),
            provider: container.decodeIfPresent(String.self, forKey: .provider),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            cost: container.decode(Double.self, forKey: .cost),
            costIsKnown: container.decodeIfPresent(Bool.self, forKey: .costIsKnown),
            attribution: container.decodeIfPresent(UsageAttribution.self, forKey: .attribution))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encode(reasoningTokens, forKey: .reasoningTokens)
        try container.encode(cost, forKey: .cost)
        try container.encodeIfPresent(costIsKnown, forKey: .costIsKnown)
        try container.encodeIfPresent(attribution, forKey: .attribution)
    }

    static func tokenCountsAreValid(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int) -> Bool {
        let validRange = 0...1_000_000_000
        return [input, output, cacheRead, cacheWrite, reasoning].allSatisfy(validRange.contains)
    }

    static func sanitizedTokenCounts(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int) -> SanitizedTokenCounts {
        guard tokenCountsAreValid(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning) else {
            return SanitizedTokenCounts(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
        }
        return SanitizedTokenCounts(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning)
    }
}
