import Foundation

/// Count-only/ordinal history diagnostics. Never includes a profile path, identifier or session data.
public struct HermesCollectionHistoryStatus {
    public struct Profile {
        public let isDefault: Bool
        public let status: HermesUsageLedgerStatus?
    }

    public let profiles: [Profile]

    public var profileReadErrorCount: Int {
        profiles.filter { $0.status == nil }.count
    }

    public var initializedProfileCount: Int {
        profiles.filter { $0.status?.accurateSince != nil }.count
    }
}
