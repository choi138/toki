import Foundation
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSourceMountMonitorTests: XCTestCase {
    func test_monitorAllowsUnchangedSourceMounts() throws {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let mountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: { mountInfo })

        XCTAssertNoThrow(try monitor.validate())
    }

    func test_monitorRequiresRefreshWhenDatabaseMountMovesToBackup() {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let initialMountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let changedMountInfo = mountInfoLines(
            databaseRoot: "/home/example/.hermes/backups/state.db.corrupt",
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let provider = MountInfoSequence([initialMountInfo, changedMountInfo])
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: provider.next)

        XCTAssertThrowsError(try monitor.validate()) { error in
            guard let builderError = error as? AgentSnapshotBuilderError else {
                return XCTFail("Expected AgentSnapshotBuilderError, got \(error)")
            }
            XCTAssertTrue(builderError.requiresProcessRestart)
        }
    }

    func test_monitorRequiresRefreshWhenSidecarMountIsDeleted() {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let initialMountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let changedMountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal//deleted",
            shmRoot: "\(databaseURL.path)-shm")
        let provider = MountInfoSequence([initialMountInfo, changedMountInfo])
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: provider.next)

        XCTAssertThrowsError(try monitor.validate())
    }

    func test_monitorDecodesEscapedMountPaths() throws {
        let databaseURL = URL(fileURLWithPath: "/home/example/Usage Data/state.db")
        let escapedPath = "/home/example/Usage\\040Data/state.db"
        let mountInfo = mountInfoLines(
            databaseRoot: escapedPath,
            databaseMountPoint: escapedPath,
            walRoot: "\(escapedPath)-wal",
            shmRoot: "\(escapedPath)-shm")
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: { mountInfo })

        XCTAssertNoThrow(try monitor.validate())
    }

    func test_monitorIgnoresUnmonitoredMountChanges() throws {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let initialMountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
            + "\n900 1 8:1 /tmp/old /tmp/unrelated ro - ext4 /dev/test rw"
        let changedMountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
            + "\n900 1 8:1 /tmp/new /tmp/unrelated ro - ext4 /dev/test rw"
        let provider = MountInfoSequence([initialMountInfo, changedMountInfo])
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: provider.next)

        XCTAssertNoThrow(try monitor.validate())
    }

    func test_snapshotBuilderPreparationSurfacesMountRefresh() async {
        let homeURL = URL(fileURLWithPath: "/home/example")
        let databaseURL = homeURL.appendingPathComponent(".hermes/state.db")
        let initialMountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let changedMountInfo = mountInfoLines(
            databaseRoot: "/home/example/.hermes/backups/state.db.corrupt",
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let provider = MountInfoSequence([initialMountInfo, changedMountInfo])
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Hermes", usage: RawTokenUsage()),
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)])
        let builder = AgentSnapshotBuilder(
            home: homeURL,
            readerDescriptors: [descriptor],
            sourceMountInfoProvider: provider.next)

        do {
            try await builder.prepareForSync()
            XCTFail("Expected source mount refresh to stop synchronization")
        } catch let error as AgentSnapshotBuilderError {
            XCTAssertTrue(error.requiresProcessRestart)
        } catch {
            XCTFail("Expected AgentSnapshotBuilderError, got \(error)")
        }
    }

    // Invariant: mount metadata that is expected but unreadable must fail closed rather than
    // permanently disabling replacement detection.
    func test_monitorFailsClosedWhenInitialMountMetadataIsUnavailable() {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            requiresMountInfo: true,
            mountInfoProvider: { nil })

        XCTAssertThrowsError(try monitor.validate()) { error in
            guard case .sourceInspectionFailed? = error as? AgentSnapshotBuilderError else {
                return XCTFail("Expected sourceInspectionFailed, got \(error)")
            }
        }
    }

    func test_monitorAdoptsBaselineOnceMountMetadataBecomesReadable() throws {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let mountInfo = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let provider = MountInfoSequence([nil, mountInfo, mountInfo])
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            requiresMountInfo: true,
            mountInfoProvider: provider.next)

        XCTAssertNoThrow(try monitor.validate())
        XCTAssertNoThrow(try monitor.validate())
    }

    func test_monitorKeepsUnsupportedPlatformsAsNoOps() {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            requiresMountInfo: false,
            mountInfoProvider: { nil })

        XCTAssertNoThrow(try monitor.validate())
    }

    // Invariant: a deleted mount root must request a refresh even when it never changes, so a
    // baseline captured after an atomic replacement cannot pass equality indefinitely.
    func test_monitorRequiresRefreshWhenBaselineAlreadyCarriesDeletedRoot() {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let deletedMountInfo = mountInfoLines(
            databaseRoot: "\(databaseURL.path)//deleted",
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: { deletedMountInfo })

        XCTAssertThrowsError(try monitor.validate()) { error in
            guard case .sourceMountRefreshRequired? = error as? AgentSnapshotBuilderError else {
                return XCTFail("Expected sourceMountRefreshRequired, got \(error)")
            }
        }
    }

    // Invariant: monitoring covers every configured source path, not only the paths that happened
    // to be mounted when the baseline was captured.
    func test_monitorRequiresRefreshWhenAbsentSidecarLaterAppears() {
        let databaseURL = URL(fileURLWithPath: "/home/example/.hermes/state.db")
        let withoutWAL = """
        100 1 8:1 \(databaseURL.path) \(databaseURL.path) ro - ext4 /dev/test rw
        102 1 8:1 \(databaseURL.path)-shm \(databaseURL.path)-shm ro - ext4 /dev/test rw
        """
        let withWAL = mountInfoLines(
            databaseRoot: databaseURL.path,
            walRoot: "\(databaseURL.path)-wal",
            shmRoot: "\(databaseURL.path)-shm")
        let provider = MountInfoSequence([withoutWAL, withWAL])
        let monitor = AgentSourceMountMonitor(
            sourceLocations: [.file(databaseURL, includesSQLiteSidecars: true)],
            mountInfoProvider: provider.next)

        XCTAssertThrowsError(try monitor.validate()) { error in
            guard case .sourceMountRefreshRequired? = error as? AgentSnapshotBuilderError else {
                return XCTFail("Expected sourceMountRefreshRequired, got \(error)")
            }
        }
    }

    func test_onlySourceMountRefreshRequiresProcessRestart() {
        XCTAssertTrue(AgentSnapshotBuilderError.sourceMountRefreshRequired.requiresProcessRestart)
        XCTAssertFalse(AgentSnapshotBuilderError.readerFailed("Hermes").requiresProcessRestart)
        XCTAssertFalse(AgentSnapshotBuilderError.sourceInspectionFailed.requiresProcessRestart)
    }
}

private func mountInfoLines(
    databaseRoot: String,
    databaseMountPoint: String = "/home/example/.hermes/state.db",
    walRoot: String,
    shmRoot: String) -> String {
    """
    100 1 8:1 \(databaseRoot) \(databaseMountPoint) ro - ext4 /dev/test rw
    101 1 8:1 \(walRoot) \(databaseMountPoint)-wal ro - ext4 /dev/test rw
    102 1 8:1 \(shmRoot) \(databaseMountPoint)-shm ro - ext4 /dev/test rw
    """
}

private final class MountInfoSequence {
    private let lock = NSLock()
    private var values: [String?]

    init(_ values: [String?]) {
        self.values = values
    }

    func next() -> String? {
        lock.withLock {
            guard values.count > 1 else { return values.first ?? nil }
            return values.removeFirst()
        }
    }
}
