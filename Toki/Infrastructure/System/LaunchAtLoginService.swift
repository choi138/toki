import ServiceManagement

protocol LaunchAtLoginServicing: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ isEnabled: Bool) throws
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
