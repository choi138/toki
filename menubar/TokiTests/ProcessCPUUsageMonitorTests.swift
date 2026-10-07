import AppKit
import XCTest
@testable import Toki

final class ProcessCPUUsageMonitorTests: XCTestCase {
    /// Verifies real selector delivery clears visible readings and establishes a new baseline after wake.
    @MainActor
    func test_sleepClearsVisibleReadingsAndWakeResetsBaseline() {
        let notifications = NotificationCenter()
        let state = ProcessCPUUsageState()
        var sample = ProcessCPUUsageSample(userSeconds: 10, systemSeconds: 2, uptimeSeconds: 100)
        var memoryBytes: UInt64 = 100
        var sampleReads = 0
        let monitor = ProcessCPUUsageMonitor(
            state: state,
            readSample: {
                sampleReads += 1
                return sample
            },
            readMemoryUsage: { memoryBytes },
            waitForNextSample: { try await Task.sleep(for: .seconds(3600)) },
            workspaceNotifications: notifications)
        defer { monitor.stop() }

        monitor.setPanelVisible(true)
        XCTAssertEqual(sampleReads, 1)
        XCTAssertNil(state.percentage)
        XCTAssertEqual(state.memoryBytes, 100)
        state.update(12)

        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertNil(state.percentage)
        XCTAssertNil(state.memoryBytes)
        XCTAssertEqual(sampleReads, 1)

        sample = ProcessCPUUsageSample(userSeconds: 500, systemSeconds: 100, uptimeSeconds: 10000)
        memoryBytes = 200
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(sampleReads, 2)
        XCTAssertNil(state.percentage, "Wake must establish a baseline without counting sleep time")
        XCTAssertEqual(state.memoryBytes, 200)
    }

    /// Verifies workspace notifications never start sampling for hidden or permanently stopped panels.
    @MainActor
    func test_wakeDoesNotSampleHiddenOrStoppedPanel() {
        let notifications = NotificationCenter()
        let state = ProcessCPUUsageState()
        var sampleReads = 0
        let monitor = ProcessCPUUsageMonitor(
            state: state,
            readSample: {
                sampleReads += 1
                return ProcessCPUUsageSample(userSeconds: 10, systemSeconds: 2, uptimeSeconds: 100)
            },
            readMemoryUsage: { 100 },
            waitForNextSample: { try await Task.sleep(for: .seconds(3600)) },
            workspaceNotifications: notifications)
        defer { monitor.stop() }

        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(sampleReads, 0)
        monitor.setPanelVisible(true)
        XCTAssertEqual(sampleReads, 1)
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitor.setPanelVisible(false)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(sampleReads, 1)
        XCTAssertNil(state.percentage)
        XCTAssertNil(state.memoryBytes)

        monitor.stop()
        monitor.setPanelVisible(true)
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(sampleReads, 1)
    }
}
