import Foundation
import TokiSyncProtocol

extension AgentSnapshotBuilder {
    func contentDigest(_ snapshot: RemoteUsageSnapshot) throws -> String {
        let content = AgentSnapshotContent(
            device: snapshot.device,
            coveredFrom: snapshot.coveredFrom,
            coveredTo: snapshot.coveredTo,
            tokenEvents: snapshot.tokenEvents,
            costEvents: snapshot.costEvents,
            activityEvents: snapshot.activityEvents)
        return try SnapshotCipher.digest(TokiSyncCoding.makeEncoder().encode(content))
    }
}

private struct AgentSnapshotContent: Encodable {
    let device: RemoteDeviceDescriptor
    let coveredFrom: Date
    let coveredTo: Date
    let tokenEvents: [RemoteTokenEvent]
    let costEvents: [RemoteCostEvent]?
    let activityEvents: [RemoteActivityEvent]
}
