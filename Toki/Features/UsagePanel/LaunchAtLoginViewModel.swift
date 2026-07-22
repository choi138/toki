import Foundation

@MainActor
final class LaunchAtLoginViewModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        isEnabled = service.isEnabled
    }

    func reload() {
        isEnabled = service.isEnabled
    }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled, !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        let service = service

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result<Void, Error> {
                    try service.setEnabled(isEnabled)
                }
            }.value

            guard let self else { return }
            if case let .failure(error) = result {
                errorMessage = error.localizedDescription
                NSLog("Launch at Login update failed: \(error.localizedDescription)")
            }
            self.isEnabled = service.isEnabled
            isUpdating = false
        }
    }
}
