//
//  DevicesView.swift
//  ConstructMessenger
//
//  Device management: list linked devices, approve new devices,
//  revoke individual devices, and sign out from this or all devices.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DevicesView: View {

    @Environment(AuthViewModel.self) private var authViewModel

    @State private var devices: [AuthServiceClient.LinkedDevice] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showingQRSheet = false
    @State private var showingScanner = false
    @State private var deviceToRevoke: AuthServiceClient.LinkedDevice? = nil
    @State private var showRevokeConfirm = false
    @State private var showSignOutConfirm = false
    @State private var showSignOutOthersConfirm = false
    @State private var showSignOutAllConfirm = false

    var body: some View {
        List {
            if isLoading && devices.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                }
            } else {
                // MARK: - This Device (always first)
                if let current = devices.first(where: { $0.isCurrent }) {
                    Section {
                        DeviceRow(device: current, isCurrent: true, onRevoke: {})
                    } header: {
                        Text(LocalizedStringKey("this_device"))
                    }
                }

                // MARK: - Other Devices
                let others = devices.filter { !$0.isCurrent }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { device in
                            DeviceRow(device: device, isCurrent: false) {
                                deviceToRevoke = device
                                showRevokeConfirm = true
                            }
                        }
                    } header: {
                        Text(LocalizedStringKey("other_devices"))
                    } footer: {
                        if others.count > 1 {
                            Text(LocalizedStringKey("other_devices_hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - Link / Approve
                Section {
                    Button {
                        showingQRSheet = true
                    } label: {
                        Label(LocalizedStringKey("link_new_device"), systemImage: "plus.circle.fill")
                    }

                    #if os(iOS)
                    Button {
                        showingScanner = true
                    } label: {
                        Label(LocalizedStringKey("device_scan_to_approve"), systemImage: "qrcode.viewfinder")
                    }
                    #endif
                } footer: {
                    Text(LocalizedStringKey("linked_devices_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Session management
                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Label(LocalizedStringKey("sign_out_this_device"), systemImage: "rectangle.portrait.and.arrow.right")
                    }

                    if devices.filter({ !$0.isCurrent }).count > 0 {
                        Button(role: .destructive) {
                            showSignOutOthersConfirm = true
                        } label: {
                            Label(LocalizedStringKey("sign_out_other_devices"), systemImage: "iphone.slash")
                        }
                    }

                    Button(role: .destructive) {
                        showSignOutAllConfirm = true
                    } label: {
                        Label(LocalizedStringKey("sign_out_all_devices"), systemImage: "xmark.shield")
                    }
                } header: {
                    Text(LocalizedStringKey("session_management"))
                } footer: {
                    Text(LocalizedStringKey("sign_out_all_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("linked_devices"))
        .refreshable { await loadDevices() }
        .task { await loadDevices() }

        // MARK: Sheets
        .sheet(isPresented: $showingQRSheet) { DeviceLinkQRSheet() }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) { DeviceLinkScanView() }
        #endif

        // MARK: Confirmations — revoke device
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
            if let name = deviceToRevoke?.name {
                Text(String(format: NSLocalizedString("device_revoke_confirm_message", comment: ""), name))
            }
        }

        // MARK: Confirmations — sign out this device
        .confirmationDialog(
            LocalizedStringKey("sign_out_this_device"),
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("sign_out"), role: .destructive) {
                authViewModel.logout()
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("sign_out_this_device_message"))
        }

        // MARK: Confirmations — sign out other devices
        .confirmationDialog(
            LocalizedStringKey("sign_out_other_devices"),
            isPresented: $showSignOutOthersConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("sign_out_other_devices"), role: .destructive) {
                Task { await revokeAllOtherDevices() }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("sign_out_other_devices_message"))
        }

        // MARK: Confirmations — sign out all devices
        .confirmationDialog(
            LocalizedStringKey("sign_out_all_devices"),
            isPresented: $showSignOutAllConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("sign_out_all_devices"), role: .destructive) {
                authViewModel.logoutAllDevices()
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("sign_out_all_devices_message"))
        }

        // MARK: Error alert
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

    private func revokeAllOtherDevices() async {
        let others = devices.filter { !$0.isCurrent }
        for device in others {
            do {
                try await AuthServiceClient.shared.revokeDevice(deviceId: device.id)
            } catch {
                Log.error("❌ revokeDevice failed for \(device.name): \(error)", category: "DevicesView")
            }
        }
        await loadDevices()
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
    let isCurrent: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: platformIcon)
                .font(.system(size: 22))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)

                if isCurrent {
                    Label(LocalizedStringKey("device_active_now"), systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                        .labelStyle(CompactLabelStyle())
                } else {
                    Text(lastSeenText)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer()

            if !isCurrent {
                Button(role: .destructive, action: onRevoke) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
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
        if abs(device.lastSeen.timeIntervalSince(device.createdAt)) < 5 {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return String(format: NSLocalizedString("device_added_%@", comment: ""), fmt.string(from: device.createdAt))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: device.lastSeen, relativeTo: Date())
    }
}

// MARK: - Compact label style (icon + text, tighter spacing)

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 7))
            configuration.title
        }
    }
}
