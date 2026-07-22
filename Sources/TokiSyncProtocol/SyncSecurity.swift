import Foundation

public enum TokiSyncLimits {
    public static let maximumDevices = 64
    public static let maximumEnvelopeBytes = 8 * 1024 * 1024
    public static let maximumSingleSnapshotResponseBytes = maximumEnvelopeBytes + 1024
    public static let maximumStoredSnapshotBytes = 48 * 1024 * 1024
    public static let maximumSnapshotResponseBytes = 64 * 1024 * 1024
    public static let maximumPairingBundleBytes = 64 * 1024
    public static let maximumConfigurationFileBytes = 64 * 1024
    public static let maximumRegistryBytes = 1024 * 1024
    public static let maximumAgentResponseBytes = 64 * 1024
    public static let maximumManagementResponseBytes = 64 * 1024
    public static let maximumHubURLBytes = 2048
    public static let maximumHubHostBytes = 253
    public static let defaultRetentionDays = 90
    public static let minimumRetentionDays = 1
    public static let maximumRetentionDays = 366
    public static let defaultSyncIntervalSeconds = 900
    public static let minimumSyncIntervalSeconds = 60
    public static let maximumSyncIntervalSeconds = 86400
    public static let staleIntervalMultiplier = 4

    public static func maximumFreshnessAge(syncIntervalSeconds: Int) -> TimeInterval {
        TimeInterval(syncIntervalSeconds) * TimeInterval(staleIntervalMultiplier)
    }
}

public enum TokiSyncValidation {
    private static let unsafeDirectionalScalars = CharacterSet(charactersIn:
        "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    public static func isAllowedHubURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let hasValidPort = components.rangeOfPort == nil
            || url.port.map { (1...65535).contains($0) } == true
        guard url.absoluteString.utf8.count <= TokiSyncLimits.maximumHubURLBytes,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              hasValidPort,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              host.utf8.count <= TokiSyncLimits.maximumHubHostBytes else {
            return false
        }

        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    public static func isSafeDeviceID(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func normalizedDeviceName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeDisplayText(normalized, maximumLength: 80) else { return nil }
        return normalized
    }

    public static func isSafeCredential(_ value: String) -> Bool {
        guard (32...512).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    public static func isSafeDisplayText(_ value: String, maximumLength: Int) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let (maximumBytes, overflow) = maximumLength.multipliedReportingOverflow(by: 8)
        guard maximumLength > 0,
              !overflow,
              !normalized.isEmpty,
              normalized == value,
              normalized.count <= maximumLength,
              normalized.utf8.count <= maximumBytes else {
            return false
        }
        return normalized.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) &&
                !CharacterSet.illegalCharacters.contains($0) &&
                !unsafeDirectionalScalars.contains($0)
        }
    }
}
