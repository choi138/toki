import ServiceManagement
import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject var settings: UsagePanelSettings

    private let readerNames: [String]
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginIsUpdating = false

    init(settings: UsagePanelSettings, readerNames: [String] = UsagePanelSettings.defaultReaderNames) {
        self.settings = settings
        self.readerNames = readerNames
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            VStack(spacing: 14) {
                refreshPicker
                settingsSection("Readers") {
                    ForEach(readerNames, id: \.self) { name in
                        settingsToggle(
                            name,
                            isOn: Binding(
                                get: { settings.isReaderEnabled(name) },
                                set: { settings.setReader(name, isEnabled: $0) }))
                    }
                }
                settingsSection("Display") {
                    settingsToggle(
                        "Show zero rows",
                        isOn: Binding(
                            get: { settings.showsZeroSourceRows },
                            set: { settings.setShowsZeroSourceRows($0) }))
                    launchAtLoginToggle
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 280)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
        .onAppear {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var refreshPicker: some View {
        settingsSection("Refresh") {
            Picker("Refresh", selection: $settings.refreshIntervalSeconds) {
                ForEach(UsagePanelSettings.refreshIntervalChoices, id: \.self) { seconds in
                    Text(refreshTitle(for: seconds)).tag(seconds)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var launchAtLoginToggle: some View {
        settingsToggle(
            "Launch at Login",
            isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }))
            .disabled(launchAtLoginIsUpdating)
            .opacity(launchAtLoginIsUpdating ? 0.5 : 1)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private func settingsSection(
        _ title: String,
        @ViewBuilder content: () -> some View)
        -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.28))
            VStack(spacing: 0) {
                content()
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.74))
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func refreshTitle(for seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m"
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        guard launchAtLoginEnabled != isEnabled else { return }
        launchAtLoginIsUpdating = true
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
        launchAtLoginIsUpdating = false
    }
}
