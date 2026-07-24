import Foundation

struct RemoteUsageReader: OriginPartitionedTokenReader {
    let name = "Remote Devices"
    private let configurationProvider: any RemoteSyncConfigurationProviding
    private let snapshotLoader: RemoteSnapshotLoader
    private let localAgentIdentityProvider: any LocalAgentIdentityProviding
    private let usageMapper = RemoteUsageMapper()

    init(
        configurationProvider: any RemoteSyncConfigurationProviding = RemoteSyncConfigurationStore(),
        client: any RemoteHubClientProtocol = RemoteHubClient(),
        cache: any RemoteSnapshotCaching = RemoteSnapshotCache(),
        anchorStore: any RemoteSnapshotAnchorStoring = RemoteSnapshotAnchorStore(),
        lifecycleCoordinator: RemoteSyncLifecycleCoordinator = .shared,
        localAgentIdentityProvider: any LocalAgentIdentityProviding = NoLocalAgentIdentityProvider()) {
        self.configurationProvider = configurationProvider
        self.localAgentIdentityProvider = localAgentIdentityProvider
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
        let localAgentDeviceID = localAgentIdentityProvider.deviceID(matching: configuration.hubURL)
        return snapshots.compactMap { snapshot in
            guard snapshot.device.id != localAgentDeviceID else { return nil }
            return usageMapper.usageSlice(from: snapshot, startDate: startDate, endDate: endDate)
        }
    }
}
