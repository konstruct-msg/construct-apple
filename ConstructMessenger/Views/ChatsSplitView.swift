//
//  ChatsSplitView.swift
//  Construct Messenger
//
//  Regular-width shell (iPad full-screen / wide multitasking):
//  NavigationSplitView with Streams list in the sidebar and detail that switches
//  between chat, Synaps cloud, and Settings.
//
//  Compact iPhone keeps TabView in MainTabView — this file is only used when
//  horizontalSizeClass == .regular.
//
//  Product: P0 of spatial composition — Synaps must exist on iPad (see
//  construct-docs RADAR_ATTENTION_SURFACE §9.4–§9.5). Radar inspector = later.
//

import SwiftUI
import CoreData

struct ChatsSplitView: View {
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Chat.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \Chat.lastMessageTime, ascending: false)
        ],
        animation: .default
    )
    private var chats: FetchedResults<Chat>

    @State private var selectedChatId: String?
    @State private var showingQRScanner = false
    @State private var activeTab: SidebarTab = .chats
    @State private var showingDrafts = false
    @State private var listRevision = 0

    /// Mirrors compact MainTabView indices for SynapsView refresh guards / orientation.
    private enum SidebarTab: Int {
        case chats = 0
        case synaps = 1
        case settings = 2
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarChats
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if !targetEnvironment(macCatalyst)
                Divider()
                sidebarTabBar
                #endif
            }
            .navigationTitle(sidebarNavigationTitle)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.CT.accent)
                    }
                    .accessibilityLabel(Text(LocalizedStringKey("scan_qr_code")))
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.CT.accent)
                    }
                    .accessibilityLabel(Text(LocalizedStringKey("scan_qr_code")))
                }
                #endif
                ToolbarItem(placement: .principal) {
                    ConnectionStatusIndicator()
                }
                #if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        cycleSidebarTab()
                    } label: {
                        Image(systemName: catalystToggleSystemImage)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color.CT.accent)
                    }
                    .accessibilityLabel(Text(LocalizedStringKey(catalystToggleA11yKey)))
                }
                #endif
            }
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { contactURL in
                    handleScannedContact(contactURL)
                }
            }
            .sheet(isPresented: $showingDrafts) {
                DraftsView()
            }
        } detail: {
            detailContent
        }
        .onAppear {
            chatsViewModel.setContext(viewContext)
            applySelectedTabFromViewModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { note in
            guard notificationContainsChatChanges(note) else { return }
            listRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)) { note in
            guard notificationContainsChatChanges(note) else { return }
            listRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSynapsTab)) { _ in
            openSynaps()
        }
        .onChange(of: chatsViewModel.selectedTab) { _, tab in
            // Compact → regular rotation, or MainTabView still writing selectedTab.
            if tab == SidebarTab.synaps.rawValue {
                openSynaps()
            } else if tab == 0 {
                selectTab(.chats, clearChatSelection: false)
            } else if tab == settingsTabIndex {
                selectTab(.settings, clearChatSelection: true)
            }
        }
        .onChange(of: chatsViewModel.chatToOpen) { _, chatId in
            if let chatId {
                selectedChatId = chatId
                selectTab(.chats, clearChatSelection: false)
                chatsViewModel.chatToOpen = nil
            }
        }
        .onChange(of: selectedChatId) { _, newId in
            // Picking a stream from the sidebar always returns to chats detail.
            if newId != nil {
                selectTab(.chats, clearChatSelection: false)
            }
        }
    }

    // MARK: - Sidebar chrome

    private var sidebarNavigationTitle: LocalizedStringKey {
        switch activeTab {
        case .chats: return "chats"
        case .synaps: return "synapses"
        case .settings: return "settings"
        }
    }

    private var sidebarTabBar: some View {
        HStack(spacing: 0) {
            sidebarTabButton(
                title: "chats",
                systemImage: "message",
                tab: .chats
            )
            sidebarTabButton(
                title: "synapses",
                systemImage: "circle.grid.cross",
                tab: .synaps
            )
            sidebarTabButton(
                title: "settings",
                systemImage: "gearshape",
                tab: .settings
            )
        }
        .frame(height: 56)
        .background(.bar)
    }

    @ViewBuilder
    private func sidebarTabButton(title: LocalizedStringKey, systemImage: String, tab: SidebarTab) -> some View {
        let selected = activeTab == tab
        Button {
            selectTab(tab, clearChatSelection: tab != .chats)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: selected ? 18 : 16, weight: selected ? .semibold : .regular))
                Text(title)
                    .font(CTFont.regular(10))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.CT.accent : Color.CT.textDim)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    #if targetEnvironment(macCatalyst)
    private var catalystToggleSystemImage: String {
        switch activeTab {
        case .chats: return "circle.grid.cross"
        case .synaps: return "gearshape"
        case .settings: return "message"
        }
    }

    private var catalystToggleA11yKey: String {
        switch activeTab {
        case .chats: return "synapses"
        case .synaps: return "settings"
        case .settings: return "chats"
        }
    }

    private func cycleSidebarTab() {
        switch activeTab {
        case .chats: selectTab(.synaps, clearChatSelection: true)
        case .synaps: selectTab(.settings, clearChatSelection: true)
        case .settings: selectTab(.chats, clearChatSelection: false)
        }
    }
    #endif

    // MARK: - Sidebar: Chats

    private var sidebarChats: some View {
        List(selection: $selectedChatId) {
            ForEach(chats) { chat in
                ChatRowView(chat: chat)
                    .tag(chat.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteChat(chat) } label: {
                            Label(LocalizedStringKey("delete"), systemImage: "trash")
                        }
                        Button { toggleMarkUnread(chat) } label: {
                            Label(LocalizedStringKey(chat.unreadCount > 0 ? "mark_read" : "mark_unread"),
                                  systemImage: chat.unreadCount > 0 ? "envelope.open" : "envelope.badge")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { togglePin(chat) } label: {
                            Label(LocalizedStringKey(chat.isPinned ? "unpin" : "pin"),
                                  systemImage: chat.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.yellow)
                    }
                    .contextMenu {
                        Button(role: .destructive) { deleteChat(chat) } label: {
                            Label("delete_chat", systemImage: "trash")
                        }
                    }
            }
            .onDelete(perform: deleteChatsAtOffsets)
        }
        .id(listRevision)
        .refreshable {
            #if os(iOS)
            await BackgroundFetchManager.shared.fetchPendingMessages()
            #endif
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        switch activeTab {
        case .synaps:
            SynapsView()
                .environment(chatsViewModel)
        case .settings:
            #if os(iOS)
            SettingsView()
                .environment(chatsViewModel)
            #else
            DesktopSettingsView()
            #endif
        case .chats:
            if let chatId = selectedChatId,
               let chat = chats.first(where: { $0.id == chatId }) {
                ChatView(chat: chat, context: viewContext)
            } else {
                ContentUnavailableView(
                    String(localized: "select_chat"),
                    systemImage: "message",
                    description: Text("select_chat_description")
                )
            }
        }
    }

    // MARK: - Tab selection

    /// Compact MainTabView settings index when calls tab is present.
    private var settingsTabIndex: Int { CallsFeature.isEnabled ? 3 : 2 }

    private func openSynaps() {
        selectTab(.synaps, clearChatSelection: true)
    }

    private func selectTab(_ tab: SidebarTab, clearChatSelection: Bool) {
        activeTab = tab
        if clearChatSelection {
            selectedChatId = nil
        }
        // Keep ChatsViewModel.selectedTab in sync so SynapsView request refresh
        // (guards on selectedTab == 1) and orientation paths stay consistent.
        switch tab {
        case .chats:
            chatsViewModel.selectedTab = 0
        case .synaps:
            chatsViewModel.selectedTab = 1
        case .settings:
            chatsViewModel.selectedTab = settingsTabIndex
        }
    }

    private func applySelectedTabFromViewModel() {
        switch chatsViewModel.selectedTab {
        case 1:
            openSynaps()
        case let t where t == settingsTabIndex:
            selectTab(.settings, clearChatSelection: true)
        default:
            break
        }
    }

    // MARK: - Actions

    private func deleteChat(_ chat: Chat) {
        if selectedChatId == chat.id {
            selectedChatId = nil
        }
        Task { await chatsViewModel.deleteChatWithEndSession(chat: chat) }
    }

    private func deleteChatsAtOffsets(at offsets: IndexSet) {
        offsets.map { chats[$0] }.forEach { deleteChat($0) }
    }

    private func togglePin(_ chat: Chat) {
        chat.isPinned.toggle()
        try? viewContext.save()
    }

    private func toggleMarkUnread(_ chat: Chat) {
        chat.unreadCount = chat.unreadCount > 0 ? 0 : 1
        try? viewContext.save()
    }

    private func notificationContainsChatChanges(_ note: Notification) -> Bool {
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        for key in keys {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            if objects.contains(where: { entity in
                let name = entity.entity.name
                return name == "Chat" || name == "Message"
            }) {
                return true
            }
        }
        return false
    }

    private func handleScannedContact(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            showErrorAfterDismiss(NSLocalizedString("invalid_qr_code_construct", comment: ""))
            return
        }
        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                await MainActor.run {
                    addContact(contactInfo: contactInfo)
                    showingQRScanner = false
                }
            } catch {
                await MainActor.run {
                    showErrorAfterDismiss(error.localizedDescription)
                    showingQRScanner = false
                }
            }
        }
    }

    private func addContact(contactInfo: ContactInfo) {
        if contactInfo.userId == AuthSessionManager.shared.currentUserId {
            showingDrafts = true
            return
        }
        let publicUserInfo = PublicUserInfo(
            id: contactInfo.userId,
            username: contactInfo.username,
            avatarUrl: nil,
            bio: nil,
            deviceId: contactInfo.deviceId
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            selectedChatId = chat.id
            selectTab(.chats, clearChatSelection: false)
        }
    }

    private func showErrorAfterDismiss(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ErrorRouter.shared.report(.unknown(message))
        }
    }
}
