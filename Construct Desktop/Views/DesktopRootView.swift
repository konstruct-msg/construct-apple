//
//  DesktopRootView.swift
//  Construct Desktop
//
//  Root view for the macOS app.
//  Mirrors ContentView.swift (iOS) — routes between onboarding and main UI
//  based on AuthViewModel.hasRegisteredDeviceKeys.
//

import SwiftUI
import CoreData
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let desktopShowAddContact = Notification.Name("desktopShowAddContact")
    static let desktopSelectNextChat = Notification.Name("desktopSelectNextChat")
    static let desktopSelectPrevChat = Notification.Name("desktopSelectPrevChat")
    static let desktopJumpToChat     = Notification.Name("desktopJumpToChat")
}

struct DesktopRootView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(DeepLinkHandler.self) private var deepLinkHandler
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.commandBridge) private var commandBridge
    @Environment(\.openSettings) private var openSettings
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic
    @AppStorage(OrientationStore.completedUserIdsKey) private var orientationCompletedUserIds = ""

    @State private var showAddContact = false
    @State private var sidebarMode: SidebarMode = .chats
    @State private var callManager = CallManager.shared
    @State private var showReceiveHistorySync = false
    @State private var historySyncPendingDeviceId: String? = nil

    private enum SidebarMode: Hashable { case chats, synaps }

    private var orientationCompletedForCurrentUser: Bool {
        OrientationStore.isCompleted(
            for: authViewModel.currentUserId ?? AuthSessionManager.shared.currentUserId,
            rawList: orientationCompletedUserIds
        )
    }

    /// Derives the Nearby-transfer PIN for the post-link history sync. The `pendingDeviceId` the
    /// phone hashed is THIS device's freshly-linked deviceId (it generated the join request under
    /// it), which equals `KeychainManager.loadDeviceID()`. Prefer the value plumbed through the
    /// link phase, but fall back to our own deviceId so the auto-PIN survives a dropped/late phase
    /// hand-off (otherwise the receiver degrades to a manual 6-digit PIN prompt).
    private func historySyncPairingPIN(for pendingId: String?) -> String? {
        guard let userId = authViewModel.currentUserId ?? KeychainManager.shared.loadUserID(),
              !userId.isEmpty else { return nil }
        let resolvedPendingId = (pendingId?.isEmpty == false ? pendingId : nil)
            ?? KeychainManager.shared.loadDeviceID()
        guard let resolvedPendingId, !resolvedPendingId.isEmpty else { return nil }
        return HistorySyncPairing.pin(pendingDeviceId: resolvedPendingId, userId: userId)
    }

    var body: some View {
        Group {
            if authViewModel.hasRegisteredDeviceKeys == nil {
                SplashView()
            } else if authViewModel.deviceKeysUnavailable {
                KeysRecoveryView()
                    .environment(authViewModel)
            } else if authViewModel.deviceDeregistered {
                // Server rejected this device as unregistered — recover, don't wipe silently.
                KeysRecoveryView(reason: .deviceDeregistered)
                    .environment(authViewModel)
            } else if authViewModel.isAuthenticated || authViewModel.hasRegisteredDeviceKeys == true {
                if orientationCompletedForCurrentUser {
                    mainContent
                } else {
                    OrientationView(openSynapsOnFinish: true)
                }
            } else {
                OnboardingView()
                    .environment(authViewModel)
                    .onDisappear {
                        authViewModel.refreshDeviceKeyState()
                    }
            }
        }
        .errorToast()
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear {
            authViewModel.refreshDeviceKeyState()
            chatsViewModel.setContext(viewContext)
            wireCommandBridge()
            handleDeepLink(deepLinkHandler.deepLink)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatForKeyChange)) { note in
            guard let userId = note.userInfo?["userId"] as? String, !userId.isEmpty else { return }
            let fetch = User.fetchRequest()
            fetch.predicate = NSPredicate(format: "id == %@", userId)
            fetch.fetchLimit = 1
            if let user = try? viewContext.fetch(fetch).first {
                chatsViewModel.openOrCreateChat(with: user)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appWillEnterForeground)) { _ in
            if AuthSessionManager.shared.sessionToken == nil || !AuthSessionManager.shared.isSessionValid
                || !CryptoManager.shared.isInitialized {
                Log.info("Desktop returning to foreground — restoring session (token missing, expired, or crypto uninitialised)", category: "Auth")
                authViewModel.restoreSession()
            }

            if AuthSessionManager.shared.isSessionValid,
               StealthPolicy.shared.isEnabled,
               TokenWalletService.shared.balance < 10 {
                Task {
                    await BlindTokenService.shared.bootstrapInitialBatch()
                }
            }

            if AuthSessionManager.shared.isSessionValid, CryptoManager.shared.isInitialized {
                Task {
                    await SessionInitializationService.shared.upgradeAllAtRiskSessionsOnForeground()
                }
            }
        }
        .onChange(of: deepLinkHandler.deepLink) { _, newDeepLink in
            handleDeepLink(newDeepLink)
        }
        .onOpenURL { url in
            Log.info("DesktopRootView: Received URL via onOpenURL: \(url.absoluteString)", category: "DeepLink")
            let result = deepLinkHandler.handleURL(url)
            Log.info("DesktopRootView: Deep link handling result: \(result)", category: "DeepLink")
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopShowAddContact)) { _ in
            showAddContact = true
        }
        .onChange(of: chatsViewModel.totalUnreadCount) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onChange(of: authViewModel.deviceLinkPhase) { _, phase in
            if case .historySyncReceive(let pendingId) = phase {
                historySyncPendingDeviceId = pendingId
                showReceiveHistorySync = true
            }
        }
        .sheet(isPresented: $showReceiveHistorySync) {
            ReceiveBackupNearbyView(
                mode: .historySync,
                autoPairingPIN: historySyncPairingPIN(for: historySyncPendingDeviceId)
            )
            .onDisappear {
                authViewModel.clearDeviceLinkPhase()
                historySyncPendingDeviceId = nil
            }
        }
    }

    // Wire keyboard commands → ViewModels

    private func wireCommandBridge() {
        commandBridge.onNewConversation = { chatsViewModel.showNewChat = true }
        commandBridge.onAddContact      = { showAddContact = true }
        commandBridge.onFocusSearch     = { focusSidebarSearch() }
        commandBridge.onGlobalSearch    = { focusSidebarSearch() }
        commandBridge.onSelectNext      = {
            NotificationCenter.default.post(name: .desktopSelectNextChat, object: nil)
        }
        commandBridge.onSelectPrev      = {
            NotificationCenter.default.post(name: .desktopSelectPrevChat, object: nil)
        }
        commandBridge.onJumpToIndex     = { idx in
            NotificationCenter.default.post(name: .desktopJumpToChat, object: idx)
        }
        commandBridge.onBack            = { chatsViewModel.chatToOpen = nil }
        commandBridge.onCopyNodeId      = {
            guard let id = chatsViewModel.chatToOpen else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        }
        commandBridge.onSyncMessages    = {
            Log.info("Manual message sync (⌘R)", category: "Desktop")
            Task { await BackgroundFetchManager.shared.fetchPendingMessages() }
        }
        commandBridge.onShowSecurity    = {
            UserDefaults.standard.set(
                DesktopSettingsSelection.securitySectionRawValue,
                forKey: DesktopSettingsSelection.selectedSectionKey
            )
            openSettings()
        }
    }

    private func focusSidebarSearch() {
        withAnimation(.easeInOut(duration: 0.15)) {
            sidebarMode = .chats
        }
        chatsViewModel.sidebarSearchFocused = true
    }

    // MARK: - Main split view (authenticated)

    private var mainContent: some View {
        let splitView = HSplitView {
            sidebarPane
            detailPane
        }
        .background(Color.CT.bg)

        let decorated = splitView
            .frame(minWidth: 700, minHeight: 480)
            .onReceive(NotificationCenter.default.publisher(for: .openSynapsTab)) { _ in
                withAnimation(.easeInOut(duration: 0.15)) {
                    sidebarMode = .synaps
                }
            }
            // Opening a chat is a request to see it, wherever it came from — a row in the people
            // list, a node in the Synaps cloud, a deep link. Handled here rather than in either
            // child because both of them do it and neither owns `sidebarMode`; a callback per child
            // would be the same rule written twice, and the one added second would be the one that
            // drifted. Only a *change* flips the mode, so entering PEOPLE with a chat still open
            // from before does not bounce straight back out.
            .onChange(of: chatsViewModel.chatToOpen) { _, newValue in
                guard newValue != nil, sidebarMode == .synaps else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    sidebarMode = .chats
                }
            }
            // Incoming call banner — bottom-center
            .overlay(alignment: .bottom) {
                if CallsFeature.isEnabled, case .incoming(let session) = callManager.state {
                    DesktopIncomingCallView(session: session)
                        .zIndex(100)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isIncomingState)
                }
            }
            // In-call controls strip — bottom-right
            .overlay(alignment: .bottomTrailing) {
                if CallsFeature.isEnabled, isActiveOrConnecting, let session = activeCallSession {
                    DesktopInCallView(
                        session: session,
                        isConnecting: isConnectingState,
                        endReason: callEndReason
                    )
                    .zIndex(100)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isActiveOrConnecting)
                }
            }
            // Add Contact sheet (⌘⌥N)
            .sheet(isPresented: $showAddContact) {
                DesktopAddContactView()
                    .environment(authViewModel)
                    .environment(deepLinkHandler)
            }
            // New Chat sheet (⌘N)
            .sheet(isPresented: Binding(
                get: { chatsViewModel.showNewChat },
                set: { chatsViewModel.showNewChat = $0 }
            )) {
                NewChatView(chatsViewModel: chatsViewModel)
                    .environment(\.managedObjectContext, viewContext)
                    .frame(minWidth: 400, minHeight: 300)
            }

        return decorated
    }

    /// What fills the pane to the right of the sidebar.
    ///
    /// **The detail follows the sidebar mode**, which is the rule the `HSplitView` conversion lost.
    /// Before it, `.synaps` put `DesktopSynapsView` in the detail column and hid the sidebar
    /// (`columnVisibility = .detailOnly`); the conversion removed the hiding — which is all that was
    /// wanted — and, with it, the only reference to `DesktopSynapsView` in the app. The view kept
    /// compiling, so nothing said so: picking PEOPLE showed a people list beside an empty state, and
    /// the honeycomb cloud, the profile popovers and **the incoming contact-request section** —
    /// which exists nowhere else on Desktop — became unreachable.
    @ViewBuilder
    private var detailPane: some View {
        if sidebarMode == .synaps {
            // No `onSwitchToChats`: that button existed because Synaps used to occupy the whole
            // window with no other way back. The mode picker in the sidebar is always visible now,
            // so the button would be a second control for one thing.
            DesktopSynapsView()
                .environment(chatsViewModel)
                .environment(\.managedObjectContext, viewContext)
        } else if let chatId = chatsViewModel.chatToOpen,
                  let chat = fetchChat(id: chatId) {
            DesktopChatView(chat: chat, context: viewContext)
                .ignoresSafeArea(.container, edges: .top) // ensure custom glass nav is flush to the top of the split detail column
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers, into: chat)
                }
        } else {
            DesktopEmptyStateView()
                .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
        }
    }

    private var sidebarPane: some View {
        VStack(spacing: 0) {
            sidebarModeBar
            Rectangle().fill(Color.CT.noise).frame(height: 1)

            if sidebarMode == .chats {
                DesktopChatsListView()
                    .environment(chatsViewModel)
            } else {
                DesktopPeopleListView()
                    .environment(chatsViewModel)
            }
        }
        .background(Color.CT.bg)
        .frame(minWidth: 230, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.CT.noise)
                .frame(width: 1)
        }
    }

    // MARK: - Call state helpers

    private var isIncomingState: Bool {
        if case .incoming = callManager.state { return true }
        return false
    }

    private var isActiveOrConnecting: Bool {
        switch callManager.state {
        case .dialing, .active, .connecting, .ringing, .ended: return true
        default: return false
        }
    }

    private var isConnectingState: Bool {
        switch callManager.state {
        case .dialing, .connecting, .ringing: return true
        default: return false
        }
    }

    private var activeCallSession: CallSession? {
        switch callManager.state {
        case .dialing(let s), .active(let s), .connecting(let s), .ringing(let s): return s
        case .ended(let s, _): return s
        default: return nil
        }
    }

    private var callEndReason: CallEndReason? {
        if case .ended(_, let reason) = callManager.state { return reason }
        return nil
    }

    // MARK: - Sidebar header

    private var sidebarModeBar: some View {
        GeometryReader { proxy in
            Picker("", selection: $sidebarMode) {
                Text(LocalizedStringKey("chats"))
                    .font(CTFont.medium(12))
                    .tag(SidebarMode.chats)
                Text(LocalizedStringKey("people"))
                    .font(CTFont.medium(12))
                    .tag(SidebarMode.synaps)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: proxy.size.width)
            .frame(height: proxy.size.height, alignment: .center)
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .background(Color.CT.bg)
    }

    // MARK: - Drag & Drop into chat

    private func handleDrop(providers: [NSItemProvider], into chat: Chat) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        // Push dropped image to ChatView via ChatsViewModel
                        chatsViewModel.pendingDroppedImage = image
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        chatsViewModel.pendingDroppedFileURL = url
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func fetchChat(id: String) -> Chat? {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        return try? viewContext.fetch(req).first
    }

    // MARK: - Deep links

    private func handleDeepLink(_ deepLink: DeepLinkType?) {
        Log.debug("DesktopRootView: Deep link changed: \(String(describing: deepLink))", category: "DeepLink")
        if case .contact(let contactInfo) = deepLink {
            Log.info("DesktopRootView: Creating chat for userId: \(contactInfo.userId)", category: "DeepLink")
            let publicUserInfo = PublicUserInfo(
                id: contactInfo.userId,
                username: contactInfo.username,
                avatarUrl: nil,
                bio: nil,
                deviceId: contactInfo.deviceId
            )
            if let chat = chatsViewModel.startChat(
                with: publicUserInfo,
                identityPublicKey: contactInfo.identityPublicKey
            ) {
                chatsViewModel.chatToOpen = chat.id
                InviteRedeemUX.presentPostRedeemSafety(for: contactInfo)
            } else {
                Log.error("DesktopRootView: Failed to create chat for userId: \(contactInfo.userId)", category: "DeepLink")
            }
            deepLinkHandler.deepLink = nil
        } else if case .openChat(let chatId) = deepLink {
            Log.info("DesktopRootView: Opening chat from deep link: \(chatId)", category: "DeepLink")
            chatsViewModel.chatToOpen = chatId
            deepLinkHandler.deepLink = nil
        }
    }
}

// MARK: - Xcode Previews

#Preview("Empty state (no chat selected)") {
    // Shows the detail pane when no conversation is open — quick layout check
    // without needing to launch the full app.
    DesktopEmptyStateView()
        .frame(width: 760, height: 500)
}

#Preview("Add Contact sheet") {
    DesktopAddContactView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(DeepLinkHandler())
}
