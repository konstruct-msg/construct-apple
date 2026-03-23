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
    @State private var showSignOutAllConfirm = false

    var body: some View {
        List {
            if isLoading && devices.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                }
            } else {
                // MARK: - Device list
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
                .foregroundStyle(device.isCurrent ? Color.blue : Color.secondary)
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
                            .foregroundStyle(Color.blue)
                            .clipShape(Capsule())
                    }
                }
                if !device.isCurrent {
                    Text(lastSeenText)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer()

            if device.isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            } else {
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: device.lastSeen, relativeTo: Date())
    }
}
