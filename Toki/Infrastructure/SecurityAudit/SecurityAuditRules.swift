import Foundation

struct SecurityAuditFileSource: Equatable {
    let name: String
    let rootURL: URL
    let allowedExtensions: Set<String>
}

struct SecurityAuditRule {
    let name: String
    let severity: SecuritySeverity
    let category: SecurityFindingCategory
    let pattern: NSRegularExpression
    let captureGroup: Int?
    let cacheKey: String
    let prefilter: (String) -> Bool
    let validator: (String) -> Bool

    init(
        name: String,
        severity: SecuritySeverity,
        category: SecurityFindingCategory,
        pattern: String,
        captureGroup: Int? = nil,
        cacheKey: String? = nil,
        prefilter: @escaping (String) -> Bool = { _ in true },
        validator: @escaping (String) -> Bool = SecurityAuditRules.defaultValidator) {
        self.name = name
        self.severity = severity
        self.category = category
        do {
            self.pattern = try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid security audit regex for \(name): \(error)")
        }
        self.captureGroup = captureGroup
        self.cacheKey = cacheKey ?? [
            name,
            severity.rawValue,
            category.rawValue,
            pattern,
            "\(captureGroup ?? -1)",
        ].joined(separator: "|")
        self.prefilter = prefilter
        self.validator = validator
    }
}

enum SecurityAuditRules {
    static let cacheVersion = "security-audit-rules-v2"

    private static let secretAssignmentPattern =
        #"(?i)\b[A-Z0-9_]*(?:SECRET|API[_-]?KEY|ACCESS[_-]?TOKEN|"#
            + #"AUTH[_-]?TOKEN|TOKEN|PASSWORD|PRIVATE[_-]?KEY)[A-Z0-9_]*"#
            + #"\b\s*[:=]\s*["']?([^"'\s,}#]{12,})"#

    static let defaults: [SecurityAuditRule] = [
        SecurityAuditRule(
            name: "OpenAI API key",
            severity: .high,
            category: .apiKey,
            pattern: #"\bsk-(?!ant-)(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b"#,
            prefilter: { $0.contains("sk-") }),
        SecurityAuditRule(
            name: "Anthropic API key",
            severity: .high,
            category: .apiKey,
            pattern: #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#,
            prefilter: { $0.contains("sk-ant-") }),
        SecurityAuditRule(
            name: "Google API key",
            severity: .high,
            category: .apiKey,
            pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#,
            prefilter: { $0.contains("AIza") }),
        SecurityAuditRule(
            name: "GitHub token",
            severity: .high,
            category: .accessToken,
            pattern: #"\b(?:gh[pousr]_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{20,}_[A-Za-z0-9_]{20,})\b"#,
            prefilter: { $0.contains("gh") }),
        SecurityAuditRule(
            name: "npm token",
            severity: .high,
            category: .accessToken,
            pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#,
            prefilter: { $0.contains("npm_") }),
        SecurityAuditRule(
            name: "Slack token",
            severity: .high,
            category: .accessToken,
            pattern: #"\bxox[abprs]-[A-Za-z0-9-]{20,}\b"#,
            prefilter: { $0.contains("xox") }),
        SecurityAuditRule(
            name: "AWS access key ID",
            severity: .high,
            category: .cloudCredential,
            pattern: #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
            prefilter: { $0.contains("AKIA") || $0.contains("ASIA") }),
        SecurityAuditRule(
            name: "Private key block",
            severity: .high,
            category: .privateKey,
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            prefilter: { $0.contains("PRIVATE KEY") },
            validator: { _ in true }),
        SecurityAuditRule(
            name: "JWT",
            severity: .medium,
            category: .jwt,
            pattern: #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
            prefilter: { $0.contains("eyJ") && $0.contains(".") },
            validator: SecurityAuditJWTValidator.isLikelyJWT),
        SecurityAuditRule(
            name: "Secret assignment",
            severity: .medium,
            category: .environmentSecret,
            pattern: secretAssignmentPattern,
            captureGroup: 1,
            prefilter: SecurityAuditRules.mightContainSecretAssignment),
    ]

    static func defaultValidator(_ value: String) -> Bool {
        !SecurityEvidenceMasker.isLikelyPlaceholder(value)
    }

    static func mightContainSecretAssignment(_ line: String) -> Bool {
        guard line.contains("=") || line.contains(":") else { return false }

        let normalized = line.lowercased()
        return [
            "secret",
            "api_key",
            "api-key",
            "apikey",
            "token",
            "password",
            "private_key",
            "private-key",
            "privatekey",
        ].contains { normalized.contains($0) }
    }

    static func cacheIdentifier(for rules: [SecurityAuditRule]) -> String {
        ([cacheVersion] + rules.map(\.cacheKey)).joined(separator: "\n")
    }
}

enum SecurityEvidenceMasker {
    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "****" }

        if trimmed.hasPrefix("-----BEGIN") {
            return "-----BEGIN ... PRIVATE KEY-----"
        }

        let prefix = String(trimmed.prefix(4))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    static func isLikelyPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .lowercased()

        guard normalized.count >= 12 else { return true }
        if normalized.allSatisfy({ $0 == "*" || $0 == "x" }) { return true }

        let fragments = [
            "example",
            "sample",
            "placeholder",
            "redacted",
            "changeme",
            "your_",
            "your-",
            "dummy",
            "fake",
            "test-token",
            "api_key_here",
        ]
        return fragments.contains { normalized.contains($0) }
    }
}

private enum SecurityAuditJWTValidator {
    static func isLikelyJWT(_ value: String) -> Bool {
        let segments = value.split(separator: ".")
        guard segments.count == 3,
              let headerData = base64URLDecodedData(String(segments[0])),
              let object = try? JSONSerialization.jsonObject(with: headerData),
              let header = object as? [String: Any] else {
            return false
        }
        return header["alg"] != nil || header["typ"] != nil
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }
}

enum SecurityAuditTimestampExtractor {
    private static let regex = try? NSRegularExpression(
        pattern: #""(?:timestamp|created_at|createdAt|date|time)"\s*:\s*"([^"]+)""#)

    private static let formatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    static func date(from line: String) -> Date? {
        guard let regex else { return nil }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: fullRange),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }

        let value = String(line[range])
        return formatters.lazy.compactMap { $0.date(from: value) }.first
    }
}
