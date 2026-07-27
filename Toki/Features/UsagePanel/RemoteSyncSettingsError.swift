import Foundation

enum RemoteSyncSettingsError: LocalizedError {
    case invalidURL
    case notConnected
    case missingDeviceName
    case invalidRetention
    case invalidSyncInterval
    case pairingCleanupRequired
    case revokeDevicesBeforeDisconnect

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid Hub URL."
        case .notConnected:
            "Connect a Hub first."
        case .missingDeviceName:
            "Enter a device name before creating a pairing bundle."
        case .invalidRetention:
            "Retention must be between 1 and 366 days."
        case .invalidSyncInterval:
            "The sync interval must be between 1 and 1,440 minutes."
        case .pairingCleanupRequired:
            "Pairing did not finish and automatic cleanup failed. Revoke the listed device before trying again."
        case .revokeDevicesBeforeDisconnect:
            "Revoke all devices before disconnecting so their encryption keys are not lost."
        }
    }
}
