//
//  SettingsView.swift
//  Construct Messenger
//

import SwiftUI
import CoreData

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    @Environment(SocialRecoveryService.self) private var socialRecoveryService
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel = SettingsViewModel()
    private var connectionStatus = ConnectionStatusManager.shared
    @State private var showingQRCode = false
    @State private var showingRecoverySetup = false
    @State private var showingOrientation = false
    @State private var recoveryBannerDismissed = UserDefaults.standard.bool(forKey: "recovery_banner_dismissed")
    @State private var navigationPath = NavigationPath()
    // Silent-transport (decisions/silent-transport-ui): the only external escape hatch for a
    // relay capability when the automatic delivery channel is fully blocked. Hidden behind N taps
    // on the version row — invisible in casual use, discoverable when a trusted party instructs.
    @State private var versionTapCount = 0
    @State private var showEmergencyImport = false
    @State private var emergencyPasteText = ""
    @State private var emergencyImportMsg: String?

    /// Content cap on regular width (iPad two-column); unbounded on compact iPhone.
    private var settingsContentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 980 : .infinity
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: SettingsRootLayout.rootSpacing) {
                
                // Section title as plain left-aligned label (not a capsule)
                HStack {
                    Text(NSLocalizedString("settings", comment: "").uppercased())
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.text)
                        .tracking(4)
                    Spacer()
                }
                .padding(.horizontal, CTLayout.edgePad)
                .frame(height: CTLayout.navBarHeight)

                ScrollView {
                    LazyVStack(spacing: SettingsRootLayout.listSpacing) {
                        // MARK: Recovery warning (full width in both layouts)
                        if recoveryVM.statusLoaded && !recoveryVM.isSetup && !recoveryBannerDismissed {
                            recoveryBanner
                        }

                        if horizontalSizeClass == .regular {
                            // iPad landscape: identity as a full-width header, the rest in
                            // two balanced columns so rows don't stretch across the stage.
                            profileHeaderLarge
                            HStack(alignment: .top, spacing: SettingsRootLayout.listSpacing) {
                                VStack(spacing: SettingsRootLayout.listSpacing) {
                                    mainSettingsSection
                                }
                                .frame(maxWidth: .infinity, alignment: .top)

                                VStack(spacing: SettingsRootLayout.listSpacing) {
                                    shareSection
                                    aboutSection
                                    // Diagnostics disclose reachability (active relay, cert) — internal only.
                                    #if DEBUG || INTERNAL_TOOLS
                                    developerSection
                                    #endif
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        } else {
                            profileSection
                            shareSection
                            mainSettingsSection
                            aboutSection
                            #if DEBUG || INTERNAL_TOOLS
                            developerSection
                            #endif
                        }

                        // Spacer for floating tab capsule
                        Color.clear
                            .frame(height: 72)
                    }
                    .padding(.bottom, SettingsRootLayout.listBottomPadding)
                }
            }
            // Regular width (iPad shell): keep rows to a readable column, centered —
            // full-width rows on a wide landscape stage read as meaninglessly long.
            .frame(maxWidth: settingsContentMaxWidth)
            .frame(maxWidth: .infinity)
            .ctBackground()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                viewModel.setContext(viewContext)
                if viewModel.needsUserInfoRefresh(from: authViewModel) {
                    viewModel.loadUserInfo(from: authViewModel)
                }
            }
            .task { await recoveryVM.loadStatus() }
            .sheet(isPresented: $showingRecoverySetup) {
                RecoverySetupView()
                    .environment(recoveryVM)
                    .environment(authViewModel)
                    .onDisappear { Task { await recoveryVM.refreshStatus() } }
            }
            .sheet(isPresented: $showingQRCode) {
                ContactQRCodeView(userId: viewModel.userId, username: viewModel.username)
            }
            .sheet(isPresented: $showingOrientation) {
                OrientationView(openSynapsOnFinish: false) {
                    showingOrientation = false
                }
            }
        }
    }

    // MARK: - Profile Row

    private var profileRow: some View {
        HStack(spacing: SettingsRootLayout.profileRowSpacing) {
            let img: Image? = {
                guard let ui = viewModel.profileImage else { return nil }
                return Image(uiImage: ui)
            }()
            CTHexAvatar(initials: profileInitials, image: img, size: .large, colorSeed: viewModel.userId)

            VStack(alignment: .leading, spacing: SettingsRootLayout.profileMetaSpacing) {
                Text(profileDisplayName.uppercased())
                    .font(CTFont.bold(15))
                    .foregroundColor(Color.CT.text)
                Text(viewModel.username.isEmpty ? NSLocalizedString("username_not_set", comment: "") : "@\(viewModel.username)")
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                HStack(spacing: 5) {
                    CTStatusBadge(status: viewModel.isDiscoverable ? .on : .off, size: 11)
                    Text(viewModel.isDiscoverable
                        ? NSLocalizedString("searchable_indicator", comment: "")
                        : NSLocalizedString("searchable_indicator_off", comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundColor(viewModel.isDiscoverable ? Color.CT.accent : Color.CT.textDim)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.accent)
        }
        .padding(.horizontal, SettingsRootLayout.profileRowHorizontalPadding)
        .padding(.vertical, SettingsRootLayout.profileRowVerticalPadding)
    }

    // MARK: - Sections (shared by compact single-column & regular two-column)

    /// NavigationLink into AccountSettingsView (identity), wrapping an arbitrary label.
    private func profileLink<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        NavigationLink {
            AccountSettingsView()
                .environment(authViewModel)
                .environment(recoveryVM)
                .environment(socialRecoveryService)
                .environment(viewModel)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    /// Compact identity row inside a section card.
    private var profileSection: some View {
        CTSectionGroup {
            profileLink { profileRow }
        }
    }

    /// iPad landscape: identity as a large full-width header banner.
    private var profileHeaderLarge: some View {
        CTSectionGroup {
            profileLink {
                HStack(spacing: SettingsRootLayout.profileRowSpacing) {
                    let img: Image? = {
                        guard let ui = viewModel.profileImage else { return nil }
                        return Image(uiImage: ui)
                    }()
                    CTHexAvatar(initials: profileInitials, image: img, size: .large, colorSeed: viewModel.userId)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(profileDisplayName.uppercased())
                            .font(CTFont.bold(22))
                            .foregroundColor(Color.CT.text)
                        Text(viewModel.username.isEmpty ? NSLocalizedString("username_not_set", comment: "") : "@\(viewModel.username)")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.textDim)
                        HStack(spacing: 5) {
                            CTStatusBadge(status: viewModel.isDiscoverable ? .on : .off, size: 11)
                            Text(viewModel.isDiscoverable
                                ? NSLocalizedString("searchable_indicator", comment: "")
                                : NSLocalizedString("searchable_indicator_off", comment: ""))
                                .font(CTFont.regular(11))
                                .foregroundColor(viewModel.isDiscoverable ? Color.CT.accent : Color.CT.textDim)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(CTFont.bold(15))
                        .foregroundColor(Color.CT.accent)
                }
                .padding(.horizontal, SettingsRootLayout.profileRowHorizontalPadding)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// One row, opening one sheet.
    ///
    /// This was a [QR][COPY LINK] pair plus a caption linking to a third screen for
    /// inviting several people. All three did the same thing — mint a v4 one-time invite —
    /// and the split forced the user to decide which shape they wanted before seeing
    /// either. `ContactQRCodeView` now shows both and states the rule that made the third
    /// screen unnecessary.
    private var shareSection: some View {
        CTSectionGroup {
            Button { showingQRCode = true } label: {
                CTSettingsRow(
                    label: NSLocalizedString("invite", comment: "").uppercased(),
                    icon: "person.badge.plus",
                    disclosure: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Settings.invite)
        }
    }

    private var mainSettingsSection: some View {
        CTSectionGroup {
            NavigationLink(destination: DevicesView()) {
                CTSettingsRow(label: NSLocalizedString("linked_devices", comment: "").uppercased(), icon: "laptopcomputer", disclosure: true)
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            NavigationLink(destination: AppearanceSettingsView()) {
                CTSettingsRow(label: NSLocalizedString("appearance", comment: "").uppercased(), icon: "paintbrush", disclosure: true)
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            NavigationLink(destination: SecurityView()
                .environment(viewModel)) {
                CTSettingsRow(label: NSLocalizedString("security", comment: "").uppercased(), icon: "lock", disclosure: true)
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            NavigationLink(destination: DataStorageSettingsView()) {
                CTSettingsRow(label: NSLocalizedString("data_and_storage", comment: "").uppercased(), icon: "externaldrive", disclosure: true)
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            NavigationLink(destination: TranscriptionSettingsView()) {
                CTSettingsRow(label: NSLocalizedString("transcription", comment: "").uppercased(), icon: "mic", disclosure: true)
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            NavigationLink(destination: NotificationsSettingsView()) {
                CTSettingsRow(label: NSLocalizedString("notifications", comment: "").uppercased(), icon: "bell", disclosure: true)
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            // Network + Background Refresh merged (silent-transport-ui left Network nearly empty
            // on production — one Connectivity-style entry with live status + BG controls).
            NavigationLink(destination: NetworkSettingsView()) {
                CTSettingsRow(
                    label: NSLocalizedString("network", comment: "").uppercased(),
                    status: connectionStatus.isConnected ? .ok : .error,
                    icon: "globe",
                    disclosure: true
                )
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            NavigationLink(destination: DraftsView()) {
                CTSettingsRow(label: NSLocalizedString("drafts", comment: "").uppercased(), icon: "folder", disclosure: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// Emergency relay-capability import (hidden version-tap escape hatch). The blob is still
    /// Ed25519 manifest-verified inside `VeilConfigImporter`, so this is not a blind-trust input.
    private func handleEmergencyImport() {
        switch VeilConfigImporter.importScannedOrPasted(emergencyPasteText) {
        case .success:
            emergencyImportMsg = NSLocalizedString("veil_config_import_ok", comment: "")
            Task {
                let vm = VeilProxyManager.shared
                if vm.mode != .off { vm.stop(); await vm.startIfEnabled() }
            }
        case .failure(let e):
            emergencyImportMsg = e.localizedDescription
        }
    }

    private var aboutSection: some View {
        CTSectionGroup {
            Button { showingOrientation = true } label: {
                CTSettingsRow(
                    label: NSLocalizedString("orientation_settings_replay", comment: "").uppercased(),
                    icon: "text.book.closed",
                    isAction: true,
                    disclosure: true
                )
            }
            .buttonStyle(.plain)
            CTSep(style: .thin)
            CTSettingsRow(
                label: NSLocalizedString("version", comment: "").uppercased(),
                value: AppConstants.versionDisplayString,
                icon: "info.circle",
                valueColor: AppConstants.isNonProductionBuild ? .orange : Color.CT.textDim
            )
                .contentShape(Rectangle())
                .onTapGesture {
                    versionTapCount += 1
                    if versionTapCount >= 10 {
                        versionTapCount = 0
                        emergencyPasteText = ""
                        emergencyImportMsg = nil
                        showEmergencyImport = true
                    }
                }
        }
        .alert(NSLocalizedString("veil_config_paste", comment: ""), isPresented: $showEmergencyImport) {
            TextField(NSLocalizedString("veil_config_paste", comment: ""), text: $emergencyPasteText)
            Button(NSLocalizedString("veil_config_import", comment: "")) { handleEmergencyImport() }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        } message: {
            if let m = emergencyImportMsg { Text(m) }
        }
    }

    private var developerSection: some View {
        CTSectionGroup {
            NavigationLink(destination: DiagnosticsView()) {
                CTSettingsRow(label: NSLocalizedString("diagnostics_logs", comment: "").uppercased(), labelColor: .orange, disclosure: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recovery Banner

    private var recoveryBanner: some View {
        HStack(alignment: .top, spacing: SettingsRootLayout.recoveryBannerContentSpacing) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: SettingsRootLayout.recoveryBannerIconSize, weight: .semibold))
                .foregroundColor(Color.CT.danger)
            VStack(alignment: .leading, spacing: SettingsRootLayout.recoveryBannerTextSpacing) {
                Text(NSLocalizedString("recovery_not_configured_title", comment: "").uppercased())
                    .font(CTFont.bold(11))
                    .foregroundColor(Color.CT.danger)
                Text(NSLocalizedString("recovery_banner_subtitle", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
                Button {
                    showingRecoverySetup = true
                } label: {
                    HStack(spacing: SettingsRootLayout.recoveryBannerActionSpacing) {
                        Text(NSLocalizedString("recovery_setup_action", comment: ""))
                            .font(CTFont.bold(11))
                        Image(systemName: "chevron.right")
                            .font(.system(size: SettingsRootLayout.recoveryBannerChevronSize, weight: .semibold))
                    }
                    .foregroundColor(Color.CT.accent)
                }
            }
            Spacer()
            Button {
                recoveryBannerDismissed = true
                UserDefaults.standard.set(true, forKey: "recovery_banner_dismissed")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: SettingsRootLayout.recoveryBannerDismissIconSize))
                    .foregroundColor(Color.CT.textDim)
            }
        }
        .padding(SettingsRootLayout.recoveryBannerPadding)
        .background(Color.CT.danger.opacity(0.06))
        .clipShape(CTShape.control())
        .overlay(
            CTShape.control()
                .stroke(Color.CT.danger.opacity(0.4), lineWidth: SettingsRootLayout.recoveryBannerStrokeWidth)
        )
        .padding(.horizontal, SettingsRootLayout.recoveryBannerHorizontalPadding)
        .padding(.vertical, SettingsRootLayout.recoveryBannerVerticalPadding)
    }

    // MARK: - Helpers

    private var profileDisplayName: String {
        if !viewModel.displayName.isEmpty { return viewModel.displayName }
        if !viewModel.userId.isEmpty { return DisplayNameGenerator.generate(from: viewModel.userId) }
        return NSLocalizedString("account", comment: "")
    }

    private var profileInitials: String {
        let name = profileDisplayName
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(name.prefix(2)).uppercased()
    }

}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()
    let recoveryVM = AccountRecoveryViewModel()
    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)
    return SettingsView()
        .environment(\.managedObjectContext, context)
        .environment(authViewModel)
        .environment(recoveryVM)
        .environment(SocialRecoveryService())
        .environment(chatsVM)
        .environment(SecurityViewModel())
}
#endif
