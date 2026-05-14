import Foundation

enum SecuritySeverity: String, CaseIterable, Identifiable, Comparable, Codable {
    case high
    case medium
    case low

    var id: String {
        rawValue
    }

    var displayName: String {
        rawValue.capitalized
    }

    private var sortRank: Int {
        switch self {
        case .high:
            0
        case .medium:
            1
        case .low:
            2
        }
    }

    static func < (lhs: SecuritySeverity, rhs: SecuritySeverity) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}

enum SecurityFindingCategory: String, CaseIterable, Identifiable, Codable {
    case apiKey
    case accessToken
    case cloudCredential
    case privateKey
    case jwt
    case environmentSecret

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .apiKey:
            "API Key"
        case .accessToken:
            "Access Token"
        case .cloudCredential:
            "Cloud Credential"
        case .privateKey:
            "Private Key"
        case .jwt:
            "JWT"
        case .environmentSecret:
            "Env Secret"
        }
    }
}

struct SecurityFindingLocation: Equatable, Hashable {
    let filePath: String
    let lineNumber: Int
}

struct SecurityFinding: Identifiable, Equatable, Hashable {
    let sourceName: String
    let severity: SecuritySeverity
    let category: SecurityFindingCategory
    let ruleName: String
    let maskedEvidence: String
    let location: SecurityFindingLocation
    let detectedAt: Date?

    var id: String {
        [
            sourceName,
            severity.rawValue,
            category.rawValue,
            ruleName,
            location.filePath,
            "\(location.lineNumber)",
            maskedEvidence,
        ].joined(separator: "|")
    }
}

struct SecurityAuditResult: Equatable {
    let scannedAt: Date
    let scannedSourceCount: Int
    let scannedFileCount: Int
    let scannedLineCount: Int
    let skippedSourceNames: [String]
    let findings: [SecurityFinding]

    var hasFindings: Bool {
        !findings.isEmpty
    }

    func count(for severity: SecuritySeverity) -> Int {
        findings.filter { $0.severity == severity }.count
    }
}

struct SecurityAuditRequest: Equatable {
    var enabledSourceNames: [String: Bool]
    var modifiedAfter: Date?

    init(enabledSourceNames: [String: Bool] = [:], modifiedAfter: Date? = nil) {
        self.enabledSourceNames = enabledSourceNames
        self.modifiedAfter = modifiedAfter
    }

    func isSourceEnabled(_ sourceName: String) -> Bool {
        enabledSourceNames[sourceName] ?? true
    }
}

struct SecurityAuditProgress: Equatable {
    enum Phase: String, Equatable {
        case preparing
        case discovering
        case scanning
        case finished
    }

    let phase: Phase
    let currentSourceName: String?
    let currentFileName: String?
    let completedFileCount: Int
    let totalFileCount: Int
    let scannedLineCount: Int
    let findingCount: Int

    static let idle = SecurityAuditProgress(
        phase: .preparing,
        currentSourceName: nil,
        currentFileName: nil,
        completedFileCount: 0,
        totalFileCount: 0,
        scannedLineCount: 0,
        findingCount: 0)

    var fractionCompleted: Double? {
        guard totalFileCount > 0 else { return nil }
        return min(1, max(0, Double(completedFileCount) / Double(totalFileCount)))
    }
}

typealias SecurityAuditProgressHandler = (SecurityAuditProgress) -> Void

protocol SecurityAuditScanning {
    func scan(request: SecurityAuditRequest, progress: SecurityAuditProgressHandler?) async -> SecurityAuditResult
}

extension SecurityAuditScanning {
    func scan(request: SecurityAuditRequest) async -> SecurityAuditResult {
        await scan(request: request, progress: nil)
    }
}
