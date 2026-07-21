import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

func tokenCountLine(
    ts: String,
    input: Int,
    cachedInput: Int,
    output: Int,
    reasoning: Int,
    total: Int) -> String {
    tokenCountLine(
        ts: ts,
        input: input,
        cachedInput: cachedInput,
        output: output,
        reasoning: reasoning,
        total: total,
        additionalInfoFields: [])
}

func tokenCountLine(
    ts: String,
    input: Int,
    cachedInput: Int,
    output: Int,
    reasoning: Int,
    total: Int,
    lastUsage: TokenCountLineUsage) -> String {
    tokenCountLine(
        ts: ts,
        input: input,
        cachedInput: cachedInput,
        output: output,
        reasoning: reasoning,
        total: total,
        additionalInfoFields: [
            tokenUsageField("last_token_usage", usage: lastUsage),
        ])
}

private func tokenCountLine(
    ts: String,
    input: Int,
    cachedInput: Int,
    output: Int,
    reasoning: Int,
    total: Int,
    additionalInfoFields: [String]) -> String {
    let totalUsage = TokenCountLineUsage(
        input: input,
        cachedInput: cachedInput,
        output: output,
        reasoning: reasoning,
        total: total)
    let infoFields = [
        tokenUsageField("total_token_usage", usage: totalUsage),
    ] + additionalInfoFields

    return """
    {"timestamp":"\(ts)","type":"event_msg",\
    "payload":{"type":"token_count","info":{\(infoFields.joined(separator: ","))}}}
    """
}

private func tokenUsageField(_ name: String, usage: TokenCountLineUsage) -> String {
    """
    "\(name)":{"input_tokens":\(usage.input),\
    "cached_input_tokens":\(usage.cachedInput),\
    "output_tokens":\(usage.output),\
    "reasoning_output_tokens":\(usage.reasoning),\
    "total_tokens":\(usage.total)}
    """
}

func isoDate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}

struct TokenCountLineUsage {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    let total: Int

    init(
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int) {
        self.init(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: input + output)
    }

    init(
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoning = reasoning
        self.total = total
    }
}
