import Foundation

struct OpenClawReadLimits {
    var maximumFiles = 4096
    var maximumEntries = 100_000
    var maximumDepth = 16
    var maximumFileBytes = 64 * 1024 * 1024
    var maximumRecordBytes = 1024 * 1024
    var maximumTotalBytes = 512 * 1024 * 1024
    var maximumRecords = 250_000
    var maximumSQLiteSteps = 50_000_000
}

enum OpenClawReadError: LocalizedError, Equatable {
    case unreadableSource
    case unsupportedSchema
    case unrecognizedTranscript
    case unsupportedArchive
    case sourceChanged
    case activeRollbackJournal
    case limitExceeded
    case sqlite(Int32)

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "OpenClaw source could not be read."
        case .unsupportedSchema: "OpenClaw database has an unsupported transcript schema."
        case .unrecognizedTranscript: "OpenClaw transcript contains no recognized records."
        case .unsupportedArchive: "OpenClaw compressed transcripts are not supported."
        case .sourceChanged: "OpenClaw source changed while its snapshot was being read."
        case .activeRollbackJournal: "OpenClaw database has a rollback journal; retry after the writer finishes."
        case .limitExceeded: "OpenClaw source exceeds the bounded read limit."
        case let .sqlite(code): "OpenClaw SQLite read failed (code \(code))."
        }
    }
}

final class OpenClawReadBudget {
    let limits: OpenClawReadLimits
    private var entries = 0
    private var files = 0
    private var records = 0
    private var bytes = 0
    private var sqliteSteps = 0

    init(limits: OpenClawReadLimits) {
        self.limits = limits
    }

    func entry() throws {
        try consume(1, total: &entries, maximum: limits.maximumEntries)
    }

    func file() throws {
        try consume(1, total: &files, maximum: limits.maximumFiles)
    }

    func record() throws {
        try consume(1, total: &records, maximum: limits.maximumRecords)
    }

    func readBytes(_ count: Int) throws {
        try consume(count, total: &bytes, maximum: limits.maximumTotalBytes)
    }

    func sqliteShouldInterrupt() -> Bool {
        sqliteSteps += 1000
        return Task.isCancelled || sqliteSteps > limits.maximumSQLiteSteps
    }

    private func consume(_ count: Int, total: inout Int, maximum: Int) throws {
        try Task.checkCancellation()
        let (next, overflow) = total.addingReportingOverflow(count)
        guard count >= 0, !overflow, next <= maximum else { throw OpenClawReadError.limitExceeded }
        total = next
    }
}

enum OpenClawTranscriptIO {
    static func forEachLine(
        at url: URL,
        budget: OpenClawReadBudget,
        beforeRead: () throws -> Void = {},
        _ body: (Data, Date?) -> Void) throws {
        let limits = budget.limits
        let lineLimits = PiCompatibleReadLimits(
            maximumFileCount: limits.maximumFiles,
            maximumFileBytes: limits.maximumFileBytes,
            maximumLineBytes: limits.maximumRecordBytes,
            maximumEventCount: limits.maximumRecords,
            maximumEntryCount: limits.maximumEntries)
        try beforeRead()
        try Task.checkCancellation()
        guard let before = try OpenClawFileSignature.capture(url) else { throw OpenClawReadError.unreadableSource }
        guard before.size <= UInt64(limits.maximumFileBytes) else { throw OpenClawReadError.limitExceeded }
        try budget.readBytes(Int(before.size))
        do {
            try forEachBoundedJSONLLine(at: url, limits: lineLimits) { line, _ in
                try budget.record()
                let data = Data(line.utf8)
                body(data, before.modified)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenClawReadError {
            throw error
        } catch let error as PiCompatibleReaderError {
            switch error {
            case .fileTooLarge, .lineTooLong, .tooManyFiles, .tooManyEvents, .tooManyEntries:
                throw OpenClawReadError.limitExceeded
            default: throw OpenClawReadError.unreadableSource
            }
        }
        guard try OpenClawFileSignature.capture(url) == before else { throw OpenClawReadError.sourceChanged }
    }
}

struct OpenClawFileSignature: Equatable {
    let device: UInt64?
    let inode: UInt64?
    let size: UInt64
    let modified: Date?
    let created: Date?

    static func capture(_ url: URL) throws -> Self? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { throw OpenClawReadError.unreadableSource }
            return Self(
                device: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                size: size.uint64Value, modified: attributes[.modificationDate] as? Date,
                created: attributes[.creationDate] as? Date)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return nil }
            throw OpenClawReadError.unreadableSource
        }
    }
}
