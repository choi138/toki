import Foundation

@MainActor
final class MenuBarActivityController {
    private enum Timing {
        static let activityCheck: TimeInterval = 10.0
        static let panelTokenVelocitySample: TimeInterval = 2.0
    }

    private let statusItemController: MenuBarStatusItemController
    private let tokenVelocityMonitor: TokenVelocityMonitor
    private let tokenVelocityState: TokenVelocityState

    private var activityCheckTimer: Timer?
    private var panelTokenVelocitySampleTimer: Timer?
    private var isActivityCheckInFlight = false
    private var isTokenVelocitySampleInFlight = false
    private var isAnyToolActive = false
    private var activeSource: ActiveUsageSource?

    init(
        statusItemController: MenuBarStatusItemController,
        tokenVelocityMonitor: TokenVelocityMonitor = TokenVelocityMonitor(),
        tokenVelocityState: TokenVelocityState) {
        self.statusItemController = statusItemController
        self.tokenVelocityMonitor = tokenVelocityMonitor
        self.tokenVelocityState = tokenVelocityState
    }

    func start() {
        guard activityCheckTimer == nil else { return }
        checkActivityInBackground()
        let timer = Timer(
            timeInterval: Timing.activityCheck,
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkActivityInBackground()
                }
            }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        activityCheckTimer = timer
    }

    func setPanelVisible(_ isVisible: Bool) {
        if isVisible {
            startPanelTokenVelocitySampling()
        } else {
            stopPanelTokenVelocitySampling()
        }
    }

    func stop() {
        activityCheckTimer?.invalidate()
        activityCheckTimer = nil
        stopPanelTokenVelocitySampling()
    }
}

private extension MenuBarActivityController {
    func startPanelTokenVelocitySampling() {
        guard panelTokenVelocitySampleTimer == nil else { return }
        sampleTokenVelocityInBackground()
        let timer = Timer(
            timeInterval: Timing.panelTokenVelocitySample,
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sampleTokenVelocityInBackground()
                }
            }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        panelTokenVelocitySampleTimer = timer
    }

    func stopPanelTokenVelocitySampling() {
        panelTokenVelocitySampleTimer?.invalidate()
        panelTokenVelocitySampleTimer = nil
    }

    func checkActivityInBackground() {
        guard !isActivityCheckInFlight else { return }
        isActivityCheckInFlight = true
        let tokenVelocityMonitor = tokenVelocityMonitor

        DispatchQueue.global(qos: .utility).async {
            let activityState = ActivityMonitor.currentState()

            Task {
                let velocitySample: TokenVelocitySample
                if let source = activityState.activeSource {
                    velocitySample = await tokenVelocityMonitor.sample(source: source)
                } else {
                    await tokenVelocityMonitor.reset()
                    velocitySample = .zero()
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    isActivityCheckInFlight = false
                    isAnyToolActive = activityState.isAnyToolActive
                    activeSource = activityState.activeSource
                    tokenVelocityState.update(velocitySample)
                    statusItemController.applyActivityState(
                        isActive: activityState.isAnyToolActive,
                        tokenVelocity: velocitySample.tokensPerSecond)
                }
            }
        }
    }

    func sampleTokenVelocityInBackground() {
        guard !isTokenVelocitySampleInFlight else { return }
        guard let activeSource else { return }
        isTokenVelocitySampleInFlight = true
        let tokenVelocityMonitor = tokenVelocityMonitor

        Task.detached(priority: .utility) { [weak self] in
            let velocitySample = await tokenVelocityMonitor.sample(source: activeSource)

            await MainActor.run { [weak self] in
                guard let self else { return }
                isTokenVelocitySampleInFlight = false
                tokenVelocityState.update(velocitySample)
                statusItemController.applyActivityState(
                    isActive: isAnyToolActive,
                    tokenVelocity: velocitySample.tokensPerSecond)
            }
        }
    }
}
