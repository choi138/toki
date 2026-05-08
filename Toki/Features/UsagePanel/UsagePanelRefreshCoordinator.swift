import Foundation

@MainActor
final class UsagePanelRefreshCoordinator {
    private var refreshLoopTask: Task<Void, Never>?
    private var settingsRefreshTask: Task<Void, Never>?

    func startLoop(
        refreshImmediately: Bool,
        intervalSeconds: @escaping @MainActor () -> Int,
        refresh: @escaping @MainActor () async -> Void) {
        refreshLoopTask?.cancel()
        refreshLoopTask = Task { @MainActor in
            if refreshImmediately {
                await refresh()
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds()))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    func scheduleSettingsRefresh(refresh: @escaping @MainActor () async -> Void) {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func cancel() {
        refreshLoopTask?.cancel()
        settingsRefreshTask?.cancel()
        refreshLoopTask = nil
        settingsRefreshTask = nil
    }
}
