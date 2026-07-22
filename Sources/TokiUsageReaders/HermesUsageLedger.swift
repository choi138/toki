import Foundation
import TokiDurableStorage
import TokiSyncProtocol

public actor HermesUsageLedger {
    public static let shared = HermesUsageLedger(fileURL: hermesUsageLedgerURL())

    private let fileURL: URL
    private var document: HermesUsageLedgerDocument?
    private var isLoaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func refresh(
        observations: [HermesSessionObservation],
        observedAt: Date) throws {
        try loadIfNeeded()
        guard hermesDateIsValid(observedAt) else {
            throw HermesUsageLedgerError.invalidObservation
        }

        let previousSuccessfulObservationAt = document?.lastSuccessfulObservationAt
        let effectiveObservedAt = max(previousSuccessfulObservationAt ?? observedAt, observedAt)
        var candidate = try document ?? HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerSchemaVersion,
            identifierKey: identifierKeyForNewDocument(),
            accurateSince: effectiveObservedAt,
            lastSuccessfulObservationAt: nil,
            baselines: [:],
            unattributed: [:],
            events: [])
        let identifierHasher: SnapshotOpaqueIdentifierHasher
        do {
            identifierHasher = try SnapshotCipher.makeOpaqueIdentifierHasher(key: candidate.identifierKey)
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }

        var changed = document == nil
        for observation in observations.sorted(by: { $0.sessionID < $1.sessionID }) {
            let observationChanged = try apply(
                observation,
                observedAt: effectiveObservedAt,
                previousSuccessfulObservationAt: previousSuccessfulObservationAt,
                identifierHasher: identifierHasher,
                to: &candidate)
            changed = changed || observationChanged
        }

        if candidate.lastSuccessfulObservationAt != effectiveObservedAt {
            candidate.lastSuccessfulObservationAt = effectiveObservedAt
            changed = true
        }

        guard changed else { return }
        try validate(candidate)
        try persist(candidate)
    }

    func events(from startDate: Date, to endDate: Date) throws -> [HermesUsageLedgerEvent] {
        try loadIfNeeded()
        guard startDate < endDate else { return [] }
        return (document?.events ?? [])
            .filter { $0.timestamp >= startDate && $0.timestamp < endDate }
            .sorted(by: hermesUsageLedgerEventSort)
    }

    public func status() throws -> HermesUsageLedgerStatus {
        try loadIfNeeded()
        let unattributed = document?.unattributed.values ?? [String: HermesUsageLedgerCarryover]().values
        return HermesUsageLedgerStatus(
            accurateSince: document?.accurateSince,
            unattributedSessionCount: unattributed.count,
            unattributedTokens: unattributed.reduce(0) { total, carryover in
                saturatedTokenSum(total, carryover.counters.totalTokens)
            })
    }
}

private extension HermesUsageLedger {
    func apply(
        _ observation: HermesSessionObservation,
        observedAt: Date,
        previousSuccessfulObservationAt: Date?,
        identifierHasher: SnapshotOpaqueIdentifierHasher,
        to candidate: inout HermesUsageLedgerDocument) throws -> Bool {
        try validate(observation, observedAt: observedAt)
        let identifier = identifierHasher.identifier(for: observation.sessionID)
        let previous = candidate.baselines[identifier]
        let currentBaseline = baseline(
            for: observation,
            observedAt: observedAt,
            previous: previous)

        guard let previous else {
            candidate.baselines[identifier] = currentBaseline
            if initialUsageIsDated(
                observation,
                after: previousSuccessfulObservationAt,
                observedAt: observedAt) {
                append(
                    event(
                        identifier: identifier,
                        timestamp: initialTimestamp(
                            observation: observation,
                            observedAt: observedAt),
                        observation: observation,
                        counters: observation.counters,
                        cost: observation.cost),
                    to: &candidate.events)
            } else {
                try addUnattributed(
                    identifier: identifier,
                    counters: observation.counters,
                    cost: observation.cost,
                    observedAt: observedAt,
                    to: &candidate.unattributed)
            }
            return true
        }

        if observation.counters.hasDecrease(comparedTo: previous.counters) {
            candidate.baselines[identifier] = currentBaseline
            try addUnattributed(
                identifier: identifier,
                counters: observation.counters,
                cost: observation.cost,
                observedAt: observedAt,
                to: &candidate.unattributed)
            return true
        }

        let delta = observation.counters.subtracting(previous.counters)
        guard delta.totalTokens > 0 else {
            guard currentBaseline.metadataDiffers(from: previous) else { return false }
            candidate.baselines[identifier] = currentBaseline
            return true
        }
        let timestamp = incrementalTimestamp(
            observation: observation,
            previous: previous,
            observedAt: observedAt)
        let cost = incrementalCost(
            observation: observation,
            previous: previous,
            delta: delta)
        append(
            event(
                identifier: identifier,
                timestamp: timestamp,
                observation: observation,
                counters: delta,
                cost: cost),
            to: &candidate.events)
        candidate.baselines[identifier] = currentBaseline
        return true
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        let directory = fileURL.deletingLastPathComponent()
        if pathExistsIncludingSymbolicLink(directory) {
            do {
                try DurableFileIO.preparePrivateDirectory(directory)
            } catch {
                throw HermesUsageLedgerError.invalidLedger
            }
        }

        let data: Data?
        do {
            data = try DurableFileIO.readPrivate(
                from: fileURL,
                maximumByteCount: hermesUsageLedgerMaximumBytes)
        } catch DurableFileIOError.privateFileTooLarge {
            throw HermesUsageLedgerError.ledgerTooLarge
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }

        guard let data else {
            document = nil
            isLoaded = true
            return
        }
        let schemaVersion: Int
        do {
            schemaVersion = try JSONDecoder().decode(HermesUsageLedgerVersionProbe.self, from: data).schemaVersion
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }
        switch schemaVersion {
        case hermesUsageLedgerSchemaVersion:
            let decoded: HermesUsageLedgerPrivateDocument
            do {
                decoded = try JSONDecoder().decode(HermesUsageLedgerPrivateDocument.self, from: data)
            } catch {
                throw HermesUsageLedgerError.invalidLedger
            }
            let current = try decoded.document(identifierKey: loadIdentifierKey())
            try validate(current)
            document = current
        case hermesUsageLedgerPreviousSchemaVersion, hermesUsageLedgerLegacySchemaVersion:
            throw HermesUsageLedgerError.migrationRequired
        default:
            throw HermesUsageLedgerError.invalidLedger
        }
        isLoaded = true
    }

    private func persist(_ candidate: HermesUsageLedgerDocument) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(HermesUsageLedgerPrivateDocument(candidate))
        } catch {
            throw HermesUsageLedgerError.couldNotPersist
        }
        guard data.count <= hermesUsageLedgerMaximumBytes else {
            throw HermesUsageLedgerError.ledgerTooLarge
        }

        do {
            try DurableFileIO.preparePrivateDirectory(fileURL.deletingLastPathComponent())
            try persistIdentifierKeyIfNeeded(candidate.identifierKey)
            try DurableFileIO.writePrivate(data, to: fileURL)
            document = candidate
            isLoaded = true
        } catch DurableFileIOError.replacementCommittedDirectorySyncFailed {
            document = candidate
            isLoaded = true
            throw HermesUsageLedgerError.durabilityNotConfirmed
        } catch {
            throw HermesUsageLedgerError.couldNotPersist
        }
    }

    private var identifierKeyURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("key")
    }

    private func identifierKeyForNewDocument() throws -> String {
        if let data = try DurableFileIO.readPrivate(from: identifierKeyURL, maximumByteCount: 4096) {
            return try decodeIdentifierKey(data)
        }
        let key = SnapshotCipher.generateKey()
        try persistIdentifierKeyIfNeeded(key)
        return key
    }

    private func loadIdentifierKey() throws -> String {
        guard let data = try DurableFileIO.readPrivate(from: identifierKeyURL, maximumByteCount: 4096) else {
            throw HermesUsageLedgerError.invalidLedger
        }
        return try decodeIdentifierKey(data)
    }

    private func decodeIdentifierKey(_ data: Data) throws -> String {
        guard let key = String(data: data, encoding: .utf8),
              (try? SnapshotCipher.makeOpaqueIdentifierHasher(key: key)) != nil else {
            throw HermesUsageLedgerError.invalidLedger
        }
        return key
    }

    private func persistIdentifierKeyIfNeeded(_ key: String) throws {
        if let data = try DurableFileIO.readPrivate(from: identifierKeyURL, maximumByteCount: 4096) {
            guard try decodeIdentifierKey(data) == key else {
                throw HermesUsageLedgerError.invalidLedger
            }
            return
        }
        try DurableFileIO.writePrivate(Data(key.utf8), to: identifierKeyURL)
    }

    private func baseline(
        for observation: HermesSessionObservation,
        observedAt: Date,
        previous: HermesUsageLedgerBaseline?) -> HermesUsageLedgerBaseline {
        let latestActivityAt = validLatestActivity(
            observation.latestActivityAt,
            startedAt: observation.startedAt,
            observedAt: observedAt)
            ?? previous?.lastActivityAt
            ?? observation.startedAt
        return HermesUsageLedgerBaseline(
            startedAt: previous?.startedAt ?? observation.startedAt,
            lastActivityAt: latestActivityAt,
            lastObservedAt: observedAt,
            model: observation.model,
            counters: observation.counters,
            cost: observation.cost,
            projectName: observation.projectName,
            attributionQuality: observation.attributionQuality)
    }

    private func incrementalTimestamp(
        observation: HermesSessionObservation,
        previous: HermesUsageLedgerBaseline,
        observedAt: Date) -> Date {
        guard let latestActivityAt = validLatestActivity(
            observation.latestActivityAt,
            startedAt: observation.startedAt,
            observedAt: observedAt),
            latestActivityAt > previous.lastActivityAt else {
            return observedAt
        }
        return latestActivityAt
    }

    private func initialUsageIsDated(
        _ observation: HermesSessionObservation,
        after previousSuccessfulObservationAt: Date?,
        observedAt: Date) -> Bool {
        guard let previousSuccessfulObservationAt,
              previousSuccessfulObservationAt <= observedAt else {
            return false
        }
        if observation.startedAt >= previousSuccessfulObservationAt {
            return true
        }
        return validEarliestActivity(
            observation.earliestActivityAt,
            startedAt: observation.startedAt,
            observedAt: observedAt).map { $0 >= previousSuccessfulObservationAt } ?? false
    }

    private func initialTimestamp(
        observation: HermesSessionObservation,
        observedAt: Date) -> Date {
        validLatestActivity(
            observation.latestActivityAt,
            startedAt: observation.startedAt,
            observedAt: observedAt) ?? observation.startedAt
    }

    private func incrementalCost(
        observation: HermesSessionObservation,
        previous: HermesUsageLedgerBaseline,
        delta: HermesTokenCounters) -> Double {
        if observation.cost >= previous.cost {
            return observation.cost - previous.cost
        }
        guard let model = observation.model,
              let price = modelPrice(for: model) else {
            return 0
        }
        return price.cost(
            input: delta.inputTokens,
            output: delta.outputTokens + delta.reasoningTokens,
            cacheRead: delta.cacheReadTokens,
            cacheWrite: delta.cacheWriteTokens)
    }

    private func event(
        identifier: String,
        timestamp: Date,
        observation: HermesSessionObservation,
        counters: HermesTokenCounters,
        cost: Double) -> HermesUsageLedgerEvent {
        HermesUsageLedgerEvent(
            sessionIdentifier: identifier,
            timestamp: timestamp,
            model: observation.model,
            counters: counters,
            cost: cost,
            projectName: observation.projectName,
            attributionQuality: observation.attributionQuality)
    }

    private func append(
        _ event: HermesUsageLedgerEvent,
        to events: inout [HermesUsageLedgerEvent]) {
        let chunks = event.counters.chunks(maximum: hermesUsageLedgerMaximumEventTokenCount)
        var remainingCost = event.cost
        for (index, counters) in chunks.enumerated() {
            let isLast = index == chunks.index(before: chunks.endIndex)
            let cost = isLast
                ? remainingCost
                : min(remainingCost, event.cost * Double(counters.totalTokens) / Double(event.counters.totalTokens))
            remainingCost -= cost
            appendSingle(
                HermesUsageLedgerEvent(
                    sessionIdentifier: event.sessionIdentifier,
                    timestamp: event.timestamp,
                    model: event.model,
                    counters: counters,
                    cost: cost,
                    projectName: event.projectName,
                    attributionQuality: event.attributionQuality),
                to: &events)
        }
    }

    private func appendSingle(
        _ event: HermesUsageLedgerEvent,
        to events: inout [HermesUsageLedgerEvent]) {
        guard let index = events.lastIndex(where: { $0.canMerge(with: event) }) else {
            events.append(event)
            return
        }
        events[index].merge(event)
    }

    private func addUnattributed(
        identifier: String,
        counters: HermesTokenCounters,
        cost: Double,
        observedAt: Date,
        to carryovers: inout [String: HermesUsageLedgerCarryover]) throws {
        guard counters.totalTokens > 0 else { return }
        guard let existing = carryovers[identifier] else {
            carryovers[identifier] = HermesUsageLedgerCarryover(
                counters: counters,
                cost: cost,
                firstObservedAt: observedAt)
            return
        }
        guard existing.counters.canAdd(counters, maximum: hermesLedgerMaximumCumulativeTokens),
              (existing.cost + cost).isFinite else {
            throw HermesUsageLedgerError.invalidObservation
        }
        carryovers[identifier] = HermesUsageLedgerCarryover(
            counters: existing.counters.adding(counters),
            cost: existing.cost + cost,
            firstObservedAt: min(existing.firstObservedAt, observedAt))
    }

    private func validate(
        _ observation: HermesSessionObservation,
        observedAt: Date) throws {
        guard !observation.sessionID.isEmpty,
              observation.sessionID.utf8.count <= 4096,
              hermesDateIsValid(observation.startedAt),
              observation.startedAt <= observedAt,
              observation.earliestActivityAt.map(hermesDateIsValid) ?? true,
              observation.latestActivityAt.map(hermesDateIsValid) ?? true,
              observation.counters.isValid(),
              observation.cost.isFinite,
              observation.cost >= 0,
              observation.model?.utf8.count ?? 0 <= 512,
              observation.projectName?.utf8.count ?? 0 <= 512 else {
            throw HermesUsageLedgerError.invalidObservation
        }
    }

    private func validate(_ document: HermesUsageLedgerDocument) throws {
        guard document.schemaVersion == hermesUsageLedgerSchemaVersion,
              document.baselines.count <= hermesUsageLedgerMaximumBaselines,
              document.unattributed.count <= hermesUsageLedgerMaximumBaselines,
              document.events.count <= hermesUsageLedgerMaximumEvents,
              document.accurateSince.map(hermesDateIsValid) ?? true,
              document.lastSuccessfulObservationAt.map(hermesDateIsValid) ?? true,
              validLedgerObservationRange(document),
              (try? SnapshotCipher.makeOpaqueIdentifierHasher(key: document.identifierKey)) != nil,
              document.baselines.allSatisfy({ identifier, baseline in
                  hermesIdentifierIsValid(identifier) && baseline.isValid
              }),
              document.unattributed.allSatisfy({ identifier, carryover in
                  hermesIdentifierIsValid(identifier)
                      && document.baselines[identifier] != nil
                      && carryover.isValid
              }),
              document.events.allSatisfy(\.isValid) else {
            throw HermesUsageLedgerError.invalidLedger
        }
    }
}
