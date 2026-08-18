import Foundation
import TokiUsageCore
import XCTest
@testable import Toki

/// Covers the half-open `[startDate, endDate)` boundaries of the model detail sheet: the displayed
/// end day and whether hourly bucketing ran for the selected range.
@MainActor
final class PanelModelDetailRangeTests: XCTestCase {
    func test_displayEndDateReportsLastIncludedDayForSingleDayRange() throws {
        let calendar = losAngelesCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))

        let displayEnd = panelModelDetailDisplayEndDate(startDate: start, endDate: end)

        XCTAssertLessThan(displayEnd, end)
        XCTAssertTrue(calendar.isDate(displayEnd, inSameDayAs: start))
    }

    func test_displayEndDateReportsPrecedingDayForMultiDayRange() throws {
        let calendar = losAngelesCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: start))
        let lastIncludedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))

        let displayEnd = panelModelDetailDisplayEndDate(startDate: start, endDate: end)

        XCTAssertTrue(calendar.isDate(displayEnd, inSameDayAs: lastIncludedDay))
    }

    func test_displayEndDateStaysOnLastIncludedDayAcrossDaylightSavingEnd() throws {
        let calendar = losAngelesCalendar()
        // 2026-11-01 is the US fall-back transition, so this calendar day is 25 hours long.
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))

        let displayEnd = panelModelDetailDisplayEndDate(startDate: start, endDate: end)

        XCTAssertTrue(calendar.isDate(displayEnd, inSameDayAs: start))
    }

    func test_displayEndDateClampsToStartForEmptyRange() {
        let displayEnd = panelModelDetailDisplayEndDate(
            startDate: modelDetailStart,
            endDate: modelDetailStart)

        XCTAssertEqual(displayEnd, modelDetailStart)
    }

    func test_hourlyAvailabilityStaysAvailableAtTheBucketLimit() throws {
        let calendar = losAngelesCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let end = try XCTUnwrap(calendar.date(byAdding: .hour, value: 48, to: start))

        XCTAssertTrue(UsageReportBuilder.supportsHourlyBuckets(
            from: start,
            to: end,
            calendar: calendar))
    }

    func test_hourlyAvailabilityReportsUnsupportedRangePastTheBucketLimit() throws {
        let calendar = losAngelesCalendar()
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
        let end = try XCTUnwrap(calendar.date(byAdding: .hour, value: 49, to: start))

        XCTAssertFalse(UsageReportBuilder.supportsHourlyBuckets(
            from: start,
            to: end,
            calendar: calendar))
    }

    func test_hourlyAvailabilityReportsUnsupportedRangeAcrossDaylightSavingEnd() throws {
        let calendar = losAngelesCalendar()
        // The 2026-11-01 fall-back transition makes this two-day range 49 hours long.
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))

        XCTAssertFalse(UsageReportBuilder.supportsHourlyBuckets(
            from: start,
            to: end,
            calendar: calendar))
    }

    func test_presentationMarksLongRangeHourlyDataUnsupported() throws {
        let longRangeEnd = modelDetailStart.addingTimeInterval(86400 * 5)

        let presentation = try XCTUnwrap(panelModelDetailPresentation(
            modelID: "context-model",
            scopeTitle: "This Mac",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: longRangeEnd,
            modelReports: [],
            contextOnlyModels: [
                makeContextRow(id: "c", model: "context-model", source: "Cursor", tokens: 10),
            ]))

        XCTAssertEqual(presentation.hourlyAvailability, .unsupportedRange)
    }

    func test_presentationMarksShortRangeHourlyDataAvailable() throws {
        let usage = makeModelDetailUsage(inputTokens: 10)
        let report = makeModelDetailReport(modelID: "model-a", usage: usage)

        let presentation = try XCTUnwrap(panelModelDetailPresentation(
            modelID: "model-a",
            scopeTitle: "All Devices",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: modelDetailEnd,
            modelReports: [report],
            contextOnlyModels: []))

        XCTAssertEqual(presentation.hourlyAvailability, .available)
    }
}

private func losAngelesCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
    return calendar
}
