import CryptoKit
import Foundation

protocol SecurityAuditCacheStoring {
    func load() -> SecurityAuditCache
    func save(_ cache: SecurityAuditCache)
}

struct SecurityAuditCache: Codable, Equatable {
    var ruleSetIdentifier: String
    var entriesByPath: [String: SecurityAuditCachedFile]

    init(ruleSetIdentifier: String = "", entriesByPath: [String: SecurityAuditCachedFile] = [:]) {
        self.ruleSetIdentifier = ruleSetIdentifier
        self.entriesByPath = entriesByPath
    }

    enum CodingKeys: String, CodingKey {
        case ruleSetIdentifier
        case entriesByPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleSetIdentifier = try container.decodeIfPresent(String.self, forKey: .ruleSetIdentifier) ?? ""
        entriesByPath = try container.decode([String: SecurityAuditCachedFile].self, forKey: .entriesByPath)
    }
}

struct SecurityAuditCachedFile: Codable, Equatable {
    let ruleSetIdentifier: String
    let sourceName: String
    let path: String
    let fileSize: Int64
    let modificationDate: Date?
    let lineCount: Int
    let findings: [SecurityAuditCachedFinding]
    let lastScannedAt: Date
    let byteOffset: Int64
    let signature: SecurityAuditFileSignature
}

struct SecurityAuditFileSignature: Codable, Equatable {
    let prefixHash: String
    let headHash: String
    let tailHash: String
    let tailByteCount: Int
    let endedWithNewline: Bool

    enum CodingKeys: String, CodingKey {
        case prefixHash
        case headHash
        case tailHash
        case tailByteCount
        case endedWithNewline
    }

    init(
        prefixHash: String,
        headHash: String,
        tailHash: String,
        tailByteCount: Int,
        endedWithNewline: Bool) {
        self.prefixHash = prefixHash
        self.headHash = headHash
        self.tailHash = tailHash
        self.tailByteCount = tailByteCount
        self.endedWithNewline = endedWithNewline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefixHash = try container.decodeIfPresent(String.self, forKey: .prefixHash) ?? ""
        headHash = try container.decode(String.self, forKey: .headHash)
        tailHash = try container.decode(String.self, forKey: .tailHash)
        tailByteCount = try container.decode(Int.self, forKey: .tailByteCount)
        endedWithNewline = try container.decode(Bool.self, forKey: .endedWithNewline)
    }
}

struct SecurityAuditCachedFinding: Codable, Equatable {
    let sourceName: String
    let severity: SecuritySeverity
    let category: SecurityFindingCategory
    let ruleName: String
    let maskedEvidence: String
    let filePath: String
    let lineNumber: Int
    let detectedAt: Date?

    init(_ finding: SecurityFinding) {
        sourceName = finding.sourceName
        severity = finding.severity
        category = finding.category
        ruleName = finding.ruleName
        maskedEvidence = finding.maskedEvidence
        filePath = finding.location.filePath
        lineNumber = finding.location.lineNumber
        detectedAt = finding.detectedAt
    }

    var finding: SecurityFinding {
        SecurityFinding(
            sourceName: sourceName,
            severity: severity,
            category: category,
            ruleName: ruleName,
            maskedEvidence: maskedEvidence,
            location: SecurityFindingLocation(filePath: filePath, lineNumber: lineNumber),
            detectedAt: detectedAt)
    }
}

final class SecurityAuditCacheStore: SecurityAuditCacheStoring {
    private let cacheURL: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(cacheURL: URL = SecurityAuditCacheStore.defaultCacheURL(), fileManager: FileManager = .default) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        decoder = JSONDecoder()

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> SecurityAuditCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? decoder.decode(SecurityAuditCache.self, from: data) else {
            return SecurityAuditCache()
        }
        return cache
    }

    func save(_ cache: SecurityAuditCache) {
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Cache failures should never block a security scan.
        }
    }

    static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Toki", isDirectory: true)
            .appendingPathComponent("SecurityAuditCache.json")
    }
}

enum SecurityAuditCacheSignature {
    private static let signatureByteCount = 4096
    private static let chunkByteCount = 256 * 1024

    static func signature(for fileURL: URL, byteOffset: Int64) -> SecurityAuditFileSignature? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let availableBytes = max(0, byteOffset)
        var remainingBytes = availableBytes
        var headData = Data()
        var tailData = Data()
        var hasher = SHA256()

        while remainingBytes > 0 {
            let readCount = Int(min(Int64(chunkByteCount), remainingBytes))
            guard let chunk = try? handle.read(upToCount: readCount),
                  !chunk.isEmpty else {
                return nil
            }

            hasher.update(data: chunk)
            appendHeadData(&headData, chunk: chunk)
            appendTailData(&tailData, chunk: chunk)
            remainingBytes -= Int64(chunk.count)
        }

        return SecurityAuditFileSignature(
            prefixHash: hexString(from: hasher.finalize()),
            headHash: hash(headData),
            tailHash: hash(tailData),
            tailByteCount: tailData.count,
            endedWithNewline: tailData.last == 10)
    }

    static func matches(_ signature: SecurityAuditFileSignature, fileURL: URL, byteOffset: Int64) -> Bool {
        signature == self.signature(for: fileURL, byteOffset: byteOffset)
    }

    private static func appendHeadData(_ headData: inout Data, chunk: Data) {
        guard headData.count < signatureByteCount else { return }
        let remaining = signatureByteCount - headData.count
        headData.append(contentsOf: chunk.prefix(remaining))
    }

    private static func appendTailData(_ tailData: inout Data, chunk: Data) {
        tailData.append(chunk)
        if tailData.count > signatureByteCount {
            tailData.removeSubrange(tailData.startIndex..<(tailData.endIndex - signatureByteCount))
        }
    }

    private static func hash(_ data: Data) -> String {
        hexString(from: SHA256.hash(data: data))
    }

    private static func hexString(from digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
