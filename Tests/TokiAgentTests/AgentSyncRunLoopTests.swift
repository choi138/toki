import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore

final class AgentSyncRunLoopTests: XCTestCase {
    func test_runRetriesSourceInspectionFailuresBeforeRestarting() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let snapshotBuilder = PreparationFailingSnapshotBuilder(failure: .sourceInspectionFailed)
        let sleeper = RecordingAgentSyncSleeper(
            maximumSleepCount: AgentSyncService.sourceInspectionRestartThreshold)
        let service = AgentSyncService(
            paths: fixture.paths,
            snapshotBuilder: snapshotBuilder)

        do {
            _ = try await service.run(sleep: sleeper.sleep)
        } catch let error as AgentSnapshotBuilderError {
            guard case .sourceInspectionFailed = error else {
                return XCTFail("Expected sourceInspectionFailed, got \(error)")
            }
        } catch {
            return XCTFail("Expected AgentSnapshotBuilderError, got \(error)")
        }

        XCTAssertEqual(
            snapshotBuilder.prepareCallCount,
            AgentSyncService.sourceInspectionRestartThreshold)
        let retrySeconds = sleeper.sleptNanoseconds.dropFirst().map { Int($0 / 1_000_000_000) }
        XCTAssertEqual(retrySeconds.count, AgentSyncService.sourceInspectionRestartThreshold - 1)
        let firstRetry = try XCTUnwrap(retrySeconds.first)
        let secondRetry = try XCTUnwrap(retrySeconds.dropFirst().first)
        XCTAssertTrue((30...36).contains(firstRetry))
        XCTAssertTrue((60...72).contains(secondRetry))
        let state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(
            state.lastError,
            AgentSyncService.publicErrorDescription(AgentSnapshotBuilderError.sourceInspectionFailed))
    }

    func test_runRestartsImmediatelyWhenSourceMountRefreshIsRequired() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let snapshotBuilder = PreparationFailingSnapshotBuilder(failure: .sourceMountRefreshRequired)
        let sleeper = RecordingAgentSyncSleeper(maximumSleepCount: 1)
        let service = AgentSyncService(
            paths: fixture.paths,
            snapshotBuilder: snapshotBuilder)

        do {
            _ = try await service.run(sleep: sleeper.sleep)
        } catch let error as AgentSnapshotBuilderError {
            guard case .sourceMountRefreshRequired = error else {
                return XCTFail("Expected sourceMountRefreshRequired, got \(error)")
            }
        } catch {
            return XCTFail("Expected AgentSnapshotBuilderError, got \(error)")
        }

        XCTAssertEqual(snapshotBuilder.prepareCallCount, 1)
        XCTAssertEqual(sleeper.sleptNanoseconds.count, 1, "mount replacement must not add retry backoff")
        let state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(
            state.lastError,
            AgentSyncService.publicErrorDescription(AgentSnapshotBuilderError.sourceMountRefreshRequired))
    }
}

private final class PreparationFailingSnapshotBuilder: AgentSnapshotBuilding {
    private let lock = NSLock()
    private let failure: AgentSnapshotBuilderError
    private var preparationCalls = 0

    init(failure: AgentSnapshotBuilderError) {
        self.failure = failure
    }

    var prepareCallCount: Int {
        lock.withLock { preparationCalls }
    }

    func prepareForSync() async throws {
        lock.withLock { preparationCalls += 1 }
        throw failure
    }

    func build(configuration _: AgentConfiguration, now _: Date) async throws -> RemoteUsageSnapshot {
        throw AgentSyncRunLoopTestError.unexpectedSnapshotBuild
    }

    func contentDigest(_: RemoteUsageSnapshot) throws -> String {
        throw AgentSyncRunLoopTestError.unexpectedSnapshotBuild
    }
}

private final class RecordingAgentSyncSleeper {
    private let lock = NSLock()
    private let maximumSleepCount: Int
    private var delays: [UInt64] = []

    init(maximumSleepCount: Int) {
        self.maximumSleepCount = maximumSleepCount
    }

    var sleptNanoseconds: [UInt64] {
        lock.withLock { delays }
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        let exceededLimit = lock.withLock {
            delays.append(nanoseconds)
            return delays.count > maximumSleepCount
        }
        if exceededLimit {
            throw AgentSyncRunLoopTestError.unexpectedSleep
        }
    }
}

private enum AgentSyncRunLoopTestError: Error {
    case unexpectedSleep
    case unexpectedSnapshotBuild
}
