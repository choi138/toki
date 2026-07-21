import Foundation

enum HubStoreError: LocalizedError {
    case unauthorized
    case invalidDeviceName
    case invalidSyncInterval
    case tooManyDevices
    case deviceNotFound
    case unsupportedVersion
    case deviceMismatch
    case payloadTooLarge
    case storageQuotaExceeded
    case invalidTimestamp
    case staleSequence
    case sequenceConflict
    case storageDurabilityUnconfirmed
    case corruptedStorage

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "The device credential is not valid."
        case .invalidDeviceName:
            "The device name must contain 1 to 80 printable characters."
        case .invalidSyncInterval:
            "The device sync interval must be between 60 seconds and 24 hours."
        case .tooManyDevices:
            "The Hub supports at most 64 active devices."
        case .deviceNotFound:
            "The device was not found."
        case .unsupportedVersion:
            "The snapshot protocol version is not supported."
        case .deviceMismatch:
            "The snapshot device does not match the authenticated route."
        case .payloadTooLarge:
            "The encrypted snapshot exceeds the 8 MiB limit or is malformed."
        case .storageQuotaExceeded:
            "The Hub encrypted-snapshot quota is full. Reduce Agent retention or revoke a device."
        case .invalidTimestamp:
            "The snapshot timestamp is outside the accepted range."
        case .staleSequence:
            "The snapshot sequence is older than the stored snapshot."
        case .sequenceConflict:
            "A different snapshot already uses this sequence."
        case .storageDurabilityUnconfirmed:
            "The Hub committed the storage update but could not confirm its durability. Retry the request."
        case .corruptedStorage:
            "The Hub storage is inconsistent or corrupted."
        }
    }
}
