import Foundation

public enum RemoteUsageSnapshotValidator {
    public static let maximumTokenEventCount = 200_000
    public static let maximumActivityEventCount = 200_000
    public static let maximumTokenCountPerBucket = 1_000_000_000
    public static let maximumModelLength = 200

    public static func validate(_ snapshot: RemoteUsageSnapshot, now: Date = Date()) throws {
        guard snapshot.schemaVersion == TokiSyncProtocolVersion.current else {
            throw RemoteUsageSnapshotValidationError.unsupportedVersion(snapshot.schemaVersion)
        }
        guard TokiSyncValidation.isSafeDeviceID(snapshot.device.id),
              TokiSyncValidation.isSafeDisplayText(snapshot.device.name, maximumLength: 80),
              TokiSyncValidation.isSafeDisplayText(snapshot.device.platform, maximumLength: 32) else {
            throw RemoteUsageSnapshotValidationError.invalidDevice
        }
        guard isFinite(snapshot.generatedAt),
              isFinite(snapshot.coveredFrom),
              isFinite(snapshot.coveredTo),
              snapshot.coveredFrom < snapshot.coveredTo,
              snapshot.coveredTo.timeIntervalSince(snapshot.coveredFrom) <= 367 * 86400,
              snapshot.generatedAt >= snapshot.coveredFrom,
              snapshot.generatedAt < snapshot.coveredTo,
              snapshot.generatedAt <= now.addingTimeInterval(86400) else {
            throw RemoteUsageSnapshotValidationError.invalidDateRange
        }
        guard snapshot.tokenEvents.count <= maximumTokenEventCount else {
            throw RemoteUsageSnapshotValidationError.tooManyEvents
        }
        guard snapshot.activityEvents.count <= maximumActivityEventCount else {
            throw RemoteUsageSnapshotValidationError.tooManyEvents
        }

        for event in snapshot.tokenEvents {
            guard event.timestamp >= snapshot.coveredFrom,
                  event.timestamp < snapshot.coveredTo,
                  TokiSyncValidation.isSafeDisplayText(event.source, maximumLength: 40),
                  isOptionalBoundedText(event.model, maximumLength: maximumModelLength),
                  validTokenCount(event.inputTokens),
                  validTokenCount(event.outputTokens),
                  validTokenCount(event.cacheReadTokens),
                  validTokenCount(event.cacheWriteTokens),
                  validTokenCount(event.reasoningTokens) else {
                throw RemoteUsageSnapshotValidationError.invalidTokenEvent
            }
        }

        for event in snapshot.activityEvents {
            guard event.timestamp >= snapshot.coveredFrom,
                  event.timestamp < snapshot.coveredTo,
                  TokiSyncValidation.isSafeDisplayText(event.source, maximumLength: 40),
                  isOptionalBoundedText(event.model, maximumLength: maximumModelLength),
                  TokiSyncValidation.isSafeDisplayText(event.streamID, maximumLength: 128) else {
                throw RemoteUsageSnapshotValidationError.invalidActivityEvent
            }
        }
    }

    private static func validTokenCount(_ value: Int) -> Bool {
        (0...maximumTokenCountPerBucket).contains(value)
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
    }

    private static func isOptionalBoundedText(_ value: String?, maximumLength: Int) -> Bool {
        guard let value else { return true }
        return TokiSyncValidation.isSafeDisplayText(value, maximumLength: maximumLength)
    }
}

public enum RemoteUsageSnapshotValidationError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidDevice
    case invalidDateRange
    case tooManyEvents
    case invalidTokenEvent
    case invalidActivityEvent

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Remote usage protocol version \(version) is not supported."
        case .invalidDevice:
            "The remote snapshot contains invalid device metadata."
        case .invalidDateRange:
            "The remote snapshot contains an invalid date range."
        case .tooManyEvents:
            "The remote snapshot contains too many events."
        case .invalidTokenEvent:
            "The remote snapshot contains an invalid token event."
        case .invalidActivityEvent:
            "The remote snapshot contains an invalid activity event."
        }
    }
}
