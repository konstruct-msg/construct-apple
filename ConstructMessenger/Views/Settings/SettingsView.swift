//
//  SettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var connectionStatus = ConnectionStatusManager.shared
    @State private var showingQRCode = false
    @State private var linkCopied = false
   
    
    private let inviteGenerator = InviteGenerator()
        
        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    // MARK: - Custom Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Settings")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .background(Color.AppBackground.primary)
                    
                    Divider()
                    
                    // MARK: - Settings List
                    List {
                        // MARK: - Profile Section
                        Section {
                            NavigationLink(destination: AccountSettingsView().environmentObject(authViewModel)) {
                                HStack(spacing: 12) {
                                    Group {
                                        if let image = viewModel.profileImage {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            RoundedRectangle(cornerRadius: AvatarStyle.settingsCornerRadius, style: .continuous)
                                                .fill(Color.blue)
                                                .overlay {
                                                    Text(profileInitials)
                                                        .foregroundColor(.white)
                                                        .fontWeight(.semibold)
                                                }
                                        }
                                    }
                                    .frame(width: AvatarStyle.settingsSize, height: AvatarStyle.settingsSize)
                                    .clipShape(RoundedRectangle(cornerRadius: AvatarStyle.settingsCornerRadius, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profileDisplayName)
                                            .font(.headline)
                                        if !viewModel.username.isEmpty {
                                            Text("@\(viewModel.username)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text("account")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        
                        Section {
                            
                            Button {
                                showingQRCode = true
                            } label: {
                                Label {
                                    Text("show_my_qr_code")
                                        .foregroundColor(.primary)
                                } icon: {
                                    Image(systemName: "qrcode")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            Button {
                                copyContactLink()
                            } label: {
                                Label {
                                    Text(linkCopied ? "link_copied" : "copy_contact_link")
                                        .foregroundColor(.primary)
                                } icon: {
                                    Image(systemName: linkCopied ? "checkmark.circle.fill" : "link")
                                        .foregroundColor(linkCopied ? .green : .gray)
                                }
                            }
                            .disabled(linkCopied)
                        }
                        
                        // MARK: - App Settings Section
                        Section {
                            NavigationLink(destination: SecurityView()) {
                                Label {
                                    Text("Security")
                                } icon: {
                                    Image(systemName: "lock")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            NavigationLink(destination: DevicesView()) {
                                Label {
                                    Text("Devices")
                                } icon: {
                                    Image(systemName: "laptopcomputer")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            NavigationLink(destination: AppearanceSettingsView()) {
                                Label {
                                    Text("appearance")
                                } icon: {
                                    Image(systemName: "paintbrush")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            NavigationLink(destination: NotificationsSettingsView()) {
                                Label {
                                    Text("notifications")
                                } icon: {
                                    Image(systemName: "bell")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            NavigationLink(destination: BackgroundFetchSettingsView()) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("background_fetch")
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(BackgroundFetchConfig.shouldBeEnabled ? Color.green : Color.gray)
                                                .frame(width: 6, height: 6)
                                            Text(BackgroundFetchConfig.shouldBeEnabled ? "enabled" : "disabled")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: "arrow.clockwise.circle")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            NavigationLink(destination: NetworkSettingsView()) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("network")
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(connectionStatus.isConnected ? Color.green : Color.red)
                                                .frame(width: 6, height: 6)
                                            Text(connectionStatus.connectionStatus.localizedKey)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: "network")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            NavigationLink(destination: DraftsView()) {
                                Label {
                                    Text("Drafts")
                                } icon: {
                                    Image(systemName: "folder")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        
                        // MARK: - About Section
                        Section {
                            HStack {
                                Label {
                                    Text("version")
                                } icon: {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Text("Construct v\(AppConstants.appVersion)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .padding(.vertical, 0)
                }
                .navigationBarHidden(true) // Скрываем стандартную навигационную панель
                .onAppear {
                    viewModel.setContext(viewContext)
                    viewModel.loadUserInfo(from: authViewModel)
                }
                .sheet(isPresented: $showingQRCode) {
                    ContactQRCodeView(
                        userId: viewModel.userId,
                        username: viewModel.username
                    )
                }
            }
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
        UIPasteboard.general.string = link
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

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()

    return SettingsView()
        .environment(\.managedObjectContext, context)
        .environmentObject(authViewModel)
        .environmentObject(SecurityViewModel())
}
