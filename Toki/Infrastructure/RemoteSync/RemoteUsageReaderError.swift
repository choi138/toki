import Foundation

enum RemoteUsageReaderError: LocalizedError {
    case tooManyDevices
    case missingDeviceKey
    case conflictingSnapshots
    case staleSnapshot
    case staleDevice(String)

    var errorDescription: String? {
        switch self {
        case .tooManyDevices:
            "The Hub returned more than 64 device snapshots."
        case .missingDeviceKey:
            "A remote device encryption key is unavailable. Revoke and pair that device again."
        case .conflictingSnapshots:
            "The Hub returned conflicting snapshots for one device sequence."
        case .staleSnapshot:
            "The Hub returned an older snapshot than this Mac has already authenticated."
        case let .staleDevice(name):
            "Remote device \(name) has not checked in within its configured interval."
        }
    }
}
