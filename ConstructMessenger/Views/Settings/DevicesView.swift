//
//  DevicesView.swift
//  ConstructMessenger
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DevicesView: View {

    @State private var devices: [AuthServiceClient.LinkedDevice] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showingQRSheet = false
    @State private var deviceToRevoke: AuthServiceClient.LinkedDevice? = nil
    @State private var showRevokeConfirm = false

    var body: some View {
        List {
            if isLoading && devices.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                }
            } else {
                Section {
                    ForEach(devices) { device in
                        DeviceRow(device: device) {
                            deviceToRevoke = device
                            showRevokeConfirm = true
                        }
                    }
                } header: {
                    Text(LocalizedStringKey("linked_devices"))
                }

                Section {
                    Button {
                        showingQRSheet = true
                    } label: {
                        Label(LocalizedStringKey("link_new_device"), systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text(LocalizedStringKey("linked_devices_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("linked_devices"))
        .refreshable { await loadDevices() }
        .task { await loadDevices() }
        .sheet(isPresented: $showingQRSheet) { DeviceLinkQRSheet() }
        .confirmationDialog(
            LocalizedStringKey("device_revoke_confirm_title"),
            isPresented: $showRevokeConfirm,
            titleVisibility: .visible
        ) {
            if let device = deviceToRevoke {
                Button(LocalizedStringKey("device_revoke"), role: .destructive) {
                    Task { await revokeDevice(device) }
                }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        } message: {
            if let device = deviceToRevoke {
                Text(device.name)
            }
        }
        .alert(LocalizedStringKey("error"), isPresented: .constant(errorMessage != nil)) {
            Button(LocalizedStringKey("ok"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Network

    private func loadDevices() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await AuthServiceClient.shared.listDevices()
        } catch {
            errorMessage = error.localizedDescription
            Log.error("❌ listDevices failed: \(error)", category: "DevicesView")
        }
    }

    private func revokeDevice(_ device: AuthServiceClient.LinkedDevice) async {
        do {
            try await AuthServiceClient.shared.revokeDevice(deviceId: device.id)
            await loadDevices()
        } catch {
            errorMessage = error.localizedDescription
            Log.error("❌ revokeDevice failed: \(error)", category: "DevicesView")
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: AuthServiceClient.LinkedDevice
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: platformIcon)
                .font(.system(size: 22))
                .foregroundStyle(device.isCurrent ? .blue : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.body)
                    if device.isCurrent {
                        Text(LocalizedStringKey("device_current"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                Text(lastSeenText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !device.isCurrent {
                Button(role: .destructive, action: onRevoke) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var platformIcon: String {
        switch device.platform {
        case .ios:     return "iphone"
        case .desktop: return "laptopcomputer"
        case .android: return "smartphone"
        default:       return "desktopcomputer"
        }
    }

    private var lastSeenText: String {
        if device.isCurrent { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: device.lastSeen, relativeTo: Date())
    }
}

