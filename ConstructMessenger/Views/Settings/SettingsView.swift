//
//  SettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    @State private var viewModel = SettingsViewModel()
    private var connectionStatus = ConnectionStatusManager.shared
    @State private var showingQRCode = false
    @State private var linkCopied = false
    @State private var showingRecoverySetup = false
   
    
    private let inviteGenerator = InviteGenerator()
        
    private let sectionCornerRadius: CGFloat = 16  // Change to adjust rounding

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {

                        // MARK: - Recovery Banner
                        if recoveryVM.statusLoaded && !recoveryVM.isSetup {
                            Button {
                                showingRecoverySetup = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundColor(.orange)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(NSLocalizedString("recovery_banner_title", comment: ""))
                                            .font(.subheadline.bold())
                                            .foregroundColor(.primary)
                                        Text(NSLocalizedString("recovery_banner_subtitle", comment: ""))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .padding(12)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(12)
                                .padding(.horizontal)
                            }
                        }

                        // MARK: - Profile Section
                        settingsSection {
                            NavigationLink(destination: AccountSettingsView().environment(authViewModel)) {
                                HStack(spacing: 12) {
                                    Group {
                                        if let image = viewModel.profileImage {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            AvatarStyle.squircle(AvatarStyle.settingsSize)
                                                .fill(Color.blue)
                                                .overlay {
                                                    Text(profileInitials)
                                                        .foregroundColor(.white)
                                                        .fontWeight(.semibold)
                                                }
                                        }
                                    }
                                    .frame(width: AvatarStyle.settingsSize, height: AvatarStyle.settingsSize)
                                    .clipShape(AvatarStyle.squircle(AvatarStyle.settingsSize))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profileDisplayName)
                                            .font(.headline)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }

                        // MARK: - Share Section
                        settingsSection {
                            Button { showingQRCode = true } label: {
                                settingsRow(icon: "qrcode", text: "show_my_qr_code")
                            }
                            .buttonStyle(.plain)
                            settingsDivider()
                            Button { copyContactLink() } label: {
                                settingsRow(
                                    icon: linkCopied ? "checkmark.circle.fill" : "link",
                                    text: linkCopied ? "link_copied" : "copy_contact_link",
                                    iconColor: linkCopied ? Color.AppStatus.success : .gray
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(linkCopied)
                        }

                        // MARK: - App Settings Section
                        settingsSection {
                            settingsNavRow(icon: "lock", text: "Security", destination: SecurityView())
                            settingsDivider()
                            settingsNavRow(icon: "laptopcomputer", text: "Devices", destination: DevicesView())
                            settingsDivider()
                            settingsNavRow(icon: "paintbrush", text: "appearance", destination: AppearanceSettingsView())
                            settingsDivider()
                            settingsNavRow(icon: "bell", text: "notifications", destination: NotificationsSettingsView())
                            settingsDivider()
                            NavigationLink(destination: BackgroundFetchSettingsView()) {
                                HStack {
                                    Image(systemName: "arrow.clockwise.circle").foregroundColor(.gray).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LocalizedStringKey("background_fetch"))
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(BackgroundFetchConfig.shouldBeEnabled ? Color.AppStatus.success : Color.gray)
                                                .frame(width: 6, height: 6)
                                            Text(LocalizedStringKey(BackgroundFetchConfig.shouldBeEnabled ? "enabled" : "disabled"))
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            settingsDivider()
                            NavigationLink(destination: NetworkSettingsView()) {
                                HStack {
                                    Image(systemName: "network").foregroundColor(.gray).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LocalizedStringKey("network"))
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(connectionStatus.isConnected ? Color.AppStatus.success : Color.red)
                                                .frame(width: 6, height: 6)
                                            Text(LocalizedStringKey(connectionStatus.connectionStatus.localizedKey))
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            settingsDivider()
                            settingsNavRow(icon: "folder", text: "Drafts", destination: DraftsView())
                        }

                        // MARK: - About Section
                        settingsSection {
                            HStack {
                                Image(systemName: "info.circle").foregroundColor(.gray).frame(width: 22)
                                Text(LocalizedStringKey("version"))
                                Spacer()
                                Text("Construct v\(AppConstants.appVersion)").foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }

                        // MARK: - Developer Section
//                        #if DEBUG
                        settingsSection(header: "Developer") {
                            NavigationLink(destination: DiagnosticsView()) {
                                HStack {
                                    Text("Diagnostics & Logs").foregroundStyle(.orange)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
//                        #endif
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationBarHidden(true)
                .onAppear {
                    viewModel.setContext(viewContext)
                    viewModel.loadUserInfo(from: authViewModel)
                }
                .task { await recoveryVM.loadStatus() }
                .sheet(isPresented: $showingRecoverySetup) {
                    RecoverySetupView()
                        .environment(recoveryVM)
                        .environment(authViewModel)
                        .onDisappear { Task { await recoveryVM.refreshStatus() } }
                }
                .sheet(isPresented: $showingQRCode) {
                    ContactQRCodeView(
                        userId: viewModel.userId,
                        username: viewModel.username
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        
    // MARK: - Section Helpers

    @ViewBuilder
    private func settingsSection<Content: View>(
        header: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        }
    }

    private func settingsRow(
        icon: String,
        text: String,
        iconColor: Color = .gray
    ) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(iconColor).frame(width: 22)
            Text(LocalizedStringKey(text))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func settingsNavRow<Destination: View>(
        icon: String,
        text: String,
        destination: Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Image(systemName: icon).foregroundColor(.gray).frame(width: 22)
                Text(LocalizedStringKey(text))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsDivider() -> some View {
        Divider().padding(.leading, 54)
    }

    // MARK: - Contact Link
    private var contactLink: String {
        guard let userId = authViewModel.currentUserId else {
            Log.error("Cannot generate contact link: userId is nil", category: "SettingsView")
            return ""
        }
        
        Log.info("Generating contact link for userId: \(userId)", category: "SettingsView")
        
        // ✅ Use public invite host (.well-known lives here)
        let serverHostname = ServerConfig.inviteHost
        
        // ✅ Generate Dynamic Invite deep link (HTTPS format for sharing)
        do {
            // Get deviceId from Keychain
            guard let deviceId = KeychainManager.shared.loadDeviceID() else {
                Log.error("Cannot generate link: deviceId not found in Keychain", category: "SettingsView")
                return ""
            }
            
            let link = try inviteGenerator.generateDeepLink(
                userId: userId,
                deviceId: deviceId,
                server: serverHostname,
                useHTTPS: true
            )
            
            Log.info("✅ Generated deep link: \(link.prefix(50))...", category: "SettingsView")
            return link
        } catch {
            Log.error("Failed to generate invite link: \(error)", category: "SettingsView")
            return ""
        }
    }
        
    private var profileDisplayName: String {
        if !viewModel.displayName.isEmpty {
            return viewModel.displayName
        }
        if !viewModel.userId.isEmpty {
            return DisplayNameGenerator.generate(from: viewModel.userId)
        }
        return NSLocalizedString("account", comment: "")
    }

    private var profileInitials: String {
        let name = profileDisplayName
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func copyContactLink() {
        Task { await copyContactLinkAsync() }
    }

    @MainActor
    private func copyContactLinkAsync() async {
        guard authViewModel.currentUserId != nil else {
            Log.error("Cannot copy contact link: userId is nil", category: "SettingsView")
            return
        }

        let link = contactLink
        PlatformClipboard.copy(link)
        Log.info("Contact link copied: \(link.prefix(50))...", category: "SettingsView")

        // Show visual feedback
        withAnimation {
            linkCopied = true
        }

        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                linkCopied = false
            }
        }
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()

    return SettingsView()
        .environment(\.managedObjectContext, context)
        .environment(authViewModel)
        .environment(SecurityViewModel())
}
#endif
