//
//  DesktopRootView.swift
//  Construct Desktop
//
//  Root view for the macOS app.
//  Mirrors ContentView.swift (iOS) — routes between onboarding and main UI
//  based on AuthViewModel.hasRegisteredDeviceKeys.
//

import SwiftUI
import Combine
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("appTheme") private var appTheme: AppTheme = .dark
    @AppStorage(OrientationStore.completedUserIdsKey) private var orientationCompletedUserIds = ""

    @State private var showAddContact = false
    /// The recovery key, offered once right after the first orientation — same as iOS
    /// `ContentView`. Contacts wait on it (`RecoveryGated`), so this is where it is asked for
    /// before anyone reaches for an invite.
    @State private var showingRecoveryPrompt = false
    /// Read again when the recovery sheet closes: `AccountAddress` is not observable.
    @State private var hasAccountAddress = AccountAddress.own() != nil
    @State private var callManager = CallManager.shared
    @State private var showReceiveHistorySync = false
    /// Why the store is not open, or nil (`LocalRepositories.storeFailure`): read at launch, after
    /// a retry, and whenever the store is replaced.
    @State private var storeFailure = LocalRepositories.storeFailure
    @State private var historySyncPendingDeviceId: String? = nil

    private var orientationCompletedForCurrentUser: Bool {
        OrientationStore.isCompleted(
            for: authViewModel.currentUserId ?? AuthSessionManager.shared.currentUserId,
            rawList: orientationCompletedUserIds
        )
    }

    var body: some View {
        Group {
            if storeFailure != nil {
                // Before anything else: no screen of the app runs on a store that is not open.
                NavigationStack {
                    KeysRecoveryView(reason: .storeUnreadable) {
                        storeFailure = LocalRepositories.openAppStoreIfNeeded()
                    }
                }
                .environment(authViewModel)
            } else if authViewModel.hasRegisteredDeviceKeys == nil {
                SplashView()
            } else if authViewModel.deviceKeysUnavailable {
                // A screen of its own, so it brings the stack its title needs.
                NavigationStack { KeysRecoveryView() }
                    .environment(authViewModel)
            } else if authViewModel.deviceDeregistered {
                // Server rejected this device as unregistered — recover, don't wipe silently.
                NavigationStack { KeysRecoveryView(reason: .deviceDeregistered) }
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
        // The People window outlives a sign-out and its @FetchRequest keeps faults into the store
        // that was just replaced; the next redraw raises. Close it with the data it was showing.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreReplaced).receive(on: DispatchQueue.main)) { _ in
            dismissWindow(id: DesktopWindowID.synaps)
            storeFailure = LocalRepositories.storeFailure
        }
        .onChange(of: orientationCompletedForCurrentUser) { _, completed in
            if completed, AccountAddress.own() == nil {
                showingRecoveryPrompt = true
            }
        }
        .onChange(of: showingRecoveryPrompt) { _, showing in
            if !showing { hasAccountAddress = AccountAddress.own() != nil }
        }
        .sheet(isPresented: $showingRecoveryPrompt) {
            RecoveryGateView(reason: .afterRegistration).sheetNavigation(closes: false)
                .frame(minWidth: 460, minHeight: 560)
        }
        .onAppear {
            authViewModel.refreshDeviceKeyState()
            chatsViewModel.setContext(viewContext)
            wireCommandBridge()
            handleDeepLink(deepLinkHandler.deepLink)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatForKeyChange)) { note in
            guard let userId = note.userInfo?["userId"] as? String, !userId.isEmpty else { return }
            chatsViewModel.openOrCreateChat(withContact: userId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appWillEnterForeground)) { _ in
            if AuthSessionManager.shared.sessionToken == nil || !AuthSessionManager.shared.isSessionValid
                || !CryptoManager.shared.isInitialized {
                Log.info("Desktop returning to foreground — restoring session (token missing, expired, or crypto uninitialised)", category: "Auth")
                authViewModel.restoreSession()
            }

            // No balance threshold here — `BlindTokenService.bootstrapAction` owns that decision.
            // See the same call site in ContentView.
            if AuthSessionManager.shared.isSessionValid,
               StealthPolicy.shared.isEnabled {
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
            Log.info("Desktop deviceLinkPhase → \(phase)", category: "DeviceLink")
            if case .historySyncReceive(let pendingId) = phase {
                historySyncPendingDeviceId = pendingId
                showReceiveHistorySync = true
            }
        }
        .overlay(alignment: .top) {
            if showReceiveHistorySync {
                // Banner, not a sheet (desktop-interaction-is-not-ios): the window stays usable
                // while the person decides. Wi-Fi opens the receive view; file uses the importer.
                HistoryTransferOfferView(
                    userId: authViewModel.currentUserId ?? "",
                    localDeviceId: KeychainManager.shared.loadDeviceID() ?? "",
                    onFinish: {
                        authViewModel.clearDeviceLinkPhase()
                        historySyncPendingDeviceId = nil
                        showReceiveHistorySync = false
                    }
                )
                .frame(maxHeight: 360)
                .background(Color.CT.bg)
            }
        }
    }

    // Wire keyboard commands → ViewModels

    private func wireCommandBridge() {
        commandBridge.onNewConversation = { chatsViewModel.showNewChat = true }
        commandBridge.onAddContact      = { showAddContact = true }
        commandBridge.onFocusSearch     = { focusSidebarSearch() }
        commandBridge.onFind            = { findInCurrentContext() }
        commandBridge.onOpenPeople      = { openWindow(id: DesktopWindowID.synaps) }
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
        chatsViewModel.sidebarSearchFocused = true
    }

    /// ⌘F — transcript search when a chat is open, otherwise the sidebar filter (D5).
    private func findInCurrentContext() {
        if chatsViewModel.chatToOpen != nil {
            chatsViewModel.chatSearchPresented = true
        } else {
            focusSidebarSearch()
        }
    }

    // MARK: - Main split view (authenticated)

    private var mainContent: some View {
        // NavigationSplitView, not HSplitView: `.toolbar` / `.searchable` on the
        // detail only land in the window toolbar inside a navigation split.
        // Sidebar is always chats (D2). People live in `Window(id: synaps)`.
        let splitView = NavigationSplitView {
            sidebarPane
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color.CT.bg)
        .toolbarBackground(Color.CT.bg, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .tint(Color.CT.accent)

        let decorated = splitView
            .frame(minWidth: 700, minHeight: 480)
            .onReceive(NotificationCenter.default.publisher(for: .openSynapsTab)) { _ in
                openWindow(id: DesktopWindowID.synaps)
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

    /// Detail is the open chat, or the empty state. People are a separate window (D2).
    @ViewBuilder
    private var detailPane: some View {
        if let chatId = chatsViewModel.chatToOpen,
           let conversation = ChatsLive.shared.conversation(chatId) {
            DesktopChatView(conversation: conversation, context: viewContext)
                // Identity, not decoration. `DesktopChatView` seeds its `ChatViewModel` and every
                // editing scrap — draft text, reply target, selection, search — from `@State`, and
                // `@State` takes its initial value once per identity. The detail column keeps the
                // same structural position when `chatToOpen` changes, so with no explicit id
                // SwiftUI reuses the node: the model still points at whichever chat was opened
                // first, and clicking a different row changes nothing on screen. iOS never hit this
                // because it pushes onto a NavigationStack, where every push is a new identity.
                .id(chatId)
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                }
        } else {
            DesktopEmptyStateView(
                hasAddress: hasAccountAddress,
                onAddContact: { showAddContact = true },
                onSetUpRecovery: { showingRecoveryPrompt = true }
            )
                .navigationTitle(NSLocalizedString("construct_title", comment: ""))
                // The same toolbar shape as an open chat (`DesktopChatView`): the system title
                // removed and the name as a navigation item.
                .toolbar(removing: .title)
                .toolbar { emptyStateToolbar }
                .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
        }
    }

    @ToolbarContentBuilder
    private var emptyStateToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { emptyStateTitle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { emptyStateTitle }
        }
    }

    private var emptyStateTitle: some View {
        Text(NSLocalizedString("construct_title", comment: ""))
            .font(CTFont.headline)
            .foregroundStyle(Color.CT.text)
            .lineLimit(1)
    }

    private var sidebarPane: some View {
        DesktopChatsListView()
            .environment(chatsViewModel)
            .background(Color.CT.bg)
            .navigationTitle(NSLocalizedString("chats", comment: ""))
            .safeAreaInset(edge: .bottom, spacing: 0) { synapsesBar }
    }

    /// The door to Synapses, under the chats — where iOS keeps its tab, with the tab's symbol
    /// and name. Synapses stays its own window (D2); until 2026-10-13 the door was an unlabeled
    /// `person.2` in the sidebar's title bar, a symbol iOS uses nowhere for it.
    private var synapsesBar: some View {
        Button {
            openWindow(id: DesktopWindowID.synaps)
        } label: {
            Label(NSLocalizedString("synapses", comment: ""), systemImage: "circle.grid.cross")
                .font(CTFont.body)
                .foregroundStyle(Color.CT.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, CTLayout.navVPad)
        .ctBorderTop()
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

    // MARK: - Drag & Drop into chat

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
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

    // MARK: - Deep links

    private func handleDeepLink(_ deepLink: DeepLinkType?) {
        Log.debug("DesktopRootView: Deep link changed: \(String(describing: deepLink))", category: "DeepLink")
        if case .contact(let contactInfo) = deepLink {
            Log.info("DesktopRootView: Creating chat for userId: \(contactInfo.userId)", category: "DeepLink")
            if let chat = chatsViewModel.startChat(
                redeeming: contactInfo
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
    DesktopEmptyStateView(hasAddress: false, onAddContact: {}, onSetUpRecovery: {})
        .frame(width: 760, height: 500)
}

#Preview("Add Contact sheet") {
    DesktopAddContactView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(DeepLinkHandler())
}
