import Foundation
import TokiUsageCore
import XCTest
@testable import Toki

@MainActor
final class UsageOriginAggregationTests: XCTestCase {
    func test_aggregatorGroupsLocalReadersAndKeepsSameNamedRemoteDevicesDistinct() async {
        let interval = testInterval
        let firstRemoteID = UsageOriginID.remote(deviceID: "remote-a")
        let secondRemoteID = UsageOriginID.remote(deviceID: "remote-b")
        let aggregator = UsageAggregator(readers: [
            FixedUsageReader(
                name: "Codex",
                usage: makeUsage(input: 80, output: 20, cost: 1.25)),
            FixedUsageReader(
                name: "Claude Code",
                usage: makeUsage(input: 45, output: 5, cost: 0.75)),
            FixedOriginReader(
                name: "Remote Devices",
                slices: [
                    makeRemoteSlice(
                        deviceID: "remote-a",
                        name: "worker",
                        usage: makeUsage(input: 20, output: 5, cost: 0.5)),
                    makeRemoteSlice(
                        deviceID: "remote-b",
                        name: "worker",
                        usage: makeUsage(input: 40, output: 10, cost: 1.0)),
                ]),
        ])

        let result = await aggregator.aggregateUsage(for: makeRequest(interval: interval))
        let localReport = result.originReports.first { $0.id == .local }
        let remoteReports = result.originReports.filter { $0.origin.kind == .remote }

        XCTAssertEqual(result.usageData.totalTokens, 225)
        XCTAssertEqual(result.usageData.cost, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(
            result.originReports.reduce(0) { $0 + $1.usageData.totalTokens },
            result.usageData.totalTokens)
        XCTAssertEqual(localReport?.usageData.totalTokens, 150)
        XCTAssertEqual(Set(localReport?.usageData.sourceStats.map(\.source) ?? []), ["Codex", "Claude Code"])
        XCTAssertEqual(remoteReports.map(\.origin.name), ["worker", "worker"])
        XCTAssertEqual(Set(remoteReports.map(\.id)), [firstRemoteID, secondRemoteID])
        XCTAssertEqual(Set(remoteReports.map(\.usageData.totalTokens)), [25, 50])
    }

    func test_remoteModelBucketsPreserveToolSourcesForSharedModel() async throws {
        let interval = testInterval
        var usage = RawTokenUsage(
            inputTokens: 30,
            perModel: [
                "shared-model": PerModelUsage(
                    totalTokens: 30,
                    sources: ["Codex", "Claude Code"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Codex",
            model: "shared-model",
            inputTokens: 10,
            outputTokens: 0)
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(120),
            source: "Claude Code",
            model: "shared-model",
            inputTokens: 20,
            outputTokens: 0)
        let slice = UsageOriginSlice(
            origin: .remote(
                deviceID: "remote-a",
                name: "worker",
                platform: "linux",
                lastUpdatedAt: interval.start),
            usage: usage,
            sourceStats: [
                SourceStat(
                    source: "Codex",
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cost: 0,
                    activeSeconds: 0),
                SourceStat(
                    source: "Claude Code",
                    inputTokens: 20,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cost: 0,
                    activeSeconds: 0),
            ])
        let aggregator = UsageAggregator(readers: [
            FixedOriginReader(name: "Remote Devices", slices: [slice]),
        ])

        let result = await aggregator.aggregateUsage(for: makeRequest(interval: interval))
        let combinedRows = result.usageData.perModel.filter { $0.modelID == "shared-model" }
        let remoteRows = try XCTUnwrap(result.originReports.first).usageData.perModel
            .filter { $0.modelID == "shared-model" }

        XCTAssertEqual(Set(combinedRows.map(\.sources)), [["Codex"], ["Claude Code"]])
        XCTAssertEqual(Set(combinedRows.map(\.totalTokens)), [10, 20])
        XCTAssertEqual(Set(remoteRows.map(\.sources)), [["Codex"], ["Claude Code"]])
        XCTAssertEqual(Set(remoteRows.map(\.totalTokens)), [10, 20])
    }
}

extension UsageOriginAggregationTests {
    func test_localLegacyModelUsageSurvivesAnotherReadersExplicitMapping() async {
        let interval = testInterval
        var explicitUsage = makeUsage(input: 40, output: 0, cost: 0.4)
        explicitUsage.perModel["shared-model"] = PerModelUsage(
            totalTokens: 40,
            cost: 0.4,
            sources: ["Mapped Tool"])
        explicitUsage.perModelBySource[
            ModelSourceUsageKey(modelID: "shared-model", source: "Mapped Tool")
        ] = PerModelUsage(
            totalTokens: 40,
            cost: 0.4,
            sources: ["Mapped Tool"])
        var legacyUsage = makeUsage(input: 60, output: 0, cost: 0.6)
        legacyUsage.perModel["shared-model"] = PerModelUsage(
            totalTokens: 60,
            cost: 0.6,
            sources: ["Legacy Tool"])
        let aggregator = UsageAggregator(readers: [
            FixedUsageReader(name: "Mapped Tool", usage: explicitUsage),
            FixedUsageReader(name: "Legacy Tool", usage: legacyUsage),
        ])

        let result = await aggregator.aggregateUsage(for: makeRequest(interval: interval))
        let rows = result.usageData.perModel.filter { $0.modelID == "shared-model" }

        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, 100)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.cost }, 1, accuracy: 0.000_001)
        XCTAssertEqual(Set(rows.flatMap(\.sources)), ["Mapped Tool", "Legacy Tool"])
    }

    func test_emptyPartitionedReaderRetainsConfiguredZeroSourceRow() async {
        let interval = testInterval
        let aggregator = UsageAggregator(readers: [
            FixedOriginReader(name: "Remote Devices", slices: []),
        ])
        let request = UsageAggregationRequest(
            start: interval.start,
            end: interval.end,
            enabledReaderNames: [:],
            includesEmptySourceRows: true)

        let result = await aggregator.aggregateUsage(for: request)
        let row = result.usageData.sourceStats.first { $0.source == "Remote Devices" }

        XCTAssertNotNil(row)
        XCTAssertEqual(row?.totalTokens, 0)
        XCTAssertEqual(row?.cost, 0)
    }

    func test_readerStatusesStayVisibleForTheirSelectedOriginKind() {
        let statuses = [
            ReaderStatus(
                name: "Codex",
                state: .failed,
                message: "Read failed",
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Remote Devices",
                state: .loaded,
                message: nil,
                lastReadAt: nil,
                totalTokens: 10,
                isOriginPartitioned: true),
        ]

        XCTAssertEqual(
            panelReaderStatuses(statuses, for: .origin(.local)).map(\.name),
            ["Codex"])
        XCTAssertEqual(
            panelReaderStatuses(statuses, for: .origin(.remote(deviceID: "remote-a"))).map(\.name),
            ["Remote Devices"])
        XCTAssertEqual(panelReaderStatuses(statuses, for: .all), statuses)
    }

    func test_duplicateDeviceMenuSubtitlesUseStableAliases() {
        let first = UsageOriginReport(
            origin: .remote(
                deviceID: "remote-a",
                name: "worker",
                platform: "linux",
                lastUpdatedAt: nil),
            usageData: .empty)
        let second = UsageOriginReport(
            origin: .remote(
                deviceID: "remote-b",
                name: "worker",
                platform: "linux",
                lastUpdatedAt: nil),
            usageData: .empty)
        let reports = [second, first]

        XCTAssertEqual(panelDeviceMenuSubtitle(for: first, among: reports), "Linux · Device 1")
        XCTAssertEqual(panelDeviceMenuSubtitle(for: second, among: reports), "Linux · Device 2")
    }

    func test_scopedLightweightTotalsSelectOnlyRequestedOrigin() async {
        let interval = testInterval
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let aggregator = UsageAggregator(readers: [
            FixedUsageReader(
                name: "Codex",
                usage: makeUsage(input: 90, output: 10, cost: 1)),
            FixedOriginReader(
                name: "Remote Devices",
                slices: [
                    makeRemoteSlice(
                        deviceID: "remote-a",
                        name: "worker-a",
                        usage: makeUsage(input: 20, output: 5, cost: 0.5)),
                    makeRemoteSlice(
                        deviceID: "remote-b",
                        name: "worker-b",
                        usage: makeUsage(input: 40, output: 10, cost: 1)),
                ]),
        ])
        let request = makeRequest(interval: interval)

        let allTotal = await aggregator.aggregateTotalTokens(for: request)
        let localTotal = await aggregator.aggregateTotalTokens(for: request, scope: .origin(.local))
        let remoteTotal = await aggregator.aggregateTotalTokens(for: request, scope: .origin(remoteID))
        let allOutput = await aggregator.aggregateOutputTokens(for: request)
        let localOutput = await aggregator.aggregateOutputTokens(for: request, scope: .origin(.local))
        let remoteOutput = await aggregator.aggregateOutputTokens(for: request, scope: .origin(remoteID))

        XCTAssertEqual(allTotal, 175)
        XCTAssertEqual(localTotal, 100)
        XCTAssertEqual(remoteTotal, 25)
        XCTAssertEqual(allOutput, 25)
        XCTAssertEqual(localOutput, 10)
        XCTAssertEqual(remoteOutput, 5)
    }
}

extension UsageOriginAggregationTests {
    func test_viewModelSwitchesScopeWithoutRepeatingSelectedRangeScan() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let selectedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: selectedDay))
        let localRecorder = UsageRangeRecorder()
        let remoteRecorder = UsageRangeRecorder()
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let service = UsageService(readers: [
            FixedUsageReader(
                name: "Codex",
                usage: makeUsage(input: 100, output: 0, cost: 1),
                recorder: localRecorder),
            FixedOriginReader(
                name: "Remote Devices",
                slices: [
                    makeRemoteSlice(
                        deviceID: "remote-a",
                        name: "worker",
                        usage: makeUsage(input: 30, output: 10, cost: 0.5)),
                ],
                recorder: remoteRecorder),
        ])
        service.selectDay(selectedDay)

        await service.refresh()
        XCTAssertEqual(service.usageData.totalTokens, 140)

        service.selectUsageScope(.origin(remoteID))
        await Task.yield()
        let localSelectedRangeReadCount = await localRecorder.count(
            start: selectedDay,
            end: selectedEnd)
        let remoteSelectedRangeReadCount = await remoteRecorder.count(
            start: selectedDay,
            end: selectedEnd)

        XCTAssertEqual(service.usageData.totalTokens, 40)
        XCTAssertEqual(service.usageScopeTitle, "worker")
        XCTAssertEqual(localSelectedRangeReadCount, 1)
        XCTAssertEqual(remoteSelectedRangeReadCount, 1)
    }

    func test_missingSelectedOriginFallsBackToAllDevices() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let state = LockedOriginState(slices: [
            makeRemoteSlice(
                deviceID: "remote-a",
                name: "worker",
                usage: makeUsage(input: 30, output: 10, cost: 0.5)),
        ])
        let service = UsageService(readers: [
            FixedUsageReader(
                name: "Codex",
                usage: makeUsage(input: 100, output: 0, cost: 1)),
            MutableOriginReader(name: "Remote Devices", state: state),
        ])
        service.selectDay(selectedDay)
        await service.refresh()
        service.selectUsageScope(.origin(remoteID))
        XCTAssertEqual(service.selectedUsageScope, .origin(remoteID))

        state.replace(with: [])
        await service.refresh()

        XCTAssertEqual(service.selectedUsageScope, .all)
        XCTAssertEqual(service.usageScopeTitle, "All Devices")
        XCTAssertEqual(service.usageData.totalTokens, 100)
    }

    func test_yesterdayAndPeriodTotalsRespectSelectedRemoteScope() async throws {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let remoteReader = ClosureOriginReader(name: "Remote Devices") { startDate, _ in
            let totalTokens = if startDate == today {
                110
            } else if startDate == yesterday {
                70
            } else {
                30
            }
            return [makeRemoteSlice(
                deviceID: "remote-a",
                name: "worker",
                usage: makeUsage(input: totalTokens, output: 0, cost: 0))]
        }
        let service = UsageService(
            readers: [
                FixedUsageReader(
                    name: "Codex",
                    usage: makeUsage(input: 500, output: 0, cost: 1)),
                remoteReader,
            ],
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))

        await service.refresh()
        service.selectUsageScope(.origin(remoteID))

        let comparisonDeadline = Date().addingTimeInterval(2)
        while service.yesterdayTotalTokens != 70, Date() < comparisonDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let totalsDeadline = Date().addingTimeInterval(2)
        while service.periodTokenTotals.map(\.totalTokens) != [30, 30, 30],
              Date() < totalsDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(service.usageData.totalTokens, 110)
        XCTAssertEqual(service.yesterdayTotalTokens, 70)
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [30, 30, 30])
    }

    func test_periodCacheKeyAndDevicePresentationIncludeScopeWithoutExposingIDs() {
        let endDate = testInterval.end
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let allKey = PeriodTokenTotalsCacheKey(
            endDate: endDate,
            enabledReaderNames: ["Codex": true],
            scope: .all)
        let remoteKey = PeriodTokenTotalsCacheKey(
            endDate: endDate,
            enabledReaderNames: ["Codex": true],
            scope: .origin(remoteID))
        let linuxOrigin = UsageOrigin.remote(
            deviceID: "remote-a",
            name: "worker",
            platform: "linux",
            lastUpdatedAt: nil)

        XCTAssertNotEqual(allKey, remoteKey)
        XCTAssertEqual(panelDevicePlatformLabel(for: linuxOrigin), "Linux")
        XCTAssertEqual(panelDeviceSystemImage(for: linuxOrigin), "server.rack")
        XCTAssertEqual(panelDeviceUpdateLabel(for: linuxOrigin), "Data updated")
        XCTAssertEqual(panelDeviceUpdateLabel(for: .local(lastUpdatedAt: nil)), "Updated")
    }

    private var testInterval: DateInterval {
        DateInterval(
            start: tokiTestISODate("2026-07-01T00:00:00Z"),
            end: tokiTestISODate("2026-07-02T00:00:00Z"))
    }

    private func makeRequest(interval: DateInterval) -> UsageAggregationRequest {
        UsageAggregationRequest(
            start: interval.start,
            end: interval.end,
            enabledReaderNames: [:],
            includesEmptySourceRows: false)
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsageOriginAggregationTests.\(UUID().uuidString)"
        return (suiteName, UserDefaults(suiteName: suiteName)!)
    }
}

private actor UsageRangeRecorder {
    private var ranges: [DateInterval] = []

    func record(start: Date, end: Date) {
        ranges.append(DateInterval(start: start, end: end))
    }

    func count(start: Date, end: Date) -> Int {
        ranges.filter { $0.start == start && $0.end == end }.count
    }
}

private struct FixedUsageReader: TokenReader {
    let name: String
    let usage: RawTokenUsage
    var recorder: UsageRangeRecorder?

    init(name: String, usage: RawTokenUsage, recorder: UsageRangeRecorder? = nil) {
        self.name = name
        self.usage = usage
        self.recorder = recorder
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        if let recorder {
            await recorder.record(start: startDate, end: endDate)
        }
        return usage
    }
}

private struct FixedOriginReader: OriginPartitionedTokenReader {
    let name: String
    let slices: [UsageOriginSlice]
    var recorder: UsageRangeRecorder?

    init(
        name: String,
        slices: [UsageOriginSlice],
        recorder: UsageRangeRecorder? = nil) {
        self.name = name
        self.slices = slices
        self.recorder = recorder
    }

    func readUsageByOrigin(from startDate: Date, to endDate: Date) async throws -> [UsageOriginSlice] {
        if let recorder {
            await recorder.record(start: startDate, end: endDate)
        }
        return slices
    }
}

private struct ClosureOriginReader: OriginPartitionedTokenReader {
    let name: String
    let provider: @Sendable (Date, Date) -> [UsageOriginSlice]

    func readUsageByOrigin(from startDate: Date, to endDate: Date) async throws -> [UsageOriginSlice] {
        provider(startDate, endDate)
    }
}

private final class LockedOriginState: @unchecked Sendable {
    private let lock = NSLock()
    private var slices: [UsageOriginSlice]

    init(slices: [UsageOriginSlice]) {
        self.slices = slices
    }

    func snapshot() -> [UsageOriginSlice] {
        lock.lock()
        defer { lock.unlock() }
        return slices
    }

    func replace(with slices: [UsageOriginSlice]) {
        lock.lock()
        self.slices = slices
        lock.unlock()
    }
}

private struct MutableOriginReader: OriginPartitionedTokenReader {
    let name: String
    let state: LockedOriginState

    func readUsageByOrigin(from _: Date, to _: Date) async throws -> [UsageOriginSlice] {
        state.snapshot()
    }
}

private func makeUsage(input: Int, output: Int, cost: Double) -> RawTokenUsage {
    var usage = RawTokenUsage()
    usage.inputTokens = input
    usage.outputTokens = output
    usage.cost = cost
    return usage
}

private func makeRemoteSlice(
    deviceID: String,
    name: String,
    usage: RawTokenUsage) -> UsageOriginSlice {
    UsageOriginSlice(
        origin: .remote(
            deviceID: deviceID,
            name: name,
            platform: "linux",
            lastUpdatedAt: tokiTestISODate("2026-07-01T12:00:00Z")),
        usage: usage,
        sourceStats: [
            SourceStat(
                source: "Codex",
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: usage.reasoningTokens,
                cost: usage.cost,
                activeSeconds: usage.activeSeconds),
        ])
}
