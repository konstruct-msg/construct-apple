//
//  ChatsSplitView.swift
//  Construct Messenger
//
//  Regular-width shell (iPad full-screen / wide multitasking).
//
//  Layout (iPadOS 26-inspired, CT glass language):
//  ┌──────┬────────────────┬─────────────────────────┐
//  │ Rail │ Streams list   │ Detail (chat / empty)   │  ← chats
//  │ vert │ (floating card)│                         │
//  │ glass│                │                         │
//  └──────┴────────────────┴─────────────────────────┘
//  ┌──────┬──────────────────────────────────────────┐
//  │ Rail │ Synaps / Settings (full stage)           │
//  └──────┴──────────────────────────────────────────┘
//
//  Compact iPhone keeps TabView in MainTabView.
//  Product: spatial composition P0/P1 — see RADAR_ATTENTION_SURFACE §9.4–§9.5.
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

    /// Order-preserving dedupe of the fetched chats by `id`. `@FetchRequest(animation:)` can
    /// transiently surface the same Chat twice during a background-context merge; a `ForEach`
    /// over a duplicate Identifiable id crashes the List with UICollectionView's diff assertion.
    private var dedupedChats: [Chat] {
        var seen = Set<String>()
        return chats.filter { seen.insert($0.id).inserted }
    }

    @State private var selectedChatId: String?
    @State private var showingQRScanner = false
    @State private var activeTab: SidebarTab = .chats
    @State private var showingDrafts = false
    @State private var listRevision = 0
    /// Collapses the streams list so the open chat spans the full stage.
    @State private var listCollapsed = false

    /// Mirrors compact MainTabView indices for SynapsView refresh guards / orientation.
    private enum SidebarTab: Int, CaseIterable {
        case chats = 0
        case synaps = 1
        case settings = 2

        var titleKey: LocalizedStringKey {
            switch self {
            case .chats: return "chats"
            case .synaps: return "synapses"
            case .settings: return "settings"
            }
        }

        var systemImage: String {
            switch self {
            case .chats: return "message"
            case .synaps: return "circle.grid.cross"
            case .settings: return "gearshape"
            }
        }
    }

    /// Narrow vertical section switcher (icon rail).
    private let railWidth: CGFloat = 56
    /// Preferred streams column width on regular (list floats beside detail).
    private let streamsColumnWidth: CGFloat = 320

    var body: some View {
        HStack(alignment: .top, spacing: CTLayout.chromeGap) {
            sectionRail
                .padding(.leading, CTLayout.edgePad)
                .padding(.vertical, CTLayout.edgePad)

            mainStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, CTLayout.edgePad)
                .padding(.vertical, CTLayout.edgePad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ctBackground()
        .sheet(isPresented: $showingQRScanner) {
            QRScannerView { contactURL in
                handleScannedContact(contactURL)
            }
        }
        .sheet(isPresented: $showingDrafts) {
            DraftsView()
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
            if newId != nil {
                selectTab(.chats, clearChatSelection: false)
            }
        }
    }

    // MARK: - Vertical section rail (left)

    /// iPadOS 26 pattern: primary sections as a floating vertical control, not a fused
    /// bottom bar. QR sits apart at the bottom of the rail (action vs destination).
    ///
    /// Streams list toggle is a **permanent rail slot** (not tab-conditional). Hiding it
    /// only on `.chats` made the control pop in/out when switching Synaps/Settings —
    /// bad discoverability and a flickering chrome layout.
    private var sectionRail: some View {
        VStack(spacing: CTLayout.chromeGap) {
            ForEach(SidebarTab.allCases, id: \.rawValue) { tab in
                railDestinationButton(tab)
            }

            railChromeDivider

            // Fixed slot — same position whether the list is open, collapsed, or another
            // section is selected. Never animates its own presence.
            railListToggleButton

            Spacer(minLength: CTLayout.sectionGap)

            railQRButton
            connectionRailBadge
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(width: railWidth)
        .frame(maxHeight: .infinity)
        .modifier(RegularShellFloatingChrome(cornerRadius: CTRadius.pill))
        .accessibilityElement(children: .contain)
    }

    private var railChromeDivider: some View {
        Rectangle()
            .fill(Color.CT.noise.opacity(0.55))
            .frame(width: 22, height: 1)
            .frame(width: CTLayout.hitTarget)
    }

    private func railDestinationButton(_ tab: SidebarTab) -> some View {
        let selected = activeTab == tab
        return Button {
            selectTab(tab, clearChatSelection: tab != .chats)
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 18, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.CT.bg : Color.CT.textDim)
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .background {
                    if selected {
                        Circle()
                            .fill(Color.CT.accent)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.titleKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Collapse / expand the streams list — permanent rail chrome.
    /// - On chats: toggles `listCollapsed`.
    /// - On Synaps/Settings: jumps back to chats and ensures the list is visible
    ///   (the control is not a no-op ghost on other sections).
    private var railListToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                if activeTab != .chats {
                    selectTab(.chats, clearChatSelection: false)
                    listCollapsed = false
                } else {
                    listCollapsed.toggle()
                }
            }
        } label: {
            Image(systemName: listToggleSystemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(listToggleForeground)
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(listToggleAccessibilityKey)))
    }

    /// Distinct glyphs: split columns vs single pane — `sidebar.left` / `sidebar.leading`
    /// looked nearly identical and read as a broken control.
    private var listToggleSystemImage: String {
        if activeTab != .chats {
            return "rectangle.split.1x2"
        }
        return listCollapsed ? "rectangle.split.1x2" : "rectangle.lefthalf.inset.filled"
    }

    private var listToggleForeground: Color {
        if activeTab != .chats {
            return Color.CT.textDim
        }
        return listCollapsed ? Color.CT.textDim : Color.CT.accent
    }

    private var listToggleAccessibilityKey: String {
        if activeTab != .chats {
            return "show_chat_list"
        }
        return listCollapsed ? "show_chat_list" : "hide_chat_list"
    }

    private var railQRButton: some View {
        Button {
            showingQRScanner = true
        } label: {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.CT.accent)
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey("scan_qr_code")))
    }

    private var connectionRailBadge: some View {
        ConnectionStatusIndicator()
            .scaleEffect(0.85)
            .frame(width: CTLayout.hitTarget)
    }

    // MARK: - Main stage

    @ViewBuilder
    private var mainStage: some View {
        switch activeTab {
        case .chats:
            chatsStage
        case .synaps:
            floatingStage {
                // Rail already exposes a global QR scan — don't duplicate it in the nav bar.
                SynapsView(showsScanAction: false)
                    .environment(chatsViewModel)
            }
        case .settings:
            floatingStage {
                #if os(iOS)
                SettingsView()
                    .environment(chatsViewModel)
                #else
                DesktopSettingsView()
                #endif
            }
        }
    }

    /// Streams: floating list column + detail (not one fused split chrome slab).
    /// The list collapses (via the rail toggle) so an open chat can span the stage.
    private var chatsStage: some View {
        HStack(alignment: .top, spacing: CTLayout.chromeGap) {
            if !listCollapsed {
                streamsListPanel
                    .frame(width: streamsColumnWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            chatDetailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: listCollapsed)
    }

    private var streamsListPanel: some View {
        VStack(spacing: 0) {
            // Secondary hide affordance co-located with the list surface (Mail/Notes).
            // Expand always lives on the permanent rail slot — list chrome can't own that.
            panelHeader(titleKey: "chats") {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { listCollapsed = true }
                } label: {
                    Image(systemName: "rectangle.lefthalf.inset.filled")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey("hide_chat_list")))
            }

            List(selection: $selectedChatId) {
                ForEach(dedupedChats) { chat in
                    ChatRowView(chat: chat)
                        .tag(chat.id)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deleteChat(chat) } label: {
                                Label(LocalizedStringKey("delete"), systemImage: "trash")
                            }
                            Button { toggleMarkUnread(chat) } label: {
                                Label(
                                    LocalizedStringKey(chat.unreadCount > 0 ? "mark_read" : "mark_unread"),
                                    systemImage: chat.unreadCount > 0 ? "envelope.open" : "envelope.badge"
                                )
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { togglePin(chat) } label: {
                                Label(
                                    LocalizedStringKey(chat.isPinned ? "unpin" : "pin"),
                                    systemImage: chat.isPinned ? "pin.slash" : "pin"
                                )
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .id(listRevision)
            .refreshable {
                #if os(iOS)
                await BackgroundFetchManager.shared.fetchPendingMessages()
                #endif
            }
        }
        .modifier(RegularShellFloatingChrome(cornerRadius: CTRadius.card))
    }

    @ViewBuilder
    private var chatDetailPanel: some View {
        if let chatId = selectedChatId,
           let chat = chats.first(where: { $0.id == chatId }) {
            // ChatView already owns floating glass nav/composer — do not double-chrome.
            ChatView(chat: chat, context: viewContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: CTRadius.card, style: .continuous))
        } else {
            ContentUnavailableView(
                String(localized: "select_chat"),
                systemImage: "message",
                description: Text("select_chat_description")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(RegularShellFloatingChrome(cornerRadius: CTRadius.card))
        }
    }

    /// Full-stage surface for Synaps / Settings — one floating panel, not edge-fused.
    private func floatingStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(RegularShellFloatingChrome(cornerRadius: CTRadius.card))
            .clipShape(RoundedRectangle(cornerRadius: CTRadius.card, style: .continuous))
    }

    private func panelHeader<Trailing: View>(
        titleKey: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: CTLayout.chromeGap) {
            Text(titleKey)
                .font(CTFont.bold(13))
                .foregroundStyle(Color.CT.text)
                .tracking(3)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.CT.noise.opacity(0.55))
                .frame(height: 1)
        }
    }

    // MARK: - Tab selection

    private var settingsTabIndex: Int { CallsFeature.isEnabled ? 3 : 2 }

    private func openSynaps() {
        selectTab(.synaps, clearChatSelection: true)
    }

    private func selectTab(_ tab: SidebarTab, clearChatSelection: Bool) {
        activeTab = tab
        if clearChatSelection {
            selectedChatId = nil
        }
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
        if let chat = chatsViewModel.startChat(
            with: publicUserInfo,
            identityPublicKey: contactInfo.identityPublicKey
        ) {
            selectedChatId = chat.id
            selectTab(.chats, clearChatSelection: false)
            InviteRedeemUX.presentPostRedeemSafety(for: contactInfo)
        }
    }

    private func showErrorAfterDismiss(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ErrorRouter.shared.report(.unknown(message))
        }
    }
}

// MARK: - Floating chrome (solid CT surface)

/// Separates shell panels as floating cards using the CT surface language:
/// solid `#090909` fill + continuous corners + a hairline `noise` edge.
///
/// Deliberately NOT translucent glass — `.glassEffect(.regular)` over the black
/// background renders as a light grey material, which clashes with the app's
/// all-black aesthetic. Panels stay black like everywhere else; the hairline
/// border is what delineates each floating card.
private struct RegularShellFloatingChrome: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.CT.bg)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.CT.noise, lineWidth: 0.5)
            )
    }
}
