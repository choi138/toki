import Foundation

struct RemoteUsageReader: OriginPartitionedTokenReader {
    let name = "Remote Devices"
    private let configurationProvider: any RemoteSyncConfigurationProviding
    private let snapshotLoader: RemoteSnapshotLoader
    private let usageMapper = RemoteUsageMapper(readerName: "Remote Devices")

    init(
        configurationProvider: any RemoteSyncConfigurationProviding = RemoteSyncConfigurationStore(),
        client: any RemoteHubClientProtocol = RemoteHubClient(),
        cache: any RemoteSnapshotCaching = RemoteSnapshotCache(),
        anchorStore: any RemoteSnapshotAnchorStoring = RemoteSnapshotAnchorStore(),
        lifecycleCoordinator: RemoteSyncLifecycleCoordinator = .shared) {
        self.configurationProvider = configurationProvider
        snapshotLoader = RemoteSnapshotLoader(
            configurationProvider: configurationProvider,
            client: client,
            cache: cache,
            anchorStore: anchorStore,
            lifecycleCoordinator: lifecycleCoordinator)
    }

    func readUsageByOrigin(from startDate: Date, to endDate: Date) async throws -> [UsageOriginSlice] {
        guard let configuration = try configurationProvider.load() else {
            return []
        }
        let snapshots = try await snapshotLoader.loadSnapshots(configuration: configuration)
        return snapshots.compactMap { snapshot in
            usageMapper.usageSlice(from: snapshot, startDate: startDate, endDate: endDate)
        }
    }
}
