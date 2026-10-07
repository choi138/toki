import AppKit
import Foundation

@MainActor
final class ProcessCPUUsageState: ObservableObject {
    @Published private(set) var percentage: Double?
    @Published private(set) var memoryBytes: UInt64?

    /// CPU percentage with one decimal place, or a placeholder before a complete interval is sampled.
    var formattedPercentage: String {
        guard let percentage else { return "—" }
        return percentage.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    /// Physical footprint in decimal MB or GB, or a placeholder when unavailable.
    var formattedMemoryUsage: String {
        guard let memoryBytes else { return "—" }
        let usesGigabytes = memoryBytes >= 1_000_000_000
        let divisor = usesGigabytes ? 1_000_000_000.0 : 1_000_000.0
        let value = (Double(memoryBytes) / divisor).formatted(.number.precision(.fractionLength(1)))
        return value + (usesGigabytes ? " GB" : " MB")
    }

    /// Publishes a changed CPU percentage; nil marks the reading as unavailable.
    func update(_ percentage: Double?) {
        guard self.percentage != percentage else { return }
        self.percentage = percentage
    }

    /// Publishes a changed memory footprint; nil marks the reading as unavailable.
    func updateMemory(_ memoryBytes: UInt64?) {
        guard self.memoryBytes != memoryBytes else { return }
        self.memoryBytes = memoryBytes
    }
}

@MainActor
final class ProcessCPUUsageMonitor: NSObject {
    let state: ProcessCPUUsageState

    private let readSample: () -> ProcessCPUUsageSample?
    private let readMemoryUsage: () -> UInt64?
    private let waitForNextSample: @Sendable () async throws -> Void
    private let workspaceNotifications: NotificationCenter
    private var calculator = ProcessCPUUsageCalculator()
    private var samplingTask: Task<Void, Never>?
    private var generation = 0
    private var isPanelVisible = false
    private var isSleeping = false
    private var isStopped = false

    /// Injects measurement sources and registers one-argument workspace sleep and wake observers.
    init(
        state: ProcessCPUUsageState,
        readSample: @escaping () -> ProcessCPUUsageSample? = ProcessCPUUsageReader.sample,
        readMemoryUsage: @escaping () -> UInt64? = ProcessMemoryUsageReader.footprintBytes,
        waitForNextSample: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        },
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.state = state
        self.readSample = readSample
        self.readMemoryUsage = readMemoryUsage
        self.waitForNextSample = waitForNextSample
        self.workspaceNotifications = workspaceNotifications
        super.init()
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil)
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    /// Cancels pending sampling and removes workspace observers when the monitor is released.
    deinit {
        samplingTask?.cancel()
        workspaceNotifications.removeObserver(self)
    }

    /// Starts sampling for a visible, awake panel and clears readings when the panel is hidden.
    func setPanelVisible(_ isVisible: Bool) {
        guard !isStopped, isPanelVisible != isVisible else { return }
        isPanelVisible = isVisible
        if isVisible, !isSleeping {
            startSampling()
        } else {
            pauseSampling()
        }
    }

    /// Permanently stops sampling, clears readings, and unregisters workspace observers.
    func stop() {
        isStopped = true
        isPanelVisible = false
        pauseSampling()
        workspaceNotifications.removeObserver(self)
    }

    /// Establishes a fresh CPU baseline and starts the cancellable periodic sampling task.
    private func startSampling() {
        guard samplingTask == nil else { return }
        calculator.reset()
        state.update(nil)
        takeSample()
        let session = generation
        let waitForNextSample = waitForNextSample
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await waitForNextSample()
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      generation == session,
                      isPanelVisible, !isSleeping, !isStopped else { return }
                takeSample()
            }
        }
    }

    /// Invalidates pending ticks, cancels sampling, and clears the CPU baseline and displayed readings.
    private func pauseSampling() {
        generation += 1
        samplingTask?.cancel()
        samplingTask = nil
        calculator.reset()
        state.update(nil)
        state.updateMemory(nil)
    }

    /// Reads this process's CPU counters and memory footprint into the footer state.
    private func takeSample() {
        state.update(calculator.percentage(for: readSample()))
        state.updateMemory(readMemoryUsage())
    }

    /// Handles a workspace sleep notification by pausing sampling and clearing displayed values.
    @objc private func systemWillSleep(_ notification: Notification) {
        isSleeping = true
        pauseSampling()
    }

    /// Handles a workspace wake notification by restarting only a visible, active monitor.
    @objc private func systemDidWake(_ notification: Notification) {
        isSleeping = false
        guard isPanelVisible, !isStopped else { return }
        startSampling()
    }
}
