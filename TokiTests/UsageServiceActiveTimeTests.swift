import TokiUsageCore
import XCTest
@testable import Toki

final class UsageServiceActiveTimeTests: XCTestCase {
    @MainActor
    func test_usageService_mergesOverlappingActiveTimeAcrossReaders() async {
        let firstRecorder = MockReaderRecorder()
        let secondRecorder = MockReaderRecorder()
        let firstReader = MockReader(name: "First", recorder: firstRecorder) { _, _ in
            mockActivityUsage(
                totalTokens: 100,
                modelID: "gpt-5.4",
                source: "First",
                events: [
                    ActivityTimeEvent(
                        streamID: "codex",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:00:00Z"),
                        key: "gpt-5.4"),
                    ActivityTimeEvent(
                        streamID: "codex",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:02:00Z"),
                        key: "gpt-5.4"),
                ])
        }
        let secondReader = MockReader(name: "Second", recorder: secondRecorder) { _, _ in
            mockActivityUsage(
                totalTokens: 80,
                modelID: "gpt-5.4",
                source: "Second",
                events: [
                    ActivityTimeEvent(
                        streamID: "claude",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:01:00Z"),
                        key: "gpt-5.4"),
                    ActivityTimeEvent(
                        streamID: "claude",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:03:00Z"),
                        key: "gpt-5.4"),
                ])
        }

        let service = UsageService(readers: [firstReader, secondReader])
        await service.refresh()

        let totalActiveSeconds = service.usageData.activeSeconds
        let models = service.usageData.perModel
        let modelsBySource = Dictionary(
            uniqueKeysWithValues: models.compactMap { model in
                model.sources.first.map { ($0, model) }
            })

        XCTAssertEqual(totalActiveSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(service.usageData.workTime.agentSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(service.usageData.workTime.wallClockSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(service.usageData.workTime.activeStreamCount, 2)
        XCTAssertEqual(service.usageData.workTime.maxConcurrentStreams, 2)
        XCTAssertEqual(Set(models.map(\.id)), ["gpt-5.4|First", "gpt-5.4|Second"])
        XCTAssertEqual(modelsBySource["First"]?.activeSeconds ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(modelsBySource["Second"]?.activeSeconds ?? 0, 150, accuracy: 0.001)
    }

    @MainActor
    func test_usageService_preservesFallbackActiveTimeFromReadersWithoutEvents() async {
        let eventReader = MockReader(name: "Event", recorder: MockReaderRecorder()) { _, _ in
            mockActivityUsage(
                totalTokens: 100,
                modelID: "gpt-5.4",
                source: "Event",
                events: [
                    ActivityTimeEvent(
                        streamID: "event",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:00:00Z"),
                        key: "gpt-5.4"),
                    ActivityTimeEvent(
                        streamID: "event",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:02:00Z"),
                        key: "gpt-5.4"),
                ])
        }
        let aggregateReader = MockReader(name: "Aggregate", recorder: MockReaderRecorder()) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 40
            usage.activeSeconds = 60
            usage.perModel["claude-sonnet-4-6"] = PerModelUsage(
                totalTokens: 40,
                cost: 0.4,
                activeSeconds: 60,
                sources: ["Aggregate"])
            return usage
        }
        let secondAggregateReader = MockReader(name: "SecondAggregate", recorder: MockReaderRecorder()) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 20
            usage.activeSeconds = 30
            usage.perModel["gemini-2.5-pro"] = PerModelUsage(
                totalTokens: 20,
                cost: 0.2,
                activeSeconds: 30,
                sources: ["SecondAggregate"])
            return usage
        }

        let service = UsageService(readers: [eventReader, aggregateReader, secondAggregateReader])
        await service.refresh()

        XCTAssertEqual(service.usageData.activeSeconds, 240, accuracy: 0.001)
        XCTAssertEqual(service.usageData.workTime.agentSeconds, 240, accuracy: 0.001)
        XCTAssertEqual(service.usageData.workTime.wallClockSeconds, 240, accuracy: 0.001)
        XCTAssertEqual(service.usageData.workTime.activeStreamCount, 3)
        XCTAssertEqual(service.usageData.workTime.maxConcurrentStreams, 1)
        XCTAssertEqual(
            service.usageData.perModel.first(where: { $0.id == "gpt-5.4" })?.activeSeconds ?? 0,
            150,
            accuracy: 0.001)
        XCTAssertEqual(
            service.usageData.perModel.first(where: { $0.id == "claude-sonnet-4-6" })?.activeSeconds ?? 0,
            60,
            accuracy: 0.001)
        XCTAssertEqual(
            service.usageData.perModel.first(where: { $0.id == "gemini-2.5-pro" })?.activeSeconds ?? 0,
            30,
            accuracy: 0.001)
    }

    func test_rawTokenUsageAdditionMergesWorkTimeFallbacks() {
        var lhs = RawTokenUsage()
        lhs.activeSeconds = 120

        var rhs = RawTokenUsage()
        rhs.activeSeconds = 90
        rhs.workTime = WorkTimeMetrics(
            agentSeconds: 90,
            wallClockSeconds: 60,
            activeStreamCount: 2,
            maxConcurrentStreams: 2)

        lhs += rhs

        XCTAssertEqual(lhs.activeSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(lhs.workTime.agentSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(lhs.workTime.wallClockSeconds, 180, accuracy: 0.001)
        XCTAssertEqual(lhs.workTime.activeStreamCount, 3)
        XCTAssertEqual(lhs.workTime.maxConcurrentStreams, 2)

        lhs.recomputeMergedActiveEstimate()

        XCTAssertEqual(lhs.workTime.agentSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(lhs.workTime.wallClockSeconds, 180, accuracy: 0.001)
        XCTAssertEqual(lhs.workTime.activeStreamCount, 3)
        XCTAssertEqual(lhs.workTime.maxConcurrentStreams, 2)
    }

    @MainActor
    func test_usageReportDoesNotCreateResidualRowsForSharedReaderStreamIDs() async {
        let firstReader = MockReader(name: "First", recorder: MockReaderRecorder()) { _, _ in
            mockActivityUsage(
                totalTokens: 10,
                modelID: "gpt-5.4",
                source: "First",
                events: [
                    ActivityTimeEvent(
                        streamID: "shared",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:00:00Z"),
                        key: "gpt-5.4"),
                ])
        }
        let secondReader = MockReader(name: "Second", recorder: MockReaderRecorder()) { _, _ in
            mockActivityUsage(
                totalTokens: 20,
                modelID: "gpt-5.4",
                source: "Second",
                events: [
                    ActivityTimeEvent(
                        streamID: "shared",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:04:00Z"),
                        key: "gpt-5.4"),
                ])
        }
        let service = UsageService(readers: [firstReader, secondReader])

        await service.refresh()

        XCTAssertEqual(Set(service.usageData.perModel.map(\.id)), ["gpt-5.4|First", "gpt-5.4|Second"])
        XCTAssertEqual(service.usageData.perModel.map(\.activeSeconds).reduce(0, +), 60, accuracy: 0.001)
    }
}

@MainActor
final class UsageModelActiveTimeReportTests: XCTestCase {
    func test_usageReportEventFallbackPreservesModelTransitions() {
        let startDate = usageServiceActiveTimeISODate("2026-04-10T00:00:00Z")
        let endDate = usageServiceActiveTimeISODate("2026-04-10T00:05:00Z")
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: usageServiceActiveTimeISODate("2026-04-10T00:00:00Z"),
            source: "Cursor",
            model: "model-a",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(sessionID: "shared-session"))
        usage.recordTokenEvent(
            timestamp: usageServiceActiveTimeISODate("2026-04-10T00:02:00Z"),
            source: "Cursor",
            model: "model-b",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(sessionID: "shared-session"))
        usage.recordTokenEvent(
            timestamp: usageServiceActiveTimeISODate("2026-04-10T00:04:00Z"),
            source: "Cursor",
            model: "model-a",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(sessionID: "shared-session"))

        let report = UsageReportBuilder.report(
            from: usage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])
        let rowsByModel = Dictionary(
            uniqueKeysWithValues: report.perModel.map { ($0.modelID, $0) })

        XCTAssertEqual(report.perModel.count, 2)
        XCTAssertEqual(rowsByModel["model-a"]?.activeSeconds ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(rowsByModel["model-b"]?.activeSeconds ?? 0, 120, accuracy: 0.001)
    }

    func test_usageReportEventFallbackClipsActivityAtRangeEnd() {
        let startDate = usageServiceActiveTimeISODate("2026-04-10T23:00:00Z")
        let endDate = usageServiceActiveTimeISODate("2026-04-11T00:00:00Z")
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: usageServiceActiveTimeISODate("2026-04-10T23:59:50Z"),
            source: "Cursor",
            model: "model-a",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(sessionID: "request-at-end"))

        let report = UsageReportBuilder.report(
            from: usage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertEqual(report.perModel.count, 1)
        XCTAssertEqual(report.perModel.first?.modelID, "model-a")
        XCTAssertEqual(report.perModel.first?.sources, ["Cursor"])
        XCTAssertEqual(report.perModel.first?.activeSeconds ?? 0, 10, accuracy: 0.001)
    }

    func test_usageReportPreservesReaderModelTransitions() async {
        let startDate = usageServiceActiveTimeISODate("2026-04-10T00:00:00Z")
        let endDate = usageServiceActiveTimeISODate("2026-04-10T00:05:00Z")
        let reader = MockReader(name: "Cursor", recorder: MockReaderRecorder()) { _, _ in
            let firstModelDate = usageServiceActiveTimeISODate("2026-04-10T00:00:00Z")
            let secondModelDate = usageServiceActiveTimeISODate("2026-04-10T00:02:00Z")
            let finalModelDate = usageServiceActiveTimeISODate("2026-04-10T00:04:00Z")
            var usage = RawTokenUsage()
            usage.inputTokens = 30
            usage.perModel["model-a"] = PerModelUsage(
                totalTokens: 20,
                sources: ["Cursor"])
            usage.perModel["model-b"] = PerModelUsage(
                totalTokens: 10,
                sources: ["Cursor"])
            usage.recordTokenEvent(
                timestamp: firstModelDate,
                source: "Cursor",
                model: "model-a",
                inputTokens: 10,
                outputTokens: 0,
                attribution: UsageAttribution(sessionID: "request-a"))
            usage.recordTokenEvent(
                timestamp: secondModelDate,
                source: "Cursor",
                model: "model-b",
                inputTokens: 10,
                outputTokens: 0,
                attribution: UsageAttribution(sessionID: "request-b"))
            usage.recordTokenEvent(
                timestamp: finalModelDate,
                source: "Cursor",
                model: "model-a",
                inputTokens: 10,
                outputTokens: 0,
                attribution: UsageAttribution(sessionID: "request-c"))
            usage.mergeActivityEvents(
                [
                    ActivityTimeEvent(
                        streamID: "Cursor",
                        timestamp: firstModelDate,
                        key: "model-a"),
                    ActivityTimeEvent(
                        streamID: "Cursor",
                        timestamp: secondModelDate,
                        key: "model-b"),
                    ActivityTimeEvent(
                        streamID: "Cursor",
                        timestamp: finalModelDate,
                        key: "model-a"),
                ],
                source: "Cursor",
                clippingEndDate: endDate)
            return usage
        }
        let aggregator = UsageAggregator(readers: [reader])

        let result = await aggregator.aggregateUsage(
            for: UsageAggregationRequest(
                start: startDate,
                end: endDate,
                enabledReaderNames: [:],
                includesEmptySourceRows: false))
        let rowsByModel = Dictionary(
            uniqueKeysWithValues: result.usageData.perModel.map { ($0.modelID, $0) })

        XCTAssertEqual(rowsByModel["model-a"]?.activeSeconds ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(rowsByModel["model-b"]?.activeSeconds ?? 0, 120, accuracy: 0.001)
    }

    func test_usageReportClipsModelActivityAtRangeEnd() async {
        let startDate = usageServiceActiveTimeISODate("2026-04-10T23:00:00Z")
        let endDate = usageServiceActiveTimeISODate("2026-04-11T00:00:00Z")
        let eventDate = usageServiceActiveTimeISODate("2026-04-10T23:59:50Z")
        let reader = MockReader(name: "Cursor", recorder: MockReaderRecorder()) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 10
            usage.perModel["model-a"] = PerModelUsage(
                totalTokens: 10,
                sources: ["Cursor"])
            usage.recordTokenEvent(
                timestamp: eventDate,
                source: "Cursor",
                model: "model-a",
                inputTokens: 10,
                outputTokens: 0,
                attribution: UsageAttribution(sessionID: "request-at-end"))
            usage.mergeActivityEvents(
                [ActivityTimeEvent(streamID: "Cursor", timestamp: eventDate, key: "model-a")],
                source: "Cursor",
                clippingEndDate: endDate)
            return usage
        }
        let aggregator = UsageAggregator(readers: [reader])

        let result = await aggregator.aggregateUsage(
            for: UsageAggregationRequest(
                start: startDate,
                end: endDate,
                enabledReaderNames: [:],
                includesEmptySourceRows: false))

        XCTAssertEqual(result.usageData.perModel.first?.activeSeconds ?? 0, 10, accuracy: 0.001)
    }

    func test_usageReportKeepsReaderActivityWhenTokenSessionsWouldOverestimate() async {
        let startDate = usageServiceActiveTimeISODate("2026-04-10T00:00:00Z")
        let endDate = usageServiceActiveTimeISODate("2026-04-10T00:05:00Z")
        let firstDate = usageServiceActiveTimeISODate("2026-04-10T00:00:00Z")
        let secondDate = usageServiceActiveTimeISODate("2026-04-10T00:04:00Z")
        let reader = MockReader(name: "Claude Code", recorder: MockReaderRecorder()) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 20
            usage.perModel["claude-sonnet"] = PerModelUsage(
                totalTokens: 20,
                sources: ["Claude Code"])
            usage.recordTokenEvent(
                timestamp: firstDate,
                source: "Claude Code",
                model: "claude-sonnet",
                inputTokens: 10,
                outputTokens: 0,
                attribution: UsageAttribution(sessionID: "session-a"))
            usage.recordTokenEvent(
                timestamp: secondDate,
                source: "Claude Code",
                model: "claude-sonnet",
                inputTokens: 10,
                outputTokens: 0,
                attribution: UsageAttribution(sessionID: "session-a"))
            usage.mergeActivityEvents(
                [
                    ActivityTimeEvent(streamID: "request-a", timestamp: firstDate, key: "claude-sonnet"),
                    ActivityTimeEvent(streamID: "request-b", timestamp: secondDate, key: "claude-sonnet"),
                ],
                source: "Claude Code",
                clippingEndDate: endDate)
            return usage
        }
        let aggregator = UsageAggregator(readers: [reader])

        let result = await aggregator.aggregateUsage(
            for: UsageAggregationRequest(
                start: startDate,
                end: endDate,
                enabledReaderNames: [:],
                includesEmptySourceRows: false))

        XCTAssertEqual(result.usageData.perModel.first?.activeSeconds ?? 0, 60, accuracy: 0.001)
    }
}

private func usageServiceActiveTimeISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
