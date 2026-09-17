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
    private var activeSources: Set<ActiveUsageSource> = []
    private var claudeCodeProbeThrottle = ClaudeCodeProbeThrottle()

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
        let now = Date()
        let probesClaudeCode = claudeCodeProbeThrottle.shouldProbeAlongsideOtherSources(now: now)

        DispatchQueue.global(qos: .utility).async {
            let activityState = ActivityMonitor.currentState(
                now: now,
                probesClaudeCodeAlongsideOtherSources: probesClaudeCode)

            Task {
                await MainActor.run { [weak self] in
                    self?.publishActivityState(activityState, at: now)
                }

                let velocitySample: TokenVelocitySample
                if activityState.isAnyToolActive {
                    velocitySample = await tokenVelocityMonitor.sample(sources: activityState.activeSources)
                } else {
                    await tokenVelocityMonitor.reset()
                    velocitySample = .zero()
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    isActivityCheckInFlight = false
                    tokenVelocityState.update(velocitySample)
                    statusItemController.applyActivityState(
                        isActive: activityState.isAnyToolActive,
                        tokenVelocity: velocitySample.tokensPerSecond)
                }
            }
        }
    }

    /// Published before the velocity read so a slow reader cannot keep the status
    /// item and panel sampling on the previous tool.
    func publishActivityState(_ activityState: ActivityMonitorState, at now: Date) {
        claudeCodeProbeThrottle.record(activityState, at: now)
        isAnyToolActive = activityState.isAnyToolActive
        activeSources = activityState.activeSources
        statusItemController.applyActivityState(
            isActive: activityState.isAnyToolActive,
            tokenVelocity: tokenVelocityState.liveTokensPerSecond)
    }

    func sampleTokenVelocityInBackground() {
        guard !isTokenVelocitySampleInFlight else { return }
        guard !activeSources.isEmpty else { return }
        isTokenVelocitySampleInFlight = true
        let tokenVelocityMonitor = tokenVelocityMonitor
        let activeSources = activeSources

        Task.detached(priority: .utility) { [weak self] in
            let velocitySample = await tokenVelocityMonitor.sample(sources: activeSources)

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
