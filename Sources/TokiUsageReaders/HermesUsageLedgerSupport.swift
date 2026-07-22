import Foundation
import TokiUsageCore

let hermesUsageLedgerSchemaVersion = 3
let hermesUsageLedgerPreviousSchemaVersion = 2
let hermesUsageLedgerLegacySchemaVersion = 1
let hermesUsageLedgerMaximumBytes = 16 * 1024 * 1024
let hermesUsageLedgerMaximumBaselines = 50000
let hermesUsageLedgerMaximumEvents = 100_000
let hermesLedgerMaximumCumulativeTokens = Int.max / 8
let hermesUsageLedgerMaximumEventTokenCount = 1_000_000_000

struct HermesSessionObservation {
    let sessionID: String
    let startedAt: Date
    let earliestActivityAt: Date?
    let latestActivityAt: Date?
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
    let projectName: String?
    let attributionQuality: AttributionQuality
}

struct HermesTokenCounters: Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int

    static let zero = Self(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0)

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    func hasDecrease(comparedTo previous: Self) -> Bool {
        inputTokens < previous.inputTokens
            || outputTokens < previous.outputTokens
            || cacheReadTokens < previous.cacheReadTokens
            || cacheWriteTokens < previous.cacheWriteTokens
            || reasoningTokens < previous.reasoningTokens
    }

    func subtracting(_ previous: Self) -> Self {
        Self(
            inputTokens: inputTokens - previous.inputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            cacheReadTokens: cacheReadTokens - previous.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens - previous.cacheWriteTokens,
            reasoningTokens: reasoningTokens - previous.reasoningTokens)
    }

    func isValid(maximum: Int = hermesLedgerMaximumCumulativeTokens) -> Bool {
        (0...maximum).contains(inputTokens)
            && (0...maximum).contains(outputTokens)
            && (0...maximum).contains(cacheReadTokens)
            && (0...maximum).contains(cacheWriteTokens)
            && (0...maximum).contains(reasoningTokens)
    }

    func canAdd(_ other: Self, maximum: Int) -> Bool {
        inputTokens <= maximum - other.inputTokens
            && outputTokens <= maximum - other.outputTokens
            && cacheReadTokens <= maximum - other.cacheReadTokens
            && cacheWriteTokens <= maximum - other.cacheWriteTokens
            && reasoningTokens <= maximum - other.reasoningTokens
    }

    func adding(_ other: Self) -> Self {
        Self(
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
            reasoningTokens: reasoningTokens + other.reasoningTokens)
    }

    func maximum(_ other: Self) -> Self {
        Self(
            inputTokens: Swift.max(inputTokens, other.inputTokens),
            outputTokens: Swift.max(outputTokens, other.outputTokens),
            cacheReadTokens: Swift.max(cacheReadTokens, other.cacheReadTokens),
            cacheWriteTokens: Swift.max(cacheWriteTokens, other.cacheWriteTokens),
            reasoningTokens: Swift.max(reasoningTokens, other.reasoningTokens))
    }

    func chunks(maximum: Int) -> [Self] {
        var inputTokens = inputTokens
        var outputTokens = outputTokens
        var cacheReadTokens = cacheReadTokens
        var cacheWriteTokens = cacheWriteTokens
        var reasoningTokens = reasoningTokens
        var chunks: [Self] = []
        while inputTokens > 0
            || outputTokens > 0
            || cacheReadTokens > 0
            || cacheWriteTokens > 0
            || reasoningTokens > 0 {
            let chunk = Self(
                inputTokens: min(inputTokens, maximum),
                outputTokens: min(outputTokens, maximum),
                cacheReadTokens: min(cacheReadTokens, maximum),
                cacheWriteTokens: min(cacheWriteTokens, maximum),
                reasoningTokens: min(reasoningTokens, maximum))
            chunks.append(chunk)
            inputTokens -= chunk.inputTokens
            outputTokens -= chunk.outputTokens
            cacheReadTokens -= chunk.cacheReadTokens
            cacheWriteTokens -= chunk.cacheWriteTokens
            reasoningTokens -= chunk.reasoningTokens
        }
        return chunks
    }
}

struct HermesUsageLedgerEvent: Codable, Equatable {
    let sessionIdentifier: String
    var timestamp: Date
    let model: String?
    var counters: HermesTokenCounters
    var cost: Double
    let projectName: String?
    let attributionQuality: AttributionQuality

    func canMerge(with other: Self) -> Bool {
        sessionIdentifier == other.sessionIdentifier
            && model == other.model
            && projectName == other.projectName
            && attributionQuality == other.attributionQuality
            && timestamp == other.timestamp
            && counters.canAdd(other.counters, maximum: hermesUsageLedgerMaximumEventTokenCount)
            && (cost + other.cost).isFinite
    }

    mutating func merge(_ other: Self) {
        timestamp = max(timestamp, other.timestamp)
        counters = HermesTokenCounters(
            inputTokens: counters.inputTokens + other.counters.inputTokens,
            outputTokens: counters.outputTokens + other.counters.outputTokens,
            cacheReadTokens: counters.cacheReadTokens + other.counters.cacheReadTokens,
            cacheWriteTokens: counters.cacheWriteTokens + other.counters.cacheWriteTokens,
            reasoningTokens: counters.reasoningTokens + other.counters.reasoningTokens)
        cost += other.cost
    }

    var isValid: Bool {
        hermesIdentifierIsValid(sessionIdentifier)
            && hermesDateIsValid(timestamp)
            && counters.isValid(maximum: hermesUsageLedgerMaximumEventTokenCount)
            && counters.totalTokens > 0
            && cost.isFinite
            && cost >= 0
            && model?.utf8.count ?? 0 <= 512
            && projectName?.utf8.count ?? 0 <= 512
    }
}

public struct HermesUsageLedgerStatus: Equatable {
    public let accurateSince: Date?
    public let unattributedSessionCount: Int
    public let unattributedTokens: Int
}

struct HermesUsageLedgerDocument: Codable, Equatable {
    let schemaVersion: Int
    let identifierKey: String
    let accurateSince: Date?
    var lastSuccessfulObservationAt: Date?
    var baselines: [String: HermesUsageLedgerBaseline]
    var unattributed: [String: HermesUsageLedgerCarryover]
    var events: [HermesUsageLedgerEvent]
}

struct HermesUsageLedgerPrivateDocument: Codable, Equatable {
    let schemaVersion: Int
    let accurateSince: Date?
    var lastSuccessfulObservationAt: Date?
    var baselines: [String: HermesUsageLedgerPrivateBaseline]
    var unattributed: [String: HermesUsageLedgerCarryover]
    var events: [HermesUsageLedgerPrivateEvent]

    init(_ document: HermesUsageLedgerDocument) {
        schemaVersion = document.schemaVersion
        accurateSince = document.accurateSince
        lastSuccessfulObservationAt = document.lastSuccessfulObservationAt
        baselines = document.baselines.mapValues(HermesUsageLedgerPrivateBaseline.init)
        unattributed = document.unattributed
        events = document.events.map(HermesUsageLedgerPrivateEvent.init)
    }

    func document(identifierKey: String) -> HermesUsageLedgerDocument {
        HermesUsageLedgerDocument(
            schemaVersion: schemaVersion,
            identifierKey: identifierKey,
            accurateSince: accurateSince,
            lastSuccessfulObservationAt: lastSuccessfulObservationAt,
            baselines: baselines.mapValues { $0.baseline },
            unattributed: unattributed,
            events: events.map(\.event))
    }
}

struct HermesUsageLedgerPrivateBaseline: Codable, Equatable {
    let startedAt: Date
    let lastActivityAt: Date
    let lastObservedAt: Date
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
    let attributionQuality: AttributionQuality

    init(_ baseline: HermesUsageLedgerBaseline) {
        startedAt = baseline.startedAt
        lastActivityAt = baseline.lastActivityAt
        lastObservedAt = baseline.lastObservedAt
        model = baseline.model
        counters = baseline.counters
        cost = baseline.cost
        attributionQuality = baseline.attributionQuality
    }

    var baseline: HermesUsageLedgerBaseline {
        HermesUsageLedgerBaseline(
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            lastObservedAt: lastObservedAt,
            model: model,
            counters: counters,
            cost: cost,
            projectName: nil,
            attributionQuality: attributionQuality)
    }
}

struct HermesUsageLedgerPrivateEvent: Codable, Equatable {
    let sessionIdentifier: String
    let timestamp: Date
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
    let attributionQuality: AttributionQuality

    init(_ event: HermesUsageLedgerEvent) {
        sessionIdentifier = event.sessionIdentifier
        timestamp = event.timestamp
        model = event.model
        counters = event.counters
        cost = event.cost
        attributionQuality = event.attributionQuality
    }

    var event: HermesUsageLedgerEvent {
        HermesUsageLedgerEvent(
            sessionIdentifier: sessionIdentifier,
            timestamp: timestamp,
            model: model,
            counters: counters,
            cost: cost,
            projectName: nil,
            attributionQuality: attributionQuality)
    }
}

struct HermesUsageLedgerVersionProbe: Decodable {
    let schemaVersion: Int
}

struct HermesUsageLedgerV1Document: Codable, Equatable {
    let schemaVersion: Int
    let identifierKey: String
    var baselines: [String: HermesUsageLedgerBaseline]
    var events: [HermesUsageLedgerEvent]
}

struct HermesUsageLedgerBaseline: Codable, Equatable {
    let startedAt: Date
    let lastActivityAt: Date
    let lastObservedAt: Date
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
    let projectName: String?
    let attributionQuality: AttributionQuality

    var isValid: Bool {
        hermesDateIsValid(startedAt)
            && hermesDateIsValid(lastActivityAt)
            && hermesDateIsValid(lastObservedAt)
            && lastActivityAt >= startedAt
            && lastObservedAt >= startedAt
            && counters.isValid()
            && cost.isFinite
            && cost >= 0
            && model?.utf8.count ?? 0 <= 512
            && projectName?.utf8.count ?? 0 <= 512
    }

    func metadataDiffers(from previous: Self) -> Bool {
        model != previous.model
            || counters != previous.counters
            || cost != previous.cost
            || attributionQuality != previous.attributionQuality
    }
}

struct HermesUsageLedgerCarryover: Codable, Equatable {
    let counters: HermesTokenCounters
    let cost: Double
    let firstObservedAt: Date

    var isValid: Bool {
        counters.isValid()
            && counters.totalTokens > 0
            && cost.isFinite
            && cost >= 0
            && hermesDateIsValid(firstObservedAt)
    }
}

public enum HermesUsageLedgerError: LocalizedError {
    case invalidLedger
    case invalidObservation
    case ledgerTooLarge
    case couldNotPersist
    case durabilityNotConfirmed
    case migrationRequired

    public var errorDescription: String? {
        switch self {
        case .invalidLedger:
            "The Hermes usage ledger is invalid or not private."
        case .invalidObservation:
            "Hermes returned an invalid cumulative usage observation."
        case .ledgerTooLarge:
            "The Hermes usage ledger exceeds its safe size limit."
        case .couldNotPersist:
            "The Hermes usage ledger could not be stored safely."
        case .durabilityNotConfirmed:
            "The Hermes usage ledger was replaced, but storage durability could not be confirmed."
        case .migrationRequired:
            "The Hermes usage ledger requires migration. Run `toki-agent migrate-hermes-ledger` first."
        }
    }
}

public func hermesUsageLedgerURL(
    paths: LocalUsageReaderPaths = LocalUsageReaderPaths(),
    scope: LocalUsageCacheScope = .application) -> URL {
    paths.cacheDirectory(for: scope).appendingPathComponent("hermes-usage-ledger.json")
}

public func hermesUsageLedgerIdentifierKeyURL(for ledgerURL: URL) -> URL {
    ledgerURL.deletingPathExtension().appendingPathExtension("key")
}

func validLatestActivity(
    _ latestActivityAt: Date?,
    startedAt: Date,
    observedAt: Date) -> Date? {
    guard let latestActivityAt,
          hermesDateIsValid(latestActivityAt),
          latestActivityAt >= startedAt else {
        return nil
    }
    return min(latestActivityAt, observedAt)
}

func validEarliestActivity(
    _ earliestActivityAt: Date?,
    startedAt: Date,
    observedAt: Date) -> Date? {
    guard let earliestActivityAt,
          hermesDateIsValid(earliestActivityAt),
          earliestActivityAt >= startedAt,
          earliestActivityAt <= observedAt else {
        return nil
    }
    return earliestActivityAt
}

func validLedgerObservationRange(_ document: HermesUsageLedgerDocument) -> Bool {
    switch (document.accurateSince, document.lastSuccessfulObservationAt) {
    case let (accurateSince?, lastSuccessfulObservationAt?):
        accurateSince <= lastSuccessfulObservationAt
    case (nil, nil), (_?, nil):
        true
    case (nil, _?):
        false
    }
}

func saturatedTokenSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}

func hermesUsageLedgerEventSort(
    _ lhs: HermesUsageLedgerEvent,
    _ rhs: HermesUsageLedgerEvent) -> Bool {
    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
    if lhs.sessionIdentifier != rhs.sessionIdentifier { return lhs.sessionIdentifier < rhs.sessionIdentifier }
    return (lhs.model ?? "") < (rhs.model ?? "")
}

func hermesIdentifierIsValid(_ identifier: String) -> Bool {
    identifier.utf8.count == 32
        && identifier.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
}

func hermesDateIsValid(_ date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite
}

func pathExistsIncludingSymbolicLink(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
        || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
}
