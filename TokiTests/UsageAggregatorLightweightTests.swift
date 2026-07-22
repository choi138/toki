import XCTest
@testable import Toki

final class UsageAggregatorLightweightTests: XCTestCase {
    func test_usageAggregator_totalTokensMatchesFullUsageTotalsWithMockReaders() async {
        let firstRecorder = MockReaderRecorder()
        let secondRecorder = MockReaderRecorder()
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()
        let request = UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: [:],
            includesEmptySourceRows: false)
        let aggregator = UsageAggregator(readers: [
            MockReader(name: "First", recorder: firstRecorder) { _, _ in
                mockUsage(totalTokens: 40)
            },
            MockReader(name: "Second", recorder: secondRecorder) { _, _ in
                mockUsage(totalTokens: 85)
            },
        ])

        let fullTotalTokens = await aggregator.aggregateUsage(for: request).usageData.totalTokens
        let lightweightTotalTokens = await aggregator.aggregateTotalTokens(for: request)

        XCTAssertEqual(lightweightTotalTokens, fullTotalTokens)
        XCTAssertEqual(lightweightTotalTokens, 125)
    }

    func test_usageAggregator_totalTokensSkipsDisabledReaders() async {
        let enabledRecorder = LightweightUsageRecorder()
        let disabledRecorder = LightweightUsageRecorder()
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()
        let request = UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: [
                "Enabled": true,
                "Disabled": false,
            ],
            includesEmptySourceRows: false)
        let aggregator = UsageAggregator(readers: [
            RecordingTotalReader(name: "Enabled", totalTokens: 40, recorder: enabledRecorder),
            RecordingTotalReader(name: "Disabled", totalTokens: 999, recorder: disabledRecorder),
        ])

        let lightweightTotalTokens = await aggregator.aggregateTotalTokens(for: request)

        let enabledSnapshot = await enabledRecorder.snapshot()
        let disabledSnapshot = await disabledRecorder.snapshot()
        XCTAssertEqual(lightweightTotalTokens, 40)
        XCTAssertEqual(enabledSnapshot.totalStarts, [start])
        XCTAssertTrue(enabledSnapshot.usageStarts.isEmpty)
        XCTAssertTrue(disabledSnapshot.totalStarts.isEmpty)
        XCTAssertTrue(disabledSnapshot.usageStarts.isEmpty)
    }

    func test_usageAggregator_outputTokensMatchesFullUsageOutputTokensWithMockReaders() async {
        let firstRecorder = MockReaderRecorder()
        let secondRecorder = MockReaderRecorder()
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()
        let request = UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: [:],
            includesEmptySourceRows: false)
        let aggregator = UsageAggregator(readers: [
            MockReader(name: "First", recorder: firstRecorder) { _, _ in
                mockOutputUsage(outputTokens: 40)
            },
            MockReader(name: "Second", recorder: secondRecorder) { _, _ in
                mockOutputUsage(outputTokens: 85)
            },
        ])

        let fullOutputTokens = await aggregator.aggregateUsage(for: request).usageData.outputTokens
        let lightweightOutputTokens = await aggregator.aggregateOutputTokens(for: request)

        XCTAssertEqual(lightweightOutputTokens, fullOutputTokens)
        XCTAssertEqual(lightweightOutputTokens, 125)
    }

    func test_usageAggregator_outputTokensSkipsDisabledReaders() async {
        let enabledRecorder = LightweightUsageRecorder()
        let disabledRecorder = LightweightUsageRecorder()
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()
        let request = UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: [
                "Enabled": true,
                "Disabled": false,
            ],
            includesEmptySourceRows: false)
        let aggregator = UsageAggregator(readers: [
            RecordingOutputReader(name: "Enabled", outputTokens: 40, recorder: enabledRecorder),
            RecordingOutputReader(name: "Disabled", outputTokens: 999, recorder: disabledRecorder),
        ])

        let lightweightOutputTokens = await aggregator.aggregateOutputTokens(for: request)

        let enabledSnapshot = await enabledRecorder.snapshot()
        let disabledSnapshot = await disabledRecorder.snapshot()
        XCTAssertEqual(lightweightOutputTokens, 40)
        XCTAssertEqual(enabledSnapshot.outputStarts, [start])
        XCTAssertTrue(enabledSnapshot.usageStarts.isEmpty)
        XCTAssertTrue(enabledSnapshot.totalStarts.isEmpty)
        XCTAssertTrue(disabledSnapshot.outputStarts.isEmpty)
        XCTAssertTrue(disabledSnapshot.usageStarts.isEmpty)
        XCTAssertTrue(disabledSnapshot.totalStarts.isEmpty)
    }
}
