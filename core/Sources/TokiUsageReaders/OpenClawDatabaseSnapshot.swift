import Foundation

/// Copy a stable DB/WAL pair before SQLite opens anything. SQLite may create or
/// update SHM read marks only in this private directory, never beside the source.
struct OpenClawDatabaseSnapshot {
    let directory: URL
    let databaseURL: URL
    let hasWAL: Bool

    init(source: URL, budget: OpenClawReadBudget) throws {
        let urls = ["", "-wal", "-journal"].map { URL(fileURLWithPath: source.path + $0) }
        let before = try urls.map { try OpenClawFileSignature.capture($0) }
        guard before[0] != nil else { throw OpenClawReadError.unreadableSource }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-openclaw-snapshot-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("openclaw-agent.sqlite")
        hasWAL = before[1] != nil
        do {
            try Self.validateRollbackJournal(urls[2], signature: before[2], budget: budget)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            for index in 0...1 {
                guard let signature = before[index] else { continue }
                let target = URL(fileURLWithPath: databaseURL.path + (index == 0 ? "" : "-wal"))
                try Self.copy(urls[index], to: target, expectedBytes: signature.size, budget: budget)
            }
            try Self.validateRollbackJournal(urls[2], signature: before[2], budget: budget)
            guard try urls.map({ try OpenClawFileSignature.capture($0) }) == before else {
                throw OpenClawReadError.sourceChanged
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError { throw CancellationError() }
            throw (error as? OpenClawReadError) ?? .unreadableSource
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func validateRollbackJournal(
        _ url: URL,
        signature: OpenClawFileSignature?,
        budget: OpenClawReadBudget) throws {
        guard let signature else { return }
        // TRUNCATE commits leave an empty journal. PERSIST commits invalidate
        // all 28 header bytes; an active, not-yet-synced header can have zero magic
        // bytes alone, so requiring only those bytes to be zero is insufficient.
        guard signature.size > 0 else { return }
        guard signature.size >= 28 else { throw OpenClawReadError.activeRollbackJournal }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 28) ?? Data()
        try budget.readBytes(header.count)
        guard header.count == 28 else { throw OpenClawReadError.sourceChanged }
        guard header.allSatisfy({ $0 == 0 }) else { throw OpenClawReadError.activeRollbackJournal }
    }

    private static func copy(
        _ source: URL,
        to target: URL,
        expectedBytes: UInt64,
        budget: OpenClawReadBudget) throws {
        guard expectedBytes <= UInt64(budget.limits.maximumTotalBytes) else {
            throw OpenClawReadError.limitExceeded
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(
            atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw OpenClawReadError.unreadableSource
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try budget.readBytes(data.count)
            copied += UInt64(data.count)
            guard copied <= expectedBytes else { throw OpenClawReadError.sourceChanged }
            try output.write(contentsOf: data)
        }
        guard copied == expectedBytes else { throw OpenClawReadError.sourceChanged }
    }
}
