import Foundation
import TokiSyncProtocol

struct AgentSnapshotEventLimits: Equatable {
    static let protocolMaximum = AgentSnapshotEventLimits(
        maximumTokenEventCount: RemoteUsageSnapshotValidator.maximumTokenEventCount,
        maximumCostEventCount: RemoteUsageSnapshotValidator.maximumCostEventCount,
        maximumActivityEventCount: RemoteUsageSnapshotValidator.maximumActivityEventCount,
        maximumEnvelopeBytes: TokiSyncLimits.maximumEnvelopeBytes)

    let maximumTokenEventCount: Int
    let maximumCostEventCount: Int
    let maximumActivityEventCount: Int
    let maximumEnvelopeBytes: Int

    init(
        maximumTokenEventCount: Int,
        maximumCostEventCount: Int,
        maximumActivityEventCount: Int,
        maximumEnvelopeBytes: Int = TokiSyncLimits.maximumEnvelopeBytes) {
        self.maximumTokenEventCount = maximumTokenEventCount
        self.maximumCostEventCount = maximumCostEventCount
        self.maximumActivityEventCount = maximumActivityEventCount
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
    }
}

struct AgentSnapshotEventBounder {
    typealias EnvelopeFitCheck = (RemoteUsageSnapshot, String) throws -> Bool

    let limits: AgentSnapshotEventLimits
    private let envelopeFitCheck: EnvelopeFitCheck?

    init(
        limits: AgentSnapshotEventLimits,
        envelopeFitCheck: EnvelopeFitCheck? = nil) {
        self.limits = limits
        self.envelopeFitCheck = envelopeFitCheck
    }

    func snapshot(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent],
        encryptionKey: String) throws -> RemoteUsageSnapshot {
        let cutoffs = cutoffCandidates(
            coveredFrom: coveredFrom,
            generatedAt: generatedAt,
            tokenEvents: tokenEvents,
            costEvents: costEvents,
            activityEvents: activityEvents)
        let fullSnapshot = makeSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: cutoffs[0],
            coveredTo: coveredTo,
            tokenEvents: tokenEvents,
            costEvents: costEvents,
            activityEvents: activityEvents)
        if try fitsUploadEnvelope(fullSnapshot, encryptionKey: encryptionKey) {
            return fullSnapshot
        }

        var lowerBound = 1
        var upperBound = cutoffs.count - 1
        var boundedSnapshot: RemoteUsageSnapshot?

        while lowerBound <= upperBound {
            let index = lowerBound + (upperBound - lowerBound) / 2
            let candidate = makeSnapshot(
                device: device,
                generatedAt: generatedAt,
                coveredFrom: cutoffs[index],
                coveredTo: coveredTo,
                tokenEvents: tokenEvents,
                costEvents: costEvents,
                activityEvents: activityEvents)
            if try fitsUploadEnvelope(candidate, encryptionKey: encryptionKey) {
                boundedSnapshot = candidate
                upperBound = index - 1
            } else {
                lowerBound = index + 1
            }
        }

        guard let boundedSnapshot else {
            throw SnapshotCipherError.payloadTooLarge
        }
        return boundedSnapshot
    }

    private func cutoffCandidates(
        coveredFrom: Date,
        generatedAt: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent]) -> [Date] {
        var candidates = [coveredFrom, generatedAt]
        func appendCutoffs(for timestamp: Date) {
            guard timestamp <= generatedAt else { return }
            candidates.append(timestamp)
            let cutoffAfterTimestamp = timestamp.addingTimeInterval(0.001)
            if cutoffAfterTimestamp <= generatedAt {
                candidates.append(cutoffAfterTimestamp)
            }
        }
        tokenEvents.forEach { appendCutoffs(for: $0.timestamp) }
        costEvents.forEach { appendCutoffs(for: $0.timestamp) }
        activityEvents.forEach { appendCutoffs(for: $0.timestamp) }
        candidates.sort()
        return candidates.reduce(into: []) { unique, candidate in
            if unique.last != candidate {
                unique.append(candidate)
            }
        }
    }

    private func makeSnapshot(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent]) -> RemoteUsageSnapshot {
        let boundedCosts = costEvents.filter { $0.timestamp >= coveredFrom }
        return RemoteUsageSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: tokenEvents.filter { $0.timestamp >= coveredFrom },
            costEvents: boundedCosts.isEmpty ? nil : boundedCosts,
            activityEvents: activityEvents.filter { $0.timestamp >= coveredFrom })
    }

    private func fitsUploadEnvelope(
        _ snapshot: RemoteUsageSnapshot,
        encryptionKey: String) throws -> Bool {
        if let envelopeFitCheck {
            return try envelopeFitCheck(snapshot, encryptionKey)
        }
        guard snapshot.tokenEvents.count <= max(0, limits.maximumTokenEventCount),
              (snapshot.costEvents?.count ?? 0) <= max(0, limits.maximumCostEventCount),
              snapshot.activityEvents.count <= max(0, limits.maximumActivityEventCount) else {
            return false
        }

        do {
            let envelope = try SnapshotCipher.seal(
                snapshot,
                sequence: UInt64.max,
                key: encryptionKey)
            let encodedEnvelope = try TokiSyncCoding.makeEncoder().encode(envelope)
            return envelope.payload.utf8.count <= max(0, limits.maximumEnvelopeBytes)
                && encodedEnvelope.count <= max(0, limits.maximumEnvelopeBytes)
        } catch SnapshotCipherError.payloadTooLarge {
            return false
        }
    }
}
