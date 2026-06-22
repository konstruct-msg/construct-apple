//
//  SettingsView.swift
//  Construct Messenger
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    @Environment(SocialRecoveryService.self) private var socialRecoveryService
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @State private var viewModel = SettingsViewModel()
    private var connectionStatus = ConnectionStatusManager.shared
    @State private var showingQRCode = false
    @State private var linkCopied = false
    @State private var showingRecoverySetup = false
    @State private var recoveryBannerDismissed = UserDefaults.standard.bool(forKey: "recovery_banner_dismissed")
    @State private var navigationPath = NavigationPath()

    private let inviteGenerator = InviteGenerator()

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
                        // MARK: Recovery warning
                        if recoveryVM.statusLoaded && !recoveryVM.isSetup && !recoveryBannerDismissed {
                            recoveryBanner
                        }

                        // MARK: Profile
                        CTSectionGroup {
                            NavigationLink(destination: AccountSettingsView()
                                .environment(authViewModel)
                                .environment(recoveryVM)
                                .environment(socialRecoveryService)
                                .environment(viewModel)) {
                                profileRow
                            }
                            .buttonStyle(.plain)
                        }

                        // MARK: Share
                        CTSectionGroup {
                            Button { showingQRCode = true } label: {
                                CTSettingsRow(label: NSLocalizedString("show_qr_code", comment: "").uppercased(), icon: "qrcode", isAction: true, disclosure: true)
                            }
                            .buttonStyle(.plain)
                            CTSep(style: .thin)
                            
                            Button { copyContactLink() } label: {
                                CTSettingsRow(
                                    label: linkCopied ? NSLocalizedString("link_copied", comment: "").uppercased() : NSLocalizedString("copy_contact_link", comment: "").uppercased(),
                                    icon: linkCopied ? "checkmark" : "link",
                                    labelColor: linkCopied ? Color.CT.accentDim : Color.CT.text,
                                    disclosure: !linkCopied
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(linkCopied)
                        }

                        // MARK: Settings
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
                            NavigationLink(destination: BackgroundFetchSettingsView()) {
                                CTSettingsRow(
                                    label: NSLocalizedString("background_fetch", comment: "").uppercased(),
                                    value: BackgroundFetchConfig.shouldBeEnabled ? "[on]" : "[off]",
                                    icon: "arrow.clockwise.circle",
                                    valueColor: BackgroundFetchConfig.shouldBeEnabled ? Color.CT.accentDim : Color.CT.textDim,
                                    disclosure: true
                                )
                            }
                            .buttonStyle(.plain)
                            CTSep(style: .thin)
                            NavigationLink(destination: NetworkSettingsView()) {
                                CTSettingsRow(
                                    label: NSLocalizedString("network", comment: "").uppercased(),
                                    value: connectionStatus.isConnected ? "[ok]" : "[err]",
                                    icon: "globe",
                                    valueColor: connectionStatus.isConnected ? Color.CT.accentDim : Color.CT.danger,
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

                        // MARK: About

                        CTSectionGroup {
                            CTSettingsRow(label: NSLocalizedString("version", comment: "").uppercased(), value: "v\(AppConstants.appVersion) (\(AppConstants.buildNumber))", icon: "info.circle")
                        }

                        // MARK: Developer
                        CTSectionGroup {
                            NavigationLink(destination: DiagnosticsView()) {
                                CTSettingsRow(label: NSLocalizedString("diagnostics_logs", comment: "").uppercased(), labelColor: .orange, disclosure: true)
                            }
                            .buttonStyle(.plain)
                        }

                        // Spacer for floating tab capsule
                        Color.clear
                            .frame(height: 72)
                    }
                    .padding(.bottom, SettingsRootLayout.listBottomPadding)
                }
            }
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
        }
    }

    // MARK: - Profile Row

    private var profileRow: some View {
        HStack(spacing: SettingsRootLayout.profileRowSpacing) {
            let img: Image? = {
                guard let ui = viewModel.profileImage else { return nil }
                return Image(uiImage: ui)
            }()
            CTHexAvatar(initials: profileInitials, image: img, size: .large)

            VStack(alignment: .leading, spacing: SettingsRootLayout.profileMetaSpacing) {
                Text(profileDisplayName.uppercased())
                    .font(CTFont.bold(15))
                    .foregroundColor(Color.CT.text)
                Text(viewModel.username.isEmpty ? NSLocalizedString("username_not_set", comment: "") : "@\(viewModel.username)")
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                Text(viewModel.isDiscoverable
                    ? NSLocalizedString("searchable_indicator", comment: "")
                    : NSLocalizedString("searchable_indicator_off", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundColor(viewModel.isDiscoverable ? Color.CT.accent : Color.CT.noise)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.accent)
        }
        .padding(.horizontal, SettingsRootLayout.profileRowHorizontalPadding)
        .padding(.vertical, SettingsRootLayout.profileRowVerticalPadding)
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
        .clipShape(RoundedRectangle(cornerRadius: SettingsRootLayout.recoveryBannerCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsRootLayout.recoveryBannerCornerRadius)
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

    private func copyContactLink() {
        Task { await copyContactLinkAsync() }
    }

    @MainActor
    private func copyContactLinkAsync() async {
        guard authViewModel.currentUserId != nil else { return }
        guard let deviceId = KeychainManager.shared.loadDeviceID() else { return }
        let serverHostname = ServerConfig.inviteHost
        guard let link = try? inviteGenerator.generateDeepLink(
            userId: viewModel.userId,
            deviceId: deviceId,
            username: viewModel.resolvedDisplayName,
            server: serverHostname,
            useHTTPS: true
        ) else { return }
        PlatformClipboard.copy(link)
        withAnimation { linkCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { linkCopied = false }
        }
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
