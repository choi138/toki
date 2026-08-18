import Foundation
import TokiUsageReaders

struct AgentSourceMountMonitor {
    typealias MountInfoProvider = () -> String?

    /// Marker the kernel appends to a mount root once its backing file is replaced or removed.
    private static let deletedRootMarker = "//deleted"

    /// Whether the running platform is expected to expose process mount metadata.
    ///
    /// This distinguishes "no metadata because this platform has none" from "no metadata because
    /// the read failed", so an unreadable `/proc/self/mountinfo` cannot silently disable
    /// replacement detection on Linux.
    static var platformProvidesMountInfo: Bool {
        #if os(Linux)
            true
        #else
            false
        #endif
    }

    private let baseline: BaselineStore
    private let monitoredPaths: Set<String>
    private let mountInfoProvider: MountInfoProvider

    init(
        sourceLocations: [LocalUsageSourceLocation],
        requiresMountInfo: Bool = platformProvidesMountInfo,
        mountInfoProvider: @escaping MountInfoProvider = currentProcessMountInfo) {
        self.mountInfoProvider = mountInfoProvider
        let monitoredPaths = Self.monitoredPaths(for: sourceLocations)
        self.monitoredPaths = monitoredPaths
        if let mountInfo = mountInfoProvider() {
            baseline = BaselineStore(
                state: .monitoring(Self.mountRoots(in: mountInfo, monitoredPaths: monitoredPaths)))
        } else {
            baseline = BaselineStore(state: requiresMountInfo ? .unavailable : .unsupported)
        }
    }

    /// Confirms every monitored source still resolves to the mount it did when the baseline was
    /// captured.
    ///
    /// Throws `sourceInspectionFailed` when mount metadata is expected but unreadable, so a
    /// transient failure aborts the sync instead of permanently disabling detection, and
    /// `sourceMountRefreshRequired` when a monitored source was replaced or deleted.
    func validate() throws {
        guard baseline.expectsMountInfo else { return }
        guard let mountInfo = mountInfoProvider() else {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }
        let currentRoots = Self.mountRoots(in: mountInfo, monitoredPaths: monitoredPaths)
        let baselineRoots = baseline.resolve(capturing: currentRoots)

        guard !Self.containsDeletedRoot(baselineRoots),
              !Self.containsDeletedRoot(currentRoots),
              currentRoots == baselineRoots else {
            throw AgentSnapshotBuilderError.sourceMountRefreshRequired
        }
    }

    static func containsDeletedRoot(_ roots: [String: String]) -> Bool {
        roots.values.contains { $0.contains(deletedRootMarker) }
    }
}

private extension AgentSourceMountMonitor {
    enum BaselineState {
        /// The platform exposes no mount metadata, so replacement cannot and need not be detected.
        case unsupported
        /// Mount metadata is expected but was unreadable when the baseline was captured.
        case unavailable
        case monitoring([String: String])
    }

    /// Holds the baseline so an initialization that could not read mount metadata can still adopt
    /// one on the first successful validation instead of failing open forever.
    final class BaselineStore: @unchecked Sendable {
        private let lock = NSLock()
        private var state: BaselineState

        init(state: BaselineState) {
            self.state = state
        }

        /// Swift 5.9.2's corelibs Foundation, which the Linux Agent builds against, has no
        /// `NSLock.withLock`, so lock and unlock explicitly here.
        var expectsMountInfo: Bool {
            lock.lock()
            defer { lock.unlock() }
            if case .unsupported = state { return false }
            return true
        }

        func resolve(capturing currentRoots: [String: String]) -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            if case let .monitoring(roots) = state { return roots }
            state = .monitoring(currentRoots)
            return currentRoots
        }
    }
}

extension AgentSourceMountMonitor {
    struct MountEntry {
        let root: String
        let mountPoint: String
    }

    static func currentProcessMountInfo() -> String? {
        #if os(Linux)
            try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
        #else
            nil
        #endif
    }

    static func monitoredPaths(for sourceLocations: [LocalUsageSourceLocation]) -> Set<String> {
        sourceLocations.reduce(into: Set<String>()) { paths, location in
            let sourcePath = location.url.standardizedFileURL.path
            paths.insert(sourcePath)
            guard case let .file(_, includesSQLiteSidecars) = location,
                  includesSQLiteSidecars else {
                return
            }
            paths.insert("\(sourcePath)-wal")
            paths.insert("\(sourcePath)-shm")
        }
    }

    static func mountRoots(
        in mountInfo: String,
        monitoredPaths: Set<String>) -> [String: String] {
        mountInfo.split(whereSeparator: \.isNewline).reduce(into: [:]) { roots, line in
            guard let entry = mountEntry(from: line),
                  monitoredPaths.contains(entry.mountPoint) else {
                return
            }
            roots[entry.mountPoint] = entry.root
        }
    }

    static func mountEntry(from line: Substring) -> MountEntry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 6 else { return nil }
        return MountEntry(
            root: decodeMountInfoPath(fields[3]),
            mountPoint: decodeMountInfoPath(fields[4]))
    }

    static func decodeMountInfoPath(_ encodedPath: Substring) -> String {
        String(encodedPath)
            .replacingOccurrences(of: "\\040", with: " ")
            .replacingOccurrences(of: "\\011", with: "\t")
            .replacingOccurrences(of: "\\012", with: "\n")
            .replacingOccurrences(of: "\\134", with: "\\")
    }
}
