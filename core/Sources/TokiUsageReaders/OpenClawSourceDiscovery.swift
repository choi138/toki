import Foundation
import TokiSyncProtocol

// Archive classification follows the pinned tokScale scanner.rs.
// Upstream MIT attribution/license is reproduced in OpenClawMessageParser.swift.

struct OpenClawSource {
    enum Kind: Int {
        case database
        case transcript
    }

    let url: URL
    let kind: Kind
    let agentID: String
    let sessionID: String
}

enum OpenClawSourceDiscovery {
    static func sources(in roots: [URL], budget: OpenClawReadBudget) throws -> [OpenClawSource] {
        var seenRoots: Set<String> = []
        var seenFiles: Set<String> = []
        var sources: [OpenClawSource] = []
        for root in roots {
            try budget.entry()
            guard root.isFileURL else { throw OpenClawReadError.unreadableSource }
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            guard seenRoots.insert(canonical.path).inserted else { continue }
            try scan(canonical, budget: budget) { source in
                if seenFiles.insert(source.url.path).inserted {
                    try budget.file()
                    sources.append(source)
                }
            }
        }
        return sources.sorted {
            $0.kind.rawValue == $1.kind.rawValue ? $0.url.path < $1.url.path : $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private static func scan(
        _ root: URL,
        budget: OpenClawReadBudget,
        _ consume: (OpenClawSource) throws -> Void) throws {
        do {
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw OpenClawReadError.unreadableSource
            }
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return }
            throw OpenClawReadError.unreadableSource
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in failed = true
                return false
            }) else {
            throw OpenClawReadError.unreadableSource
        }
        for case let url as URL in enumerator {
            try budget.entry()
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                throw OpenClawReadError.unreadableSource
            }
            if values.isSymbolicLink == true || url.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            // macOS enumeration may return /private/var while the selected root resolves to /var.
            // Compare canonical component sequences, never offsets from differently spelled paths.
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalURL.pathComponents.starts(with: root.pathComponents) else {
                throw OpenClawReadError.unreadableSource
            }
            let relative = Array(canonicalURL.pathComponents.dropFirst(root.pathComponents.count))
            if isCodexHome(relative) {
                enumerator.skipDescendants()
                continue
            }
            guard relative.count <= budget.limits.maximumDepth else { throw OpenClawReadError.limitExceeded }
            guard values.isRegularFile == true else { continue }
            let kind: OpenClawSource.Kind
            if relative.count == 3, relative[1] == "agent", relative[2] == "openclaw-agent.sqlite" {
                kind = .database
            } else if isTranscriptName(url.lastPathComponent) {
                guard !url.lastPathComponent.hasSuffix(".zst"),
                      !url.lastPathComponent.hasSuffix(".gz"),
                      !url.lastPathComponent.hasSuffix(".zip") else { throw OpenClawReadError.unsupportedArchive }
                kind = .transcript
            } else {
                continue
            }
            let agent = relative.count > 1 ? root.appendingPathComponent(relative[0]) : root
            try consume(OpenClawSource(
                url: url.standardizedFileURL, kind: kind, agentID: SnapshotCipher.digest(agent.path),
                sessionID: sessionID(for: url)))
        }
        if failed { throw OpenClawReadError.unreadableSource }
    }

    private static func isCodexHome(_ relative: [String]) -> Bool {
        relative.count >= 3 && relative[1] == "agent" && relative[2] == "codex-home"
    }

    static func isTranscriptName(_ name: String) -> Bool {
        guard !isCheckpoint(name), let marker = name.range(of: ".jsonl"), marker.lowerBound != name.startIndex else {
            return false
        }
        let suffix = name[marker.upperBound...]
        return suffix.isEmpty || (suffix.hasPrefix(".")
            && !suffix.hasSuffix(".json") && !suffix.hasSuffix(".json.migrated"))
    }

    private static func isCheckpoint(_ name: String) -> Bool {
        let uncompressed = name.hasSuffix(".zst") ? String(name.dropLast(4)) : name
        let stem: String
        if uncompressed.hasSuffix(".jsonl") {
            stem = String(uncompressed.dropLast(6))
        } else if let marker = [".jsonl.deleted.", ".jsonl.reset."].compactMap({
            uncompressed.range(of: $0, options: .backwards)
        }).max(by: { $0.lowerBound < $1.lowerBound }) {
            stem = String(uncompressed[..<marker.lowerBound])
        } else {
            return false
        }
        guard let marker = stem.range(of: ".checkpoint.", options: [.backwards, .caseInsensitive]),
              marker.lowerBound != stem.startIndex else { return false }
        let uuid = String(stem[marker.upperBound...])
        let bytes = Array(uuid.lowercased().utf8)
        return bytes.count == 36 && UUID(uuidString: uuid) != nil
            && (49...53).contains(bytes[14]) && [56, 57, 97, 98].contains(bytes[19])
    }

    private static func sessionID(for url: URL) -> String {
        let name = url.lastPathComponent
        guard let marker = name.range(of: ".jsonl") else { return name }
        let stem = String(name[..<marker.lowerBound])
        if url.deletingLastPathComponent().lastPathComponent == "session-sqlite-import-archive",
           stem.hasPrefix("archive-tier."), stem.count > "archive-tier.".count {
            return String(stem.dropFirst("archive-tier.".count))
        }
        return stem
    }
}
