import Foundation
import TokiUsageCore

/// Reads Amp thread records from the XDG data directory.
public struct AmpReader: TokenReader {
    public static let sourceName = "Amp"

    public let name = Self.sourceName
    private let threadsURLOverride: URL?

    public init(threadsURLOverride: URL? = nil) {
        self.threadsURLOverride = threadsURLOverride
    }

    private var threadsURL: URL {
        threadsURLOverride
            ?? LocalUsageReaderPaths().ampThreads
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let files = findFiles(in: threadsURL, withExtension: "json")
        let decoder = JSONDecoder()
        var canonicalPaths = Set<String>()
        var recordsByThread: [String: AmpThreadRecordGroup] = [:]
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var decodedThreadCount = 0
        var hadThreadDecodeFailure = false

        for file in files.sorted(by: { $0.path < $1.path }) {
            let canonicalPath = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPaths.insert(canonicalPath).inserted else {
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let thread = try? decoder.decode(AmpThread.self, from: data) else {
                hadThreadDecodeFailure = true
                continue
            }
            decodedThreadCount += 1

            let fileDate = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let threadID = thread.id?.trimmedNonEmpty
                ?? file.deletingPathExtension().lastPathComponent
            let createdDate = thread.created.flatMap(ampEpochDate)
            let fallbackDate = createdDate ?? fileDate
            var group = recordsByThread[threadID] ?? AmpThreadRecordGroup()
            group.workspaceRoot = group.workspaceRoot
                ?? thread.environment?.workspaceRoot?.trimmedNonEmpty
            group.workingDirectory = group.workingDirectory
                ?? thread.environment?.workingDirectory?.trimmedNonEmpty
            group.ledgerRecords.append(contentsOf: ampLedgerRecords(
                thread.usageLedger?.events?.elements ?? [],
                fallbackDate: fallbackDate))
            group.messageRecords.append(contentsOf: ampMessageRecords(
                thread.messages?.elements ?? [],
                fallbackDate: fallbackDate))
            recordsByThread[threadID] = group
        }

        appendAmpRecords(
            recordsByThread,
            from: startDate,
            to: endDate,
            usage: &result,
            activityEvents: &activityEvents)

        return try finalizedAmpUsage(
            result,
            activityEvents: activityEvents,
            clippingEndDate: endDate,
            decodedThreadCount: decodedThreadCount,
            hadThreadDecodeFailure: hadThreadDecodeFailure)
    }
}

private func appendAmpRecords(
    _ recordsByThread: [String: AmpThreadRecordGroup],
    from startDate: Date,
    to endDate: Date,
    usage: inout RawTokenUsage,
    activityEvents: inout [ActivityTimeEvent<String>]) {
    for threadID in recordsByThread.keys.sorted() {
        guard let group = recordsByThread[threadID] else { continue }
        let attribution = UsageAttribution(
            projectPath: group.projectPath,
            sessionID: threadID,
            quality: group.projectPath == nil ? .unknown : .exact)
        let records = reconciledAmpRecords(
            ledgerRecords: group.ledgerRecords,
            messageRecords: group.messageRecords)

        for record in records {
            guard record.timestamp >= startDate,
                  record.timestamp < endDate else {
                continue
            }

            guard let totalTokens = usage.accumulateTokenCounts(
                input: record.tokens.input,
                output: record.tokens.output,
                cacheRead: record.tokens.cacheRead,
                cacheWrite: record.tokens.cacheWrite) else {
                continue
            }
            let provider = inferredUsageProvider(from: record.model)
            usage.cost += record.cost ?? 0
            usage.accumulatePerModelUsage(
                model: record.model,
                source: AmpReader.sourceName,
                totalTokens: totalTokens,
                cost: record.cost ?? 0)
            usage.recordTokenEvent(
                timestamp: record.timestamp,
                source: AmpReader.sourceName,
                model: record.model,
                provider: provider,
                inputTokens: record.tokens.input,
                outputTokens: record.tokens.output,
                cacheReadTokens: record.tokens.cacheRead,
                cacheWriteTokens: record.tokens.cacheWrite,
                cost: record.cost ?? 0,
                costIsKnown: record.cost != nil,
                attribution: attribution)

            if totalTokens > 0 {
                activityEvents.append(ActivityTimeEvent(
                    streamID: threadID,
                    timestamp: record.timestamp,
                    key: UsageModelGrouping.groupingKey(for: record.model)))
            }
        }
    }
}

private func finalizedAmpUsage(
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

private struct AmpThread: Decodable {
    let id: String?
    let created: Int64?
    let environment: AmpEnvironment?
    let messages: LossyArray<AmpMessage>?
    let usageLedger: AmpUsageLedger?

    enum CodingKeys: String, CodingKey {
        case id, created, environment, messages, usageLedger
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        created = try? container.decodeIfPresent(Int64.self, forKey: .created)
        environment = try? container.decodeIfPresent(AmpEnvironment.self, forKey: .environment)
        messages = try? container.decodeIfPresent(LossyArray<AmpMessage>.self, forKey: .messages)
        usageLedger = try? container.decodeIfPresent(AmpUsageLedger.self, forKey: .usageLedger)
    }
}

private struct AmpEnvironment: Decodable {
    let workspaceRoot: String?
    let workingDirectory: String?
}

private struct AmpMessage: Decodable {
    let role: String?
    let messageId: Int64?
    let createdAt: String?
    let usage: AmpMessageUsage?
}

private struct AmpMessageUsage: Decodable {
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let credits: Double?
    let timestamp: String?
}

private struct AmpUsageLedger: Decodable {
    let events: LossyArray<AmpUsageLedgerEvent>?
}

private struct AmpUsageLedgerEvent: Decodable {
    let timestamp: String?
    let model: String?
    let credits: Double?
    let tokens: AmpLedgerTokens?
    let fromMessageId: Int64?
    let toMessageId: Int64?
}

private struct AmpLedgerTokens: Decodable {
    let input: Int?
    let output: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
}

private struct AmpTokenCounts: Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    private let hasInput: Bool
    private let hasOutput: Bool
    private let hasCacheRead: Bool
    private let hasCacheWrite: Bool

    init(messageUsage: AmpMessageUsage) {
        input = max(0, messageUsage.inputTokens ?? 0)
        output = max(0, messageUsage.outputTokens ?? 0)
        cacheRead = max(0, messageUsage.cacheReadInputTokens ?? 0)
        cacheWrite = max(0, messageUsage.cacheCreationInputTokens ?? 0)
        hasInput = messageUsage.inputTokens != nil
        hasOutput = messageUsage.outputTokens != nil
        hasCacheRead = messageUsage.cacheReadInputTokens != nil
        hasCacheWrite = messageUsage.cacheCreationInputTokens != nil
    }

    init(ledgerTokens: AmpLedgerTokens?) {
        input = max(0, ledgerTokens?.input ?? 0)
        output = max(0, ledgerTokens?.output ?? 0)
        cacheRead = max(0, ledgerTokens?.cacheReadInputTokens ?? 0)
        cacheWrite = max(0, ledgerTokens?.cacheCreationInputTokens ?? 0)
        hasInput = ledgerTokens?.input != nil
        hasOutput = ledgerTokens?.output != nil
        hasCacheRead = ledgerTokens?.cacheReadInputTokens != nil
        hasCacheWrite = ledgerTokens?.cacheCreationInputTokens != nil
    }

    private init(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        hasInput: Bool,
        hasOutput: Bool,
        hasCacheRead: Bool,
        hasCacheWrite: Bool) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.hasCacheRead = hasCacheRead
        self.hasCacheWrite = hasCacheWrite
    }

    func fillingMissingValues(from fallback: Self) -> Self {
        Self(
            input: hasInput ? input : fallback.input,
            output: hasOutput ? output : fallback.output,
            cacheRead: hasCacheRead ? cacheRead : fallback.cacheRead,
            cacheWrite: hasCacheWrite ? cacheWrite : fallback.cacheWrite,
            hasInput: hasInput || fallback.hasInput,
            hasOutput: hasOutput || fallback.hasOutput,
            hasCacheRead: hasCacheRead || fallback.hasCacheRead,
            hasCacheWrite: hasCacheWrite || fallback.hasCacheWrite)
    }

    func isCompatible(with other: Self) -> Bool {
        (!hasInput || !other.hasInput || input == other.input)
            && (!hasOutput || !other.hasOutput || output == other.output)
            && (!hasCacheRead || !other.hasCacheRead || cacheRead == other.cacheRead)
            && (!hasCacheWrite || !other.hasCacheWrite || cacheWrite == other.cacheWrite)
    }

    var totalTokens: Int {
        checkedTokenTotal(input, output, cacheRead, cacheWrite) ?? 0
    }
}

private struct AmpUsageRecord {
    let stableID: String
    let contentID: String
    let messageID: Int64?
    let sequenceIndex: Int
    let timestamp: Date
    let hasExplicitTimestamp: Bool
    let model: String?
    let tokens: AmpTokenCounts
    let cost: Double?
}

private struct AmpThreadRecordGroup {
    var workspaceRoot: String?
    var workingDirectory: String?
    var ledgerRecords: [AmpUsageRecord] = []
    var messageRecords: [AmpUsageRecord] = []

    var projectPath: String? {
        workspaceRoot ?? workingDirectory
    }
}

private struct AmpRecordMatchKey: Hashable {
    let model: String?
    let timestamp: Date
}

private struct LossyArray<Element: Decodable>: Decodable {
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

private func reconciledAmpRecords(
    ledgerRecords: [AmpUsageRecord],
    messageRecords: [AmpUsageRecord]) -> [AmpUsageRecord] {
    var result = coalescedAmpRecords(ledgerRecords)
    var consumedLedgerIndexes = Set<Int>()
    var unmatchedMessages: [AmpUsageRecord] = []
    var ledgerIndexesByMessageID: [Int64: [Int]] = [:]
    var ledgerIndexesByMatchKey: [AmpRecordMatchKey: [Int]] = [:]
    for (index, ledger) in result.enumerated() {
        if let messageID = ledger.messageID {
            ledgerIndexesByMessageID[messageID, default: []].append(index)
        }
        ledgerIndexesByMatchKey[
            AmpRecordMatchKey(model: ledger.model, timestamp: ledger.timestamp),
            default: []
        ].append(index)
    }

    for message in coalescedAmpRecords(messageRecords) {
        var candidateIndexes = ledgerIndexesByMatchKey[
            AmpRecordMatchKey(model: message.model, timestamp: message.timestamp)
        ] ?? []
        if let messageID = message.messageID {
            candidateIndexes.append(contentsOf: ledgerIndexesByMessageID[messageID] ?? [])
        }
        let matchingIndex = Set(candidateIndexes).sorted().first { index in
            guard !consumedLedgerIndexes.contains(index) else { return false }
            let ledger = result[index]
            if let messageID = message.messageID,
               let ledgerMessageID = ledger.messageID {
                return ledgerMessageID == messageID
                    && ampRecordsAreCompatible(ledger, message)
            }
            return ledger.model == message.model
                && ledger.tokens.isCompatible(with: message.tokens)
                && ledger.timestamp == message.timestamp
        }

        guard let matchingIndex else {
            unmatchedMessages.append(message)
            continue
        }

        consumedLedgerIndexes.insert(matchingIndex)
        result[matchingIndex] = mergeAmpRecord(
            ledger: result[matchingIndex],
            message: message)
    }

    result.append(contentsOf: unmatchedMessages)
    return result
        .filter { $0.tokens.totalTokens > 0 || $0.cost != nil }
        .sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.stableID < $1.stableID
        }
}

private func ampLedgerRecords(
    _ events: [AmpUsageLedgerEvent],
    fallbackDate: Date?) -> [AmpUsageRecord] {
    var occurrences: [String: Int] = [:]
    var records: [AmpUsageRecord] = []
    for (sequenceIndex, event) in events.enumerated() {
        let model = normalizedModelID(event.model)
        let explicitDate = event.timestamp.flatMap(DateParser.parse)
        guard let timestamp = explicitDate ?? fallbackDate else { continue }
        let tokens = AmpTokenCounts(ledgerTokens: event.tokens)
        let messageID = event.toMessageId.flatMap { $0 > 0 ? $0 : nil }
        let cost = nonnegativeAmpCost(event.credits)
        let fingerprint = ampContentFingerprint(
            model: model,
            timestamp: timestamp,
            hasExplicitTimestamp: explicitDate != nil)
        let occurrence = occurrences[fingerprint, default: 0]
        occurrences[fingerprint] = occurrence + 1
        let contentID = "\(fingerprint):\(occurrence)"
        records.append(AmpUsageRecord(
            stableID: messageID.map { "message:\($0)" } ?? contentID,
            contentID: contentID,
            messageID: messageID,
            sequenceIndex: sequenceIndex,
            timestamp: timestamp,
            hasExplicitTimestamp: explicitDate != nil,
            model: model,
            tokens: tokens,
            cost: cost))
    }
    return records
}

private func ampMessageRecords(
    _ messages: [AmpMessage],
    fallbackDate: Date?) -> [AmpUsageRecord] {
    var occurrences: [String: Int] = [:]
    var records: [AmpUsageRecord] = []
    for (sequenceIndex, message) in messages.enumerated() {
        guard message.role == "assistant",
              let usage = message.usage,
              let model = normalizedModelID(usage.model) else {
            continue
        }
        let explicitDate = usage.timestamp.flatMap(DateParser.parse)
            ?? message.createdAt.flatMap(DateParser.parse)
        guard let timestamp = explicitDate ?? fallbackDate else { continue }
        let tokens = AmpTokenCounts(messageUsage: usage)
        let messageID = message.messageId.flatMap { $0 > 0 ? $0 : nil }
        let cost = nonnegativeAmpCost(usage.credits)
        let fingerprint = ampContentFingerprint(
            model: model,
            timestamp: timestamp,
            hasExplicitTimestamp: explicitDate != nil)
        let occurrence = occurrences[fingerprint, default: 0]
        occurrences[fingerprint] = occurrence + 1
        let contentID = "\(fingerprint):\(occurrence)"
        records.append(AmpUsageRecord(
            stableID: messageID.map { "message:\($0)" } ?? contentID,
            contentID: contentID,
            messageID: messageID,
            sequenceIndex: sequenceIndex,
            timestamp: timestamp,
            hasExplicitTimestamp: explicitDate != nil,
            model: model,
            tokens: tokens,
            cost: cost))
    }
    return records
}

private func coalescedAmpRecords(_ records: [AmpUsageRecord]) -> [AmpUsageRecord] {
    var result: [AmpUsageRecord] = []
    for record in records {
        if let matchingIndex = result.firstIndex(where: {
            sameKindAmpRecordsMatch($0, record)
        }) {
            result[matchingIndex] = mergeAmpRecord(
                ledger: result[matchingIndex],
                message: record)
        } else {
            result.append(record)
        }
    }
    return result
}

private func sameKindAmpRecordsMatch(
    _ lhs: AmpUsageRecord,
    _ rhs: AmpUsageRecord) -> Bool {
    if let lhsMessageID = lhs.messageID,
       let rhsMessageID = rhs.messageID {
        return lhsMessageID == rhsMessageID
            && ampRecordsAreCompatible(lhs, rhs)
    }
    if lhs.messageID == nil, rhs.messageID == nil {
        return lhs.contentID == rhs.contentID
            && ampRecordsAreCompatible(lhs, rhs)
    }
    return lhs.contentID == rhs.contentID
        && lhs.tokens.isCompatible(with: rhs.tokens)
}

private func mergeAmpRecord(
    ledger: AmpUsageRecord,
    message: AmpUsageRecord) -> AmpUsageRecord {
    let messageID = ledger.messageID ?? message.messageID
    return AmpUsageRecord(
        stableID: messageID.map { "message:\($0)" } ?? ledger.stableID,
        contentID: ledger.contentID,
        messageID: messageID,
        sequenceIndex: ledger.sequenceIndex,
        timestamp: ledger.hasExplicitTimestamp ? ledger.timestamp : message.timestamp,
        hasExplicitTimestamp: ledger.hasExplicitTimestamp || message.hasExplicitTimestamp,
        model: ledger.model ?? message.model,
        tokens: ledger.tokens.fillingMissingValues(from: message.tokens),
        cost: ledger.cost ?? message.cost)
}

private func ampContentFingerprint(
    model: String?,
    timestamp: Date,
    hasExplicitTimestamp: Bool) -> String {
    [
        "content",
        model ?? "unknown",
        hasExplicitTimestamp ? String(timestamp.timeIntervalSince1970) : "fallback",
    ].joined(separator: ":")
}

private func ampRecordsAreCompatible(
    _ lhs: AmpUsageRecord,
    _ rhs: AmpUsageRecord) -> Bool {
    (lhs.model == nil || rhs.model == nil || lhs.model == rhs.model)
        && lhs.tokens.isCompatible(with: rhs.tokens)
        && (!lhs.hasExplicitTimestamp || !rhs.hasExplicitTimestamp || lhs.timestamp == rhs.timestamp)
}

private func nonnegativeAmpCost(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

private func ampEpochDate(_ value: Int64) -> Date? {
    guard value > 0 else { return nil }
    let seconds = value >= 100_000_000_000 ? Double(value) / 1000 : Double(value)
    return Date(timeIntervalSince1970: seconds)
}
