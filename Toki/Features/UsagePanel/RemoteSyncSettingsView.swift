import Foundation
import SwiftUI
import TokiSyncProtocol

struct RemoteSyncSettingsSection: View {
    @ObservedObject var viewModel: RemoteSyncSettingsViewModel
    @State private var pendingRevocation: RemoteDeviceSummary?
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isConnected {
                connectedContent
            } else {
                disconnectedContent
            }
            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 9))
                    .foregroundColor(viewModel.hasError ? Color.red.opacity(0.85) : Color.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
        }
        .disabled(viewModel.isBusy)
        .opacity(viewModel.isBusy ? 0.6 : 1)
        .confirmationDialog(
            "Revoke remote device?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }),
            titleVisibility: .visible,
            presenting: pendingRevocation) { device in
                Button("Revoke \(device.name)", role: .destructive) {
                    pendingRevocation = nil
                    Task { await viewModel.revoke(device) }
                }
                Button("Cancel", role: .cancel) {
                    pendingRevocation = nil
                }
        } message: { device in
            Text("This stops future uploads from \(device.name) and removes its key from this Mac.")
        }
        .task {
            await viewModel.refreshDevices()
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: 8) {
            remoteTextField("https://hub.example.com", text: $viewModel.hubURLText)
            SecureField("Hub owner token", text: $viewModel.ownerToken)
                .textFieldStyle(.plain)
                .remoteFieldStyle()
            Button("Connect Hub") {
                Task { await viewModel.connect() }
            }
            .buttonStyle(.borderless)
            .foregroundColor(Color.accentColor)
            if viewModel.needsLocalCredentialRecovery {
                Button("Clear Invalid Local Credentials", role: .destructive) {
                    Task { await viewModel.clearInvalidLocalState() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
        }
        .padding(.vertical, 8)
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text(viewModel.connectedHost ?? "Hub connected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.72))
                Spacer()
                Button("Refresh") {
                    Task { await viewModel.refreshDevices() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                Button("Disconnect") {
                    Task { await viewModel.disconnect() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.06))

            VStack(spacing: 8) {
                SecureField("New Hub owner token", text: $viewModel.ownerToken)
                    .textFieldStyle(.plain)
                    .remoteFieldStyle()
                Button("Update Owner Token") {
                    Task { await viewModel.updateOwnerToken() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
            .padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.06))

            VStack(spacing: 8) {
                remoteTextField("Device name (for example, build-server)", text: $viewModel.deviceName)
                HStack(spacing: 8) {
                    compactRemoteTextField("Retention days", text: $viewModel.retentionDaysText)
                    compactRemoteTextField("Interval minutes", text: $viewModel.syncIntervalMinutesText)
                }
                .padding(.horizontal, 8)
                Button("Copy Agent Pairing Bundle") {
                    Task { await viewModel.createPairingBundle() }
                }
                .buttonStyle(.borderless)
                .foregroundColor(Color.accentColor)
            }
            .padding(.vertical, 8)

            if !viewModel.devices.isEmpty {
                Divider().overlay(Color.white.opacity(0.06))
                ForEach(viewModel.devices, id: \.id) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.7))
                            Text(deviceStatus(device))
                                .font(.system(size: 9))
                                .foregroundColor(Color.white.opacity(0.32))
                        }
                        Spacer()
                        Button("Revoke") {
                            pendingRevocation = device
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                        .foregroundColor(Color.red.opacity(0.8))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func remoteTextField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .remoteFieldStyle()
    }

    private func compactRemoteTextField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .font(.system(size: 10))
            .foregroundColor(Color.white.opacity(0.8))
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func deviceStatus(_ device: RemoteDeviceSummary) -> String {
        guard viewModel.hasEncryptionKey(for: device) else { return "Encryption key unavailable" }
        guard let lastSeenAt = device.lastSeenAt else { return "Waiting for first sync" }
        let relativeDate = Self.relativeDateFormatter.localizedString(for: lastSeenAt, relativeTo: Date())
        return RemoteDeviceFreshness.isStale(device)
            ? "Stale · last sync \(relativeDate)"
            : "Last sync \(relativeDate)"
    }
}

private extension View {
    func remoteFieldStyle() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 6)
            .font(.system(size: 10))
            .foregroundColor(Color.white.opacity(0.8))
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.horizontal, 8)
    }
}
