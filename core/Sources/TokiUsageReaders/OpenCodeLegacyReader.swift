import Foundation

enum OpenCodeLegacyReader {
    static func files(in root: URL, budget: OpenCodeReadBudget) throws -> [URL] {
        let directory = root.appendingPathComponent("storage/message")
        // Roots may explicitly be aliases; nested legacy trees may not escape the requested root.
        guard openCodeCanonicalURL(directory).path.hasPrefix(root.path + "/") else { return [] }
        guard let attributes = try openCodeAttributes(directory) else { return [] }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw OpenCodeReaderError.unreadableSource
        }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in failed = true
                return false
            }) else {
            throw OpenCodeReaderError.unreadableSource
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            try budget.consumeEntry()
            guard let attributes = try openCodeAttributes(url) else { continue }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink { enumerator.skipDescendants()
                continue
            }
            if type == .typeDirectory {
                if enumerator.level >= 2 { enumerator.skipDescendants() }
                continue
            }
            guard type == .typeRegular, url.pathExtension == "json", enumerator.level <= 2 else { continue }
            try budget.consumeFile()
            files.append(url)
        }
        if failed { throw OpenCodeReaderError.unreadableSource }
        try Task.checkCancellation()
        return files.sorted { $0.path < $1.path }
    }

    static func read(_ url: URL, root: URL, budget: OpenCodeReadBudget) throws -> OpenCodeMessage? {
        try Task.checkCancellation()
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw OpenCodeReaderError.unreadableSource
        }
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                throw OpenCodeReaderError.unreadableSource
            }
            if chunk.isEmpty { break }
            guard chunk.count <= budget.limits.maximumRecordBytes - data.count else {
                throw OpenCodeReaderError.limitExceeded
            }
            try budget.consumeBytes(chunk.count)
            data.append(chunk)
        }
        try Task.checkCancellation()
        // Legacy IDs come from the payload, never a basename that another session can reuse.
        var context = OpenCodeMessage.Context(
            namespace: openCodeRootNamespace(root), originID: openCodeCanonicalURL(url).path)
        if url.deletingLastPathComponent().path != root.appendingPathComponent("storage/message").path {
            context.fallbackSessionID = url.deletingLastPathComponent().lastPathComponent
        }
        return OpenCodeMessage.parse(data, context: context)
    }
}
