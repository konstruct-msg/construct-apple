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
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [AuthServiceClient.LinkedDevice] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showingQRSheet = false
    @State private var showingScanner = false
    @State private var showSendHistorySync = false
    @State private var deviceToRevoke: AuthServiceClient.LinkedDevice? = nil
    @State private var showRevokeConfirm = false
    @State private var showSignOutConfirm = false
    @State private var showSignOutOthersConfirm = false
    @State private var showSignOutAllConfirm = false

    var body: some View {
        let otherDevices = devices.filter { !$0.isCurrent }
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("linked_devices", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }

            ScrollView {
            LazyVStack(spacing: DevicesSettingsLayout.listSpacing) {
                if isLoading && devices.isEmpty {
                    CTSectionGroup {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding()
                    }
                } else {
                    // MARK: - This Device (always first)
                    if let current = devices.first(where: { $0.isCurrent }) {
                        VStack(alignment: .leading, spacing: 0) {
                            CTSettingsSectionHeader(title: NSLocalizedString("this_device", comment: ""))
                            CTSectionGroup {
                                DeviceRow(device: current, isCurrent: true, onRevoke: {})
                                    .deviceRowInsets()
                            }
                        }
                    }

                    // MARK: - Other Devices
                    if !otherDevices.isEmpty {
                        VStack(alignment: .leading, spacing: DevicesSettingsLayout.sectionSpacing) {
                            VStack(alignment: .leading, spacing: 0) {
                                CTSettingsSectionHeader(title: NSLocalizedString("other_devices", comment: ""))
                                CTSectionGroup {
                                    ForEach(Array(otherDevices.enumerated()), id: \.element.id) { index, device in
                                        if index > 0 { ConstructRowDivider(indent: DevicesSettingsLayout.dividerIndent) }
                                        DeviceRow(device: device, isCurrent: false) {
                                            deviceToRevoke = device
                                            showRevokeConfirm = true
                                        }
                                        .deviceRowInsets()
                                    }
                                }
                            }
                            if otherDevices.count > 1 {
                                Text(LocalizedStringKey("other_devices_hint"))
                                    .font(CTFont.regular(11))
                                    .foregroundStyle(Color.CT.textDim)
                                    .settingsSectionHintInsets()
                            }
                        }
                    }

                    // MARK: - Link / Approve
                    VStack(alignment: .leading, spacing: DevicesSettingsLayout.sectionSpacing) {
                        CTSectionGroup {
                            ConstructButtonRow(systemImage: "plus.circle", title: LocalizedStringKey("link_new_device")) {
                                showingQRSheet = true
                            }
                            #if os(iOS)
                            ConstructRowDivider(indent: DevicesSettingsLayout.dividerIndent)
                            ConstructButtonRow(systemImage: "qrcode.viewfinder", title: LocalizedStringKey("device_scan_to_approve")) {
                                showingScanner = true
                            }
                            #endif
                        }
                        Text(LocalizedStringKey("linked_devices_hint"))
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                            .settingsSectionHintInsets()
                    }

                    // MARK: - History Transfer
                    VStack(alignment: .leading, spacing: DevicesSettingsLayout.sectionSpacing) {
                        CTSectionGroup {
                            ConstructButtonRow(systemImage: "arrow.right.arrow.left", title: LocalizedStringKey("transfer_history_row")) {
                                showSendHistorySync = true
                            }
                        }
                        Text(LocalizedStringKey("transfer_history_hint"))
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                            .settingsSectionHintInsets()
                    }

                    // MARK: - Session management
                    VStack(alignment: .leading, spacing: DevicesSettingsLayout.sectionSpacing) {
                        VStack(alignment: .leading, spacing: 0) {
                            CTSettingsSectionHeader(title: NSLocalizedString("session_management", comment: ""))
                            CTSectionGroup {
                                ConstructActionRow(systemImage: "rectangle.portrait.and.arrow.right", title: LocalizedStringKey("sign_out_this_device"), role: .destructive) {
                                    showSignOutConfirm = true
                                }
                                if !otherDevices.isEmpty {
                                    ConstructRowDivider(indent: DevicesSettingsLayout.dividerIndent)
                                    ConstructActionRow(systemImage: "person.2.slash", title: LocalizedStringKey("sign_out_other_devices"), role: .destructive) {
                                        showSignOutOthersConfirm = true
                                    }
                                }
                                ConstructRowDivider(indent: DevicesSettingsLayout.dividerIndent)
                                ConstructActionRow(systemImage: "xmark.circle", title: LocalizedStringKey("sign_out_all_devices"), role: .destructive) {
                                    showSignOutAllConfirm = true
                                }
                            }
                        }
                        Text(LocalizedStringKey("sign_out_all_hint"))
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                            .settingsSectionHintInsets()
                    }
                }
            }
            .padding(.vertical, DevicesSettingsLayout.listVerticalPadding)
        } // ScrollView
        } // VStack
        .background(Color.CT.bg.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .refreshable { await loadDevices() }
        .task { await loadDevices() }

        // MARK: Sheets
        .sheet(isPresented: $showingQRSheet) { DeviceLinkQRSheet() }
        .sheet(isPresented: $showSendHistorySync) {
            SendBackupNearbyView(mode: .historySync)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
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
            Log.error("listDevices failed: \(error)", category: "DevicesView")
        }
    }

    private func revokeAllOtherDevices() async {
        let others = devices.filter { !$0.isCurrent }
        for device in others {
            do {
                try await AuthServiceClient.shared.revokeDevice(deviceId: device.id)
            } catch {
                Log.error("revokeDevice failed for \(device.name): \(error)", category: "DevicesView")
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
            Log.error("revokeDevice failed: \(error)", category: "DevicesView")
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    private static let addedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let relativeLastSeenFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    let device: AuthServiceClient.LinkedDevice
    let isCurrent: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: DevicesSettingsLayout.rowContentSpacing) {
            CTRowIcon(sf: platformSFSymbol,
                      color: isCurrent ? Color.CT.accent : Color.CT.textDim)

            VStack(alignment: .leading, spacing: DevicesSettingsLayout.deviceMetaSpacing) {
                Text(device.name)
                    .font(CTFont.bold(16))

                if isCurrent {
                    HStack(spacing: DevicesSettingsLayout.currentStatusSpacing) {
                        Text("●")
                            .font(.system(size: DevicesSettingsLayout.currentStatusDotSize))
                            .foregroundStyle(Color.CT.accent)
                        Text(LocalizedStringKey("device_active_now"))
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.accent)
                    }
                } else {
                    Text(lastSeenText)
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                }
            }

            Spacer()

            if !isCurrent {
                Button(role: .destructive, action: onRevoke) {
                    Image(systemName: "xmark.circle.fill")
                        .font(CTFont.bold(14))
                        .foregroundStyle(Color.CT.danger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var platformSFSymbol: String {
        switch device.platform {
        case .ios:     return "iphone"
        case .desktop: return "laptopcomputer"
        case .android: return "candybarphone"
        default:       return "desktopcomputer"
        }
    }

    private var lastSeenText: String {
        if abs(device.lastSeen.timeIntervalSince(device.createdAt)) < 5 {
            return String(
                format: NSLocalizedString("device_added_%@", comment: ""),
                Self.addedDateFormatter.string(from: device.createdAt)
            )
        }
        return Self.relativeLastSeenFormatter.localizedString(for: device.lastSeen, relativeTo: Date())
    }
}

private extension View {
    func settingsSectionHintInsets() -> some View {
        padding(.horizontal, DevicesSettingsLayout.hintHorizontalPadding)
    }

    func deviceRowInsets() -> some View {
        padding(.horizontal, DevicesSettingsLayout.rowHorizontalPadding)
            .padding(.vertical, DevicesSettingsLayout.rowVerticalPadding)
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()
    return NavigationStack {
        DevicesView()
            .environment(authViewModel)
    }
    .preferredColorScheme(.dark)
}
#endif
