import AppKit
import Foundation

@MainActor
final class ProcessCPUUsageState: ObservableObject {
    @Published private(set) var percentage: Double?
    @Published private(set) var memoryBytes: UInt64?

    var formattedPercentage: String {
        guard let percentage else { return "—" }
        return percentage.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    var formattedMemoryUsage: String {
        guard let memoryBytes else { return "—" }
        let usesGigabytes = memoryBytes >= 1_000_000_000
        let divisor = usesGigabytes ? 1_000_000_000.0 : 1_000_000.0
        let value = (Double(memoryBytes) / divisor).formatted(.number.precision(.fractionLength(1)))
        return value + (usesGigabytes ? " GB" : " MB")
    }

    func update(_ percentage: Double?) {
        guard self.percentage != percentage else { return }
        self.percentage = percentage
    }

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
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil)
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    deinit {
        samplingTask?.cancel()
        workspaceNotifications.removeObserver(self)
    }

    func setPanelVisible(_ isVisible: Bool) {
        guard !isStopped, isPanelVisible != isVisible else { return }
        isPanelVisible = isVisible
        if isVisible, !isSleeping {
            startSampling()
        } else {
            pauseSampling()
        }
    }

    func stop() {
        isStopped = true
        isPanelVisible = false
        pauseSampling()
        workspaceNotifications.removeObserver(self)
    }

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

    private func pauseSampling() {
        generation += 1
        samplingTask?.cancel()
        samplingTask = nil
        calculator.reset()
        state.update(nil)
        state.updateMemory(nil)
    }

    private func takeSample() {
        state.update(calculator.percentage(for: readSample()))
        state.updateMemory(readMemoryUsage())
    }

    @objc private func systemWillSleep() {
        isSleeping = true
        pauseSampling()
    }

    @objc private func systemDidWake() {
        isSleeping = false
        guard isPanelVisible, !isStopped else { return }
        startSampling()
    }
}
