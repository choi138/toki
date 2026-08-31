import Foundation
import TokiUsageCore

func finalizedAmpUsage(
    _ usage: RawTokenUsage,
    activityEvents: [ActivityTimeEvent<String>],
    clippingEndDate: Date,
    decodedThreadCount: Int,
    hadThreadDecodeFailure: Bool) throws -> RawTokenUsage {
    var usage = usage
    usage.mergeActivityEvents(
        activityEvents,
        source: AmpReader.sourceName,
        clippingEndDate: clippingEndDate)
    if decodedThreadCount == 0, hadThreadDecodeFailure {
        throw LocalUsageReaderDiagnosticError.decodeFailed(
            source: AmpReader.sourceName,
            stage: "thread")
    }
    return usage
}

struct AmpLedgerTokens: Decodable {
    let input: Int?
    let output: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case input, output, cacheReadInputTokens, cacheCreationInputTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try? container.decodeIfPresent(Int.self, forKey: .input)
        output = try? container.decodeIfPresent(Int.self, forKey: .output)
        cacheReadInputTokens = try? container.decodeIfPresent(
            Int.self,
            forKey: .cacheReadInputTokens)
        cacheCreationInputTokens = try? container.decodeIfPresent(
            Int.self,
            forKey: .cacheCreationInputTokens)
    }
}

struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                elements.append(value)
            } else {
                _ = try? container.superDecoder()
            }
        }
        self.elements = elements
    }
}

func nonnegativeAmpCost(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

func ampEpochDate(_ value: Int64) -> Date? {
    guard value > 0 else { return nil }
    let seconds = value >= 100_000_000_000 ? Double(value) / 1000 : Double(value)
    return Date(timeIntervalSince1970: seconds)
}
