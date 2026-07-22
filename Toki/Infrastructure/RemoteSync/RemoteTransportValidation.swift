import Foundation
import TokiSyncProtocol

enum RemoteSnapshotManifestValidation {
    static func validated(
        _ devices: [RemoteDeviceSummary],
        now: Date = Date()) throws -> [RemoteDeviceSummary] {
        guard devices.count <= TokiSyncLimits.maximumDevices else {
            throw RemoteUsageReaderError.tooManyDevices
        }
        var deviceIDs = Set<String>()
        for device in devices {
            guard deviceIDs.insert(device.id).inserted,
                  TokiSyncValidation.isSafeDeviceID(device.id),
                  TokiSyncValidation.normalizedDeviceName(device.name) == device.name,
                  isSafeTimestamp(device.createdAt),
                  device.createdAt <= now.addingTimeInterval(86400),
                  device.lastSeenAt.map(isSafeTimestamp) != false,
                  device.lastSeenAt.map({ $0 <= now.addingTimeInterval(86400) }) != false,
                  device.latestSequence != 0,
                  (device.latestSequence == nil) == (device.lastSeenAt == nil),
                  (TokiSyncLimits.minimumSyncIntervalSeconds...TokiSyncLimits.maximumSyncIntervalSeconds)
                  .contains(device.syncIntervalSeconds) else {
                throw RemoteHubClientError.invalidPayload
            }
        }
        return devices.sorted { $0.id < $1.id }
    }

    private static func isSafeTimestamp(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= 946_684_800 && seconds <= 32_503_680_000
    }
}

enum RemoteEntityTag {
    static func isValid(_ value: String) -> Bool {
        guard value.count == 66, value.first == "\"", value.last == "\"" else { return false }
        return SnapshotCipher.isSHA256Digest(String(value.dropFirst().dropLast()))
    }
}
