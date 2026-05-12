import Foundation
import SQLite3

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads Cursor's global usage state from the app's local SQLite store.
/// Aggregates one token-bearing assistant response per usage UUID.
struct CursorReader: TokenReader {
    let name = "Cursor"
    private let dbPathOverride: String?

    init(dbPathOverride: String? = nil) {
        self.dbPathOverride = dbPathOverride
    }

    private var dbPath: String {
        dbPathOverride
            ?? homeDir()
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return RawTokenUsage()
        }
        sqlite3_busy_timeout(db, 2000)

        let bubblePayloads = cursorQueryBubblePayloads(
            db: db,
            from: startDate,
            to: endDate)
        guard !Task.isCancelled else { return RawTokenUsage() }

        let composerPayloads: [String] = if Self.shouldIncludeLiveComposerContext(from: startDate, to: endDate) {
            cursorQueryLiveComposerPayloads(
                db: db,
                from: startDate,
                to: endDate)
        } else {
            []
        }
        guard !Task.isCancelled else { return RawTokenUsage() }

        return Self.usage(
            fromBubblePayloads: bubblePayloads,
            composerPayloads: composerPayloads,
            source: name,
            from: startDate,
            to: endDate)
    }
}

extension CursorReader {
    static func usage(
        fromBubblePayloads payloads: [String],
        source: String = "Cursor",
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromBubblePayloads: payloads,
            composerPayloads: [],
            source: source,
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromComposerPayloads payloads: [String],
        source: String = "Cursor",
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromBubblePayloads: [],
            composerPayloads: payloads,
            source: source,
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromBubblePayloads bubblePayloads: [String],
        composerPayloads: [String],
        source: String = "Cursor",
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let bubbles = decodePayloads(bubblePayloads, as: CursorBubble.self)
        let composers = decodePayloads(composerPayloads, as: CursorComposerRecord.self)
        return usage(fromBubbles: bubbles, composers: composers, source: source, from: startDate, to: endDate)
    }

    static func usage(
        fromBubbles bubbles: [CursorBubble],
        composers: [CursorComposerRecord],
        source: String = "Cursor",
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var result = summarizedBubbleUsage(
            from: bubbles,
            source: source,
            from: startDate,
            to: endDate)
        result += usage(
            fromComposers: composers,
            source: source,
            from: startDate,
            to: endDate)
        return result
    }

    static func usage(
        fromBubbles bubbles: [CursorBubble],
        source: String = "Cursor",
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        summarizedBubbleUsage(from: bubbles, source: source, from: startDate, to: endDate)
    }

    private static func usage(
        fromComposers composers: [CursorComposerRecord],
        source: String = "Cursor",
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let startMillis = Int64(startDate.timeIntervalSince1970 * 1000)
        let endMillis = Int64(endDate.timeIntervalSince1970 * 1000)

        var result = RawTokenUsage()

        for composer in composers {
            let contextTokensUsed = composer.contextTokensUsed ?? 0
            guard let activityAt = composer.activityAt,
                  activityAt >= startMillis,
                  activityAt < endMillis,
                  contextTokensUsed > 0 else {
                continue
            }

            let composerID = composer.composerId ?? "\(activityAt)"

            result.supplemental.append(
                SupplementalUsage(
                    id: "\(source)-context-\(composerID)",
                    label: "\(source) Context",
                    value: contextTokensUsed,
                    unit: .tokens,
                    source: source,
                    model: composer.modelID,
                    includedInTotals: false,
                    quality: .contextOnly))
        }

        return result
    }

    private static func summarizedBubbleUsage(
        from bubbles: [CursorBubble],
        source: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var modelByUsageIdentifier: [String: String] = [:]
        for bubble in bubbles {
            guard let usageIdentifier = bubble.usageIdentifier,
                  let modelID = bubble.modelID else { continue }
            modelByUsageIdentifier[usageIdentifier] = modelID
        }

        var seenUsageIdentifiers = Set<String>()
        var usage = RawTokenUsage()
        let orderedBubbles = bubbles
            .compactMap { bubble -> (CursorBubble, Date)? in
                let input = bubble.tokenCount?.inputTokens ?? 0
                let output = bubble.tokenCount?.outputTokens ?? 0
                guard input + output > 0,
                      let createdAt = bubble.createdAtDate,
                      createdAt >= startDate,
                      createdAt < endDate else {
                    return nil
                }
                return (bubble, createdAt)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                let lhsID = lhs.0.usageIdentifier ?? lhs.0.bubbleId ?? ""
                let rhsID = rhs.0.usageIdentifier ?? rhs.0.bubbleId ?? ""
                if lhsID != rhsID { return lhsID < rhsID }
                return (lhs.0.bubbleId ?? "") < (rhs.0.bubbleId ?? "")
            }
            .map(\.0)

        for bubble in orderedBubbles {
            let input = bubble.tokenCount?.inputTokens ?? 0
            let output = bubble.tokenCount?.outputTokens ?? 0

            guard input + output > 0,
                  let createdAt = bubble.createdAtDate,
                  createdAt >= startDate,
                  createdAt < endDate,
                  let usageIdentifier = bubble.usageIdentifier,
                  seenUsageIdentifiers.insert(usageIdentifier).inserted else {
                continue
            }

            let modelID = bubble.modelID ?? modelByUsageIdentifier[usageIdentifier]
            let requestTokens = input + output

            usage.inputTokens += input
            usage.outputTokens += output

            let requestCost: Double
            if let modelID, let price = modelPrice(for: modelID) {
                requestCost = price.cost(
                    input: input,
                    output: output,
                    cacheRead: 0,
                    cacheWrite: 0)
                usage.cost += requestCost
            } else {
                requestCost = 0
            }

            if let modelID {
                usage.perModel[modelID, default: PerModelUsage()].totalTokens += requestTokens
                usage.perModel[modelID, default: PerModelUsage()].cost += requestCost
                usage.perModel[modelID, default: PerModelUsage()].sources.insert(source)
            }

            usage.recordTokenEvent(
                timestamp: createdAt,
                source: source,
                model: modelID,
                inputTokens: input,
                outputTokens: output,
                cost: requestCost)
        }

        return usage
    }

    private static func decodePayloads<T: Decodable>(_ payloads: [String], as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        return payloads.compactMap { payload -> T? in
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    static func shouldIncludeLiveComposerContext(
        from startDate: Date,
        to endDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current) -> Bool {
        // Date-ranged totals come from append-only bubble rows. The mutable
        // composer snapshot is only safe to show as a live context overlay.
        let isSingleDay =
            calendar.dateComponents([.day], from: startDate, to: endDate).day == 1
        return isSingleDay
            && calendar.isDate(startDate, inSameDayAs: now)
            && startDate <= now
            && endDate > now
    }
}

enum SQLiteBind {
    case int64(Int64)
    case text(String)
}

private func cursorQueryBubblePayloads(
    db: OpaquePointer?,
    from startDate: Date,
    to endDate: Date) -> [String] {
    guard !Task.isCancelled else { return [] }

    let startText = cursorSQLiteTimestampString(for: startDate)
    let endText = cursorSQLiteTimestampString(for: endDate)
    let bubbleKeyBinds = cursorKeyRangeBinds(forPrefix: "bubbleId:")

    let tokenQuery = """
        SELECT CAST(value AS TEXT)
        FROM cursorDiskKV
        WHERE \(cursorKeyRangeSQL(forPrefix: "bubbleId:"))
        AND json_valid(CAST(value AS TEXT))
        AND json_extract(CAST(value AS TEXT), '$.tokenCount') IS NOT NULL
        AND (
            COALESCE(CAST(json_extract(CAST(value AS TEXT), '$.tokenCount.inputTokens') AS INTEGER), 0)
            + COALESCE(CAST(json_extract(CAST(value AS TEXT), '$.tokenCount.outputTokens') AS INTEGER), 0)
        ) > 0
        AND julianday(json_extract(CAST(value AS TEXT), '$.createdAt')) >= julianday(?)
        AND julianday(json_extract(CAST(value AS TEXT), '$.createdAt')) < julianday(?)
    """

    let tokenPayloads = cursorQueryPayloads(
        db: db,
        query: tokenQuery,
        binds: bubbleKeyBinds + [.text(startText), .text(endText)])
    guard !Task.isCancelled else { return [] }

    let usageIdentifiers = Set(
        cursorDecodePayloads(tokenPayloads, as: CursorBubble.self)
            .compactMap(\.usageIdentifier))
    let identifierList = Array(usageIdentifiers).sorted()
    guard !identifierList.isEmpty else {
        return tokenPayloads
    }

    let placeholders = Array(repeating: "?", count: identifierList.count).joined(separator: ", ")
    let modelQuery = """
        SELECT CAST(value AS TEXT)
        FROM cursorDiskKV
        WHERE \(cursorKeyRangeSQL(forPrefix: "bubbleId:"))
        AND json_valid(CAST(value AS TEXT))
        AND (
            json_extract(CAST(value AS TEXT), '$.tokenCount') IS NULL
            OR (
                COALESCE(CAST(json_extract(CAST(value AS TEXT), '$.tokenCount.inputTokens') AS INTEGER), 0)
                + COALESCE(CAST(json_extract(CAST(value AS TEXT), '$.tokenCount.outputTokens') AS INTEGER), 0)
            ) = 0
        )
        AND (
            json_extract(CAST(value AS TEXT), '$.modelInfo') IS NOT NULL
            OR json_extract(CAST(value AS TEXT), '$.modelName') IS NOT NULL
            OR json_extract(CAST(value AS TEXT), '$.model') IS NOT NULL
        )
        AND (
            json_extract(CAST(value AS TEXT), '$.requestId') IN (\(placeholders))
            OR json_extract(CAST(value AS TEXT), '$.usageUuid') IN (\(placeholders))
            OR json_extract(CAST(value AS TEXT), '$.bubbleId') IN (\(placeholders))
        )
    """
    let identifierBinds = identifierList.map(SQLiteBind.text)
    let modelPayloads = cursorQueryPayloads(
        db: db,
        query: modelQuery,
        binds: bubbleKeyBinds + identifierBinds + identifierBinds + identifierBinds)
    guard !Task.isCancelled else { return [] }

    return tokenPayloads + modelPayloads
}

private func cursorQueryLiveComposerPayloads(
    db: OpaquePointer?,
    from startDate: Date,
    to endDate: Date) -> [String] {
    guard !Task.isCancelled else { return [] }

    // composerData is a mutable live snapshot, not a historical log.
    // Only surface it for today's active view as context-only metadata.
    let startMillis = Int64(startDate.timeIntervalSince1970 * 1000)
    let endMillis = Int64(endDate.timeIntervalSince1970 * 1000)
    let composerKeyBinds = cursorKeyRangeBinds(forPrefix: "composerData:")

    let composerQuery = """
        SELECT CAST(value AS TEXT)
        FROM cursorDiskKV
        WHERE \(cursorKeyRangeSQL(forPrefix: "composerData:"))
        AND json_valid(CAST(value AS TEXT))
        AND CAST(COALESCE(
            json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'),
            json_extract(CAST(value AS TEXT), '$.createdAt')
        ) AS INTEGER) >= ?
        AND CAST(COALESCE(
            json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'),
            json_extract(CAST(value AS TEXT), '$.createdAt')
        ) AS INTEGER) < ?
        AND CAST(COALESCE(
            json_extract(CAST(value AS TEXT), '$.contextTokensUsed'),
            0
        ) AS INTEGER) > 0
    """

    return cursorQueryPayloads(
        db: db,
        query: composerQuery,
        binds: composerKeyBinds + [.int64(startMillis), .int64(endMillis)])
}

private func cursorKeyRangeSQL(forPrefix _: String) -> String {
    "key >= ? AND key < ?"
}

private func cursorKeyRangeBinds(forPrefix prefix: String) -> [SQLiteBind] {
    [.text(prefix), .text(cursorPrefixUpperBound(for: prefix))]
}

private func cursorPrefixUpperBound(for prefix: String) -> String {
    let scalars = Array(prefix.unicodeScalars)
    for index in scalars.indices.reversed() {
        var nextScalarValue = scalars[index].value + 1
        if (0xD800...0xDFFF).contains(nextScalarValue) {
            nextScalarValue = 0xE000
        }
        guard nextScalarValue <= 0x10FFFF,
              let nextScalar = UnicodeScalar(nextScalarValue) else {
            continue
        }

        var upperBoundScalars = String.UnicodeScalarView()
        upperBoundScalars.append(contentsOf: scalars[..<index])
        upperBoundScalars.append(nextScalar)
        return String(upperBoundScalars)
    }
    return prefix + "\u{10FFFF}"
}

private func cursorQueryPayloads(
    db: OpaquePointer?,
    query: String,
    binds: [SQLiteBind] = []) -> [String] {
    guard !Task.isCancelled else { return [] }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
        return []
    }
    defer { sqlite3_finalize(stmt) }

    for (index, value) in binds.enumerated() {
        let bindIndex = Int32(index + 1)
        let status: Int32 = switch value {
        case let .int64(intValue):
            sqlite3_bind_int64(stmt, bindIndex, intValue)
        case let .text(textValue):
            sqlite3_bind_text(stmt, bindIndex, textValue, -1, sqliteTransient)
        }
        guard status == SQLITE_OK else {
            return []
        }
    }

    var payloads: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard !Task.isCancelled else { return payloads }

        guard let text = sqlite3_column_text(stmt, 0) else { continue }
        payloads.append(String(cString: text))
    }
    return payloads
}

private func cursorDecodePayloads<T: Decodable>(_ payloads: [String], as type: T.Type) -> [T] {
    let decoder = JSONDecoder()
    return payloads.compactMap { payload -> T? in
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}

private func cursorSQLiteTimestampString(for date: Date) -> String {
    cursorSQLiteDateFormatter.string(from: date)
}

private let cursorSQLiteDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

struct CursorBubble: Decodable {
    let bubbleId: String?
    let usageUuid: String?
    let requestId: String?
    let createdAt: String?
    let tokenCount: TokenCount?
    let modelInfo: ModelInfo?
    let modelName: String?
    let model: String?

    var usageIdentifier: String? {
        usageUuid ?? requestId ?? bubbleId
    }

    var createdAtDate: Date? {
        createdAt.flatMap(DateParser.parse)
    }

    var modelID: String? {
        normalizedCursorModelID(modelInfo?.modelName ?? modelName ?? model)
    }

    struct TokenCount: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
    }

    struct ModelInfo: Decodable {
        let modelName: String?
    }
}

struct CursorComposerRecord: Decodable {
    let composerId: String?
    let createdAt: Int64?
    let lastUpdatedAt: Int64?
    let contextTokensUsed: Int?
    let usageData: [String: ReportedUsage]?
    let modelConfig: ModelConfig?
    let fullConversationHeadersOnly: [ConversationHeader]?

    var activityAt: Int64? {
        lastUpdatedAt ?? createdAt
    }

    var modelID: String? {
        normalizedCursorModelID(
            modelConfig?.modelName
                ?? (usageData?.count == 1 ? usageData?.keys.first : nil))
    }

    struct ConversationHeader: Decodable {
        let bubbleId: String?
        let type: Int?
    }

    struct ReportedUsage: Decodable {
        let amount: Int?
        let costInCents: Int?
    }

    struct ModelConfig: Decodable {
        let modelName: String?
    }
}

private func normalizedCursorModelID(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed != "default",
          trimmed != "composer-1" else {
        return nil
    }

    return trimmed
}
