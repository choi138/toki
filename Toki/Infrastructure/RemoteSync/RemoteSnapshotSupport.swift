import Foundation
import TokiSyncProtocol

struct RemoteSnapshotPayloadBudget {
    let maximumBytes: Int
    private(set) var usedBytes = 0

    var remainingBytes: Int {
        maximumBytes - usedBytes
    }

    init(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    mutating func consume(_ envelope: EncryptedUsageEnvelope) throws {
        let count = envelope.payload.utf8.count
        guard count <= remainingBytes else {
            throw RemoteHubClientError.responseTooLarge
        }
        usedBytes += count
    }
}

enum RemoteDeviceFreshness {
    static func validate(_ devices: [RemoteDeviceSummary], now: Date = Date()) throws {
        for device in devices where device.latestSequence != nil {
            guard let lastSeenAt = device.lastSeenAt else {
                throw RemoteHubClientError.invalidPayload
            }
            let age = now.timeIntervalSince(lastSeenAt)
            let maximumAge = TokiSyncLimits.maximumFreshnessAge(
                syncIntervalSeconds: device.syncIntervalSeconds)
            guard age <= maximumAge else {
                throw RemoteUsageReaderError.staleDevice(device.name)
            }
        }
    }

    static func isStale(_ device: RemoteDeviceSummary, now: Date = Date()) -> Bool {
        guard device.latestSequence != nil, let lastSeenAt = device.lastSeenAt else { return false }
        return now.timeIntervalSince(lastSeenAt) > TokiSyncLimits.maximumFreshnessAge(
            syncIntervalSeconds: device.syncIntervalSeconds)
    }
}
