import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import TokiUsageReaders

struct AgentSyncService {
    let paths: AgentPaths
    let hubClient: any AgentHubClientProtocol
    let snapshotBuilder: any AgentSnapshotBuilding

    init(
        paths: AgentPaths = AgentPaths(),
        hubClient: any AgentHubClientProtocol = AgentHubClient(),
        snapshotBuilder: any AgentSnapshotBuilding = AgentSnapshotBuilder()) {
        self.paths = paths
        self.hubClient = hubClient
        self.snapshotBuilder = snapshotBuilder
    }

    func syncOnce(now: Date = Date()) async throws {
        let processLock = try AgentProcessLock.acquire(paths: paths)
        defer { _ = processLock }
        try await syncOnceHoldingLock(now: now, forceSnapshotBuild: false)
    }

    func fullRescanAndSync(now: Date = Date()) async throws {
        let processLock = try AgentProcessLock.acquire(paths: paths)
        defer { _ = processLock }
        try await snapshotBuilder.resetCaches()
        try await syncOnceHoldingLock(now: now, forceSnapshotBuild: true)
    }

    private func syncOnceHoldingLock(now: Date, forceSnapshotBuild: Bool) async throws {
        let configuration = try AgentConfigurationStore(paths: paths).load()
        let stateStore = AgentStateStore(paths: paths)
        let spool = AgentSpool(paths: paths)
        var state = try stateStore.load()
        state.lastAttemptAt = now

        do {
            try await snapshotBuilder.prepareForSync()
            for pending in try spool.pendingEnvelopes() {
                guard pending.envelope.deviceID == configuration.deviceID else {
                    throw AgentSyncError.pendingDeviceMismatch
                }
                let pendingSnapshot = try SnapshotCipher.open(
                    pending.envelope,
                    key: configuration.encryptionKey)
                try await hubClient.upload(pending.envelope, configuration: configuration)
                state.latestSequence = max(state.latestSequence, pending.envelope.sequence)
                state.lastUploadedContentDigest = try snapshotBuilder.contentDigest(pendingSnapshot)
                state.lastSourceSignature = nil
                try stateStore.save(state)
                try spool.remove(pending.url)
            }
            let sourceSignature = try await snapshotBuilder.sourceSignature(configuration: configuration, now: now)
            if !forceSnapshotBuild,
               let sourceSignature,
               state.lastSourceSignature == sourceSignature,
               state.lastUploadedContentDigest != nil {
                if try await heartbeatAccepted(
                    configuration: configuration,
                    latestSequence: state.latestSequence) {
                    state.lastSuccessfulSyncAt = now
                    state.lastError = nil
                    try stateStore.save(state)
                    return
                }
                try Self.invalidateSnapshotVerification(&state, stateStore: stateStore)
            }

            let snapshot = try await snapshotBuilder.build(configuration: configuration, now: now)
            let contentDigest = try snapshotBuilder.contentDigest(snapshot)
            if state.lastUploadedContentDigest == contentDigest {
                state.lastSourceSignature = try await snapshotBuilder.sourceSignature(
                    configuration: configuration,
                    now: now)
                try stateStore.save(state)
                if try await heartbeatAccepted(
                    configuration: configuration,
                    latestSequence: state.latestSequence) {
                    state.lastSuccessfulSyncAt = now
                    state.lastError = nil
                    try stateStore.save(state)
                    return
                }
                try Self.invalidateSnapshotVerification(&state, stateStore: stateStore)
            }
            guard state.latestSequence < UInt64.max else {
                throw AgentSyncError.sequenceExhausted
            }
            let sequence = state.latestSequence + 1
            let envelope = try SnapshotCipher.seal(
                snapshot,
                sequence: sequence,
                key: configuration.encryptionKey)
            guard TokiSyncValidation.isAcceptableEnvelopeTimestamp(envelope.generatedAt, now: now) else {
                throw AgentSyncError.invalidEnvelopeTimestamp
            }
            let spoolURL = try spool.enqueue(envelope)
            state.latestSequence = sequence
            try stateStore.save(state)

            try await hubClient.upload(envelope, configuration: configuration)
            try spool.remove(spoolURL)
            state.lastUploadedContentDigest = contentDigest
            state.lastSourceSignature = nil
            state.lastSuccessfulSyncAt = now
            state.lastError = nil
            try stateStore.save(state)
        } catch {
            state.lastError = Self.publicErrorDescription(error)
            try? stateStore.save(state)
            throw error
        }
    }

    func run() async throws -> Never {
        let processLock = try AgentProcessLock.acquire(paths: paths)
        defer { _ = processLock }
        let configuration = try AgentConfigurationStore(paths: paths).load()
        var consecutiveFailures = 0

        let initialDelay = Self.scheduledDelay(
            interval: configuration.syncIntervalSeconds,
            deviceID: configuration.deviceID,
            phase: "initial")
        try await Task.sleep(nanoseconds: UInt64(initialDelay) * 1_000_000_000)

        while true {
            do {
                try await syncOnceHoldingLock(now: Date(), forceSnapshotBuild: false)
                consecutiveFailures = 0
                let delay = Self.scheduledDelay(
                    interval: configuration.syncIntervalSeconds,
                    deviceID: configuration.deviceID,
                    phase: "success")
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveFailures = min(consecutiveFailures + 1, 8)
                let baseDelay = min(30 * (1 << (consecutiveFailures - 1)), configuration.syncIntervalSeconds)
                let jitterLimit = max(1, baseDelay / 5)
                let delay = baseDelay + Int.random(in: 0...jitterLimit)
                AgentConsole.writeError("sync failed; retrying in \(delay)s: \(Self.publicErrorDescription(error))")
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    static func publicErrorDescription(_ error: Error) -> String {
        let description = knownErrorDescription(error) ?? fallbackErrorDescription(error)
        return String(description.prefix(300))
    }

    private static func knownErrorDescription(_ error: Error) -> String? {
        switch error {
        case let error as AgentCommandError:
            error.localizedDescription
        case let error as AgentConfigurationError:
            error.localizedDescription
        case let error as AgentStateStoreError:
            error.localizedDescription
        case let error as AgentSpoolError:
            error.localizedDescription
        case let error as AgentProcessLockError:
            error.localizedDescription
        case let error as AgentSnapshotBuilderError:
            error.localizedDescription
        case let error as HermesUsageLedgerError:
            error.localizedDescription
        case let error as AgentHubClientError:
            error.localizedDescription
        case let error as AgentSyncError:
            error.localizedDescription
        case let error as SnapshotCipherError:
            error.localizedDescription
        case let error as RemoteUsageSnapshotValidationError:
            error.localizedDescription
        case let error as TokiSyncCodingError:
            error.localizedDescription
        default:
            nil
        }
    }

    private static func fallbackErrorDescription(_ error: Error) -> String {
        switch error {
        case let error as URLError:
            "The Hub network request failed with code \(error.code.rawValue)."
        case is DecodingError:
            "Toki Agent data could not be decoded."
        default:
            "Synchronization failed. Run `toki-agent doctor` and inspect the redacted status."
        }
    }

    static func scheduledDelay(interval: Int, deviceID: String, phase: String) -> Int {
        let jitterLimit = max(1, interval / 10)
        let digest = SnapshotCipher.digest("\(phase):\(deviceID)")
        let prefix = String(digest.prefix(8))
        let value = UInt64(prefix, radix: 16) ?? 0
        let jitter = Int(value % UInt64(jitterLimit + 1))
        return phase == "initial" ? jitter : interval + jitter
    }
}

private extension AgentSyncService {
    func heartbeatAccepted(
        configuration: AgentConfiguration,
        latestSequence: UInt64) async throws -> Bool {
        do {
            try await hubClient.heartbeat(
                configuration: configuration,
                latestSequence: latestSequence)
            return true
        } catch let error as AgentHubClientError {
            guard case .httpStatus(409) = error else { throw error }
            return false
        }
    }

    static func invalidateSnapshotVerification(
        _ state: inout AgentRuntimeState,
        stateStore: AgentStateStore) throws {
        state.lastSourceSignature = nil
        state.lastUploadedContentDigest = nil
        try stateStore.save(state)
    }
}

enum AgentSyncError: LocalizedError {
    case invalidEnvelopeTimestamp
    case pendingDeviceMismatch
    case sequenceExhausted

    var errorDescription: String? {
        switch self {
        case .invalidEnvelopeTimestamp:
            "The Agent clock is outside the Hub timestamp window. Correct the system clock and retry."
        case .pendingDeviceMismatch:
            "A pending snapshot belongs to a different pairing. Run `toki-agent unpair`, then pair again."
        case .sequenceExhausted:
            "The Agent upload sequence is exhausted. Run `toki-agent unpair`, then pair as a new device."
        }
    }
}
