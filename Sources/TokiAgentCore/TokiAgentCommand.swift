import Foundation
import TokiSyncProtocol
import TokiUsageCore
import TokiUsageReaders

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

package enum TokiAgentCommand {
    package static func run() async {
        do {
            try await execute(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            AgentConsole.writeError(AgentSyncService.publicErrorDescription(error))
            exit(EXIT_FAILURE)
        }
    }

    static func execute(arguments: [String]) async throws {
        guard let command = arguments.first else {
            AgentConsole.write(usage)
            return
        }

        switch command {
        case "doctor":
            try doctor()
        case "pair":
            try pair()
        case "unpair":
            try unpair()
        case "sync-once":
            try await AgentSyncService().syncOnce()
            AgentConsole.write("sync completed")
        case "status":
            try await status()
        case "full-rescan":
            try await AgentSyncService().fullRescanAndSync()
            AgentConsole.write("full rescan completed")
        case "migrate-hermes-ledger":
            let result = try migrateHermesLedger(arguments: Array(arguments.dropFirst()))
            AgentConsole.write(migrationDescription(result))
        case "run":
            _ = try await AgentSyncService().run()
        case "help", "--help", "-h":
            AgentConsole.write(usage)
        case "version", "--version":
            AgentConsole.write("toki-agent protocol \(TokiSyncProtocolVersion.current)")
        default:
            throw AgentCommandError.unknownCommand
        }
    }

    private static func pair() throws {
        let standardInput = FileHandle.standardInput
        let descriptor = standardInput.fileDescriptor
        let isTerminal = isatty(descriptor) == 1
        let data = try AgentTerminal.withEchoDisabledIfNeeded(fileDescriptor: descriptor) {
            try readPairingBundle(from: standardInput)
        }
        if isTerminal {
            AgentConsole.write("")
        }
        guard let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AgentCommandError.missingPairingBundle
        }
        let bundle = try TokiSyncCoding.decodeBundle(AgentPairingBundle.self, from: value)
        let configuration = try AgentConfiguration(bundle: bundle)
        let paths = AgentPaths()
        let processLock = try AgentProcessLock.acquire(paths: paths)
        defer { _ = processLock }
        let configurationStore = AgentConfigurationStore(paths: paths)

        do {
            let existing = try configurationStore.load()
            guard existing == configuration else {
                throw AgentCommandError.alreadyPaired
            }
        } catch AgentConfigurationError.notPaired {
            try AgentSpool(paths: paths).clear()
            try AgentStateStore(paths: paths).reset()
            try configurationStore.save(configuration)
        }
        AgentConsole.write("paired device \(configuration.deviceName); credentials stored with user-only permissions")
    }

    static func readPairingBundle(from file: FileHandle) throws -> Data {
        var data = Data()
        let maximumReadCount = TokiSyncLimits.maximumPairingBundleBytes + 1
        while data.count < maximumReadCount {
            let remainingCount = maximumReadCount - data.count
            guard let chunk = try file.read(upToCount: min(4096, remainingCount)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= TokiSyncLimits.maximumPairingBundleBytes else {
            throw AgentCommandError.pairingBundleTooLarge
        }
        return data
    }

    private static func unpair() throws {
        let paths = AgentPaths()
        let processLock = try AgentProcessLock.acquire(paths: paths)
        defer { _ = processLock }
        try AgentConfigurationStore(paths: paths).clear()
        try AgentSpool(paths: paths).clear()
        try AgentStateStore(paths: paths).reset()
        AgentConsole.write("unpaired; local usage data was not changed")
    }

    static func doctor(
        paths: AgentPaths = AgentPaths(),
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try paths.prepare()
        let configuration: AgentConfiguration?
        do {
            configuration = try AgentConfigurationStore(paths: paths).load()
        } catch AgentConfigurationError.notPaired {
            configuration = nil
        }
        let diagnostics = sourceDiagnostics(home: home, environment: environment)

        for diagnostic in diagnostics {
            AgentConsole.write("\(diagnostic.name): \(diagnostic.status.rawValue)")
        }
        AgentConsole.write("Pairing: \(configuration == nil ? "not configured" : "configured")")
        AgentConsole.write("Inbound listener: disabled")

        let errorCount = diagnostics.filter { $0.status == .error }.count
        guard errorCount == 0 else {
            throw AgentCommandError.localUsageSourceErrors(errorCount)
        }
        guard diagnostics.contains(where: { $0.status == .readable }) else {
            throw AgentCommandError.localUsageDataUnavailable
        }
    }

    static func status(
        paths: AgentPaths = AgentPaths(),
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let configuration = try AgentConfigurationStore(paths: paths).load()
        let state = try AgentStateStore(paths: paths).load()
        let pendingCount = try AgentSpool(paths: paths).pendingEnvelopes().count
        let hermesStatus = try await HermesUsageLedger(
            fileURL: paths.stateDirectory.appendingPathComponent("hermes-usage-ledger.json"))
            .status()
        let usagePaths = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: environment)
        let hermesCoverage = try HermesReader(
            dbPathOverride: usagePaths.hermesDatabase.path)
            .coverageStatus()

        for line in statusLines(
            configuration: configuration,
            state: state,
            pendingCount: pendingCount,
            hermesStatus: hermesStatus,
            hermesCoverage: hermesCoverage) {
            AgentConsole.write(line)
        }
    }

    static func statusLines(
        configuration: AgentConfiguration,
        state: AgentRuntimeState,
        pendingCount: Int,
        hermesStatus: HermesUsageLedgerStatus? = nil,
        hermesCoverage: HermesUsageCoverageStatus? = nil) -> [String] {
        var lines = [
            "Device: \(configuration.deviceName)",
            "Hub: configured",
            "Interval: \(configuration.syncIntervalSeconds)s",
            "Pending uploads: \(pendingCount)",
            "Latest sequence: \(state.latestSequence)",
            "Snapshot verification: \(snapshotVerificationStatus(state))",
            "Last success: \(state.lastSuccessfulSyncAt.map(iso8601) ?? "never")",
        ]
        if let hermesStatus {
            lines.append("Hermes accurate since: \(hermesStatus.accurateSince.map(iso8601) ?? "not initialized")")
            lines.append(
                "Hermes unattributed: \(hermesStatus.unattributedSessionCount) sessions, "
                    + "\(hermesStatus.unattributedTokens) tokens")
        }
        if let hermesCoverage {
            lines.append("Hermes unmetered main calls: \(hermesCoverage.unmeteredMainAPICallCount)")
        }
        if state.lastError != nil {
            lines.append("Last error: present")
        }
        return lines
    }

    private static func snapshotVerificationStatus(_ state: AgentRuntimeState) -> String {
        state.lastUploadedContentDigest != nil && state.lastSourceSignature != nil
            ? "stable"
            : "pending"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static let usage = """
    Usage: toki-agent <command>

      doctor       Check local usage sources and Agent configuration
      pair         Read a base64 Agent pairing bundle from standard input
      unpair       Remove Agent credentials and pending encrypted snapshots
      sync-once    Collect, encrypt, and upload one snapshot
      status       Show redacted operational state
      full-rescan  Clear local usage parse caches and synchronize
      migrate-hermes-ledger [--apply]
                   Inspect legacy ledger migration; write only with --apply
      run          Run continuously without opening an inbound port
      version      Show the sync protocol version
    """
}

extension TokiAgentCommand {
    static func migrateHermesLedger(
        arguments: [String],
        paths: AgentPaths = AgentPaths()) throws -> HermesUsageLedgerMigrationResult {
        let mode: HermesUsageLedgerMigrationMode
        switch arguments {
        case []:
            mode = .dryRun
        case ["--apply"]:
            mode = .apply
        default:
            throw AgentCommandError.invalidMigrationArguments
        }
        try paths.prepare()
        let processLock = try AgentProcessLock.acquire(paths: paths)
        defer { _ = processLock }
        return try HermesUsageLedgerMigrator.migrate(
            fileURL: paths.stateDirectory.appendingPathComponent("hermes-usage-ledger.json"),
            mode: mode)
    }

    private static func migrationDescription(_ result: HermesUsageLedgerMigrationResult) -> String {
        switch result {
        case .noLedger:
            "Hermes ledger: not found"
        case .notRequired:
            "Hermes ledger: migration not required"
        case .migrationRequired:
            "Hermes ledger: migration required (dry run; rerun with --apply)"
        case .migrated:
            "Hermes ledger: migration completed"
        }
    }

    static func sourceDiagnostics(
        home: URL,
        environment: [String: String]) -> [AgentSourceDiagnostic] {
        LocalUsageReaderRegistry.agentDescriptors(home: home, environment: environment).map { descriptor in
            AgentSourceDiagnostic(
                name: descriptor.name,
                status: sourceDiagnosticStatus(
                    locations: descriptor.sourceLocations,
                    fileManager: .default))
        }
    }

    private static func sourceDiagnosticStatus(
        locations: [LocalUsageSourceLocation],
        fileManager: FileManager) -> AgentSourceDiagnosticStatus {
        var hasReadableLocation = false
        var hasError = false

        for location in locations {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: location.url.path, isDirectory: &isDirectory) else {
                continue
            }

            let hasExpectedType = switch location {
            case .file:
                !isDirectory.boolValue
            case .directory:
                isDirectory.boolValue
            }
            guard hasExpectedType,
                  fileManager.isReadableFile(atPath: location.url.path) else {
                hasError = true
                continue
            }
            hasReadableLocation = true
        }

        if hasError { return .error }
        return hasReadableLocation ? .readable : .notFound
    }
}

enum AgentCommandError: LocalizedError {
    case unknownCommand
    case missingPairingBundle
    case pairingBundleTooLarge
    case terminalEchoControlFailed
    case alreadyPaired
    case localUsageDataUnavailable
    case localUsageSourceErrors(Int)
    case invalidMigrationArguments

    var errorDescription: String? {
        switch self {
        case .unknownCommand:
            "Unknown command. Run `toki-agent help`."
        case .missingPairingBundle:
            "No pairing bundle was received on standard input."
        case .pairingBundleTooLarge:
            "The pairing bundle exceeds the 64 KiB safety limit."
        case .terminalEchoControlFailed:
            "Could not safely disable terminal echo for pairing input. Pipe the bundle into `toki-agent pair`."
        case .alreadyPaired:
            "This Agent is paired to a different device. Revoke it, run `toki-agent unpair`, then pair again."
        case .localUsageDataUnavailable:
            "No readable supported local usage source was found for this user."
        case let .localUsageSourceErrors(count):
            "\(count) local usage source(s) could not be read safely. Check the Agent service read-only paths."
        case .invalidMigrationArguments:
            "Usage: toki-agent migrate-hermes-ledger [--apply]"
        }
    }
}

struct AgentSourceDiagnostic: Equatable {
    let name: String
    let status: AgentSourceDiagnosticStatus
}

enum AgentSourceDiagnosticStatus: String, Equatable {
    case readable
    case notFound = "not found"
    case error
}

enum AgentTerminal {
    static func withEchoDisabledIfNeeded<Value>(
        fileDescriptor: Int32,
        operation: () throws -> Value) throws -> Value {
        guard isatty(fileDescriptor) == 1 else {
            return try operation()
        }

        var originalAttributes = termios()
        guard tcgetattr(fileDescriptor, &originalAttributes) == 0 else {
            throw AgentCommandError.terminalEchoControlFailed
        }
        var hiddenAttributes = originalAttributes
        hiddenAttributes.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(fileDescriptor, TCSANOW, &hiddenAttributes) == 0 else {
            throw AgentCommandError.terminalEchoControlFailed
        }
        defer {
            var restoredAttributes = originalAttributes
            _ = tcsetattr(fileDescriptor, TCSANOW, &restoredAttributes)
        }
        return try operation()
    }
}

enum AgentConsole {
    static func write(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("toki-agent: \(message)\n".utf8))
    }
}
