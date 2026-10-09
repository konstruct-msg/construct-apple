//
//  SynapsView.swift
//  Construct Messenger
//
//  Synaps — persistent contact network, independent of chats.
//  Layout: Zoomable/pannable honeycomb cloud of round avatars + name labels.
//  Gestures: pinch-to-zoom + drag-to-pan. Contacts near the screen
//  center appear larger; peripheral contacts are dimmer — Apple Watch style.
//

import SwiftUI
import CoreData
import GRPCCore
#if os(iOS)
import UIKit
#endif

// MARK: - SynapsView

struct SynapsView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(ChatsViewModel.self) private var chatsViewModel

    /// People marked as contacts, in the order shown (`ContactsLive.contacts`).
    private var contacts: [ContactRecord] { ContactsLive.shared.contacts() }

    @State private var searchText      = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedContact: ContactRecord? = nil
    @State private var pruneTarget:     ContactRecord? = nil
    @State private var showPruneConfirm = false
    // Shared canvas transform — owned here so SynapsCloud can read them for
    // the lens while ZoomableCloud drives them via gestures.
    @State private var canvasScale:  CGFloat  = 1.0   // recalculated on appear
    @State private var canvasOffset: CGSize   = .zero
    /// How far inside the visible area the lens ends: about the radius of a circle at the rim.
    private static let lensInset: CGFloat = 14
    /// Height of what overlays the cloud's top edge (remote result, pending requests).
    @State private var topOverlayHeight: CGFloat = 0

    // MARK: - Remote search state
    enum RemoteSearchState {
        case idle
        case searching
        case found(Shared_Proto_Services_V1_UserProfile)
        case notFound
    }
    @State private var remoteState: RemoteSearchState = .idle
    @State private var searchTask: Task<Void, Never>? = nil
    /// Optimistic / session UI for “request sent” — UserDefaults alone does not invalidate the view.
    @State private var pendingSentUserIds: Set<String> = []
    @State private var sendingRequestToUserId: String? = nil

    // MARK: - QR Scanner
    @State private var showingQRScanner = false

    // MARK: - Contact requests
    @State private var contactRequestsVM: ContactRequestsViewModel? = nil
    @State private var selectedRequest: ContactRequestsViewModel.IncomingRequest? = nil
    @State private var contactMetricsByUser: [String: ContactMetrics] = [:]
    @State private var isRefreshingContactRequests = false
    @State private var lastContactRequestsRefresh: Date = .distantPast

    /// Minimum gap between contact-request refreshes. Guards against RPC chatter
    /// from rapid tab re-entries (native TabView re-runs `.task` on every appear).
    private static let contactRequestsRefreshInterval: TimeInterval = 8

    private var filtered: [ContactRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts }
        return contacts.filter { userMatchesQuery($0, query: query) }
    }

    var body: some View {
        let filteredContacts = filtered
        NavigationStack {
            // The cloud runs under the bars, as every other screen's content does; until
            // 2026-10-08 it was cut to the safe area and ended at the search field's lower edge.
            // What sits over its top edge — a remote result, pending requests — is measured so
            // the cloud centres and fits in the part that is actually visible.
            ZStack(alignment: .top) {
                CTMatrixBackground().ignoresSafeArea()

                if contacts.isEmpty {
                    // While searching, the remote card above is the primary UI; keep the
                    // “no synapses yet” empty state for idle only.
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyState
                    }
                } else {
                    GeometryReader { geo in
                        cloud(contacts: filteredContacts, in: geo)
                    }
                }

                VStack(spacing: 0) {
                    if !searchText.isEmpty, filteredContacts.isEmpty {
                        remoteSearchCard
                    }
                    if let vm = contactRequestsVM, !vm.incomingRequests.isEmpty, searchText.isEmpty {
                        requestsSection(vm: vm)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topOverlayHeight = $0 }
            }
            .ctBackground()
            .navigationTitle(NSLocalizedString("synapses", comment: ""))
            .inlineNavTitle()
            .connectionSubtitle()
            .searchable(text: $searchText, prompt: Text(LocalizedStringKey("search_prompt")))
            .searchFocused($isSearchFocused)
            .onSubmit(of: .search) { dismissSearchKeyboard() }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingQRScanner = true } label: {
                        Label(NSLocalizedString("scan_qr_code", comment: ""), systemImage: "qrcode.viewfinder")
                    }
                    .barItem()
                }
            }
            #endif
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        dismissSearchKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .foregroundStyle(Color.CT.accent)
                    }
                    .accessibilityLabel(Text(LocalizedStringKey("done")))
                }
            }
            #endif
            .onAppear {
                rebuildContactMetrics()
            }
            .onChange(of: searchText) { _, newValue in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    canvasOffset = .zero
                }
                searchTask?.cancel()
                remoteState = .idle
                if newValue.isEmpty {
                    dismissSearchKeyboard()
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s debounce
                    guard !Task.isCancelled else { return }
                    let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { return }
                    let hasLocalMatches = contacts.contains { userMatchesQuery($0, query: query) }
                    await performRemoteSearch(username: query, localMatchesExist: hasLocalMatches)
                }
            }
            .onChange(of: contacts.count) { _, _ in
                rebuildContactMetrics()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { note in
                guard notificationContainsSynapsesMetricChanges(note) else { return }
                rebuildContactMetrics()
            }
            .task {
                // Native TabView fires `.task` on every appear (i.e. each time this
                // tab is selected) and cancels it on disappear — so this is also the
                // "tab re-entered" refresh. No separate onChange(selectedTab) trigger
                // is needed; refreshContactRequests throttles rapid re-entries.
                let vm = contactRequestsVM ?? ContactRequestsViewModel(viewContext: context)
                contactRequestsVM = vm
                await refreshContactRequests(vm: vm, reason: "tab_appear")
            }
            .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
                guard chatsViewModel.selectedTab == 1, let vm = contactRequestsVM else { return }
                Task { await refreshContactRequests(vm: vm, reason: "app_active") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .contactRequestAccepted)) { _ in
                // The service already ran (from AppDelegate) and stored pending user IDs.
                // Consume them and navigate to the first newly-accepted contact.
                Task {
                    let pendingIds = ContactRequestService.shared.consumePendingNavigationUserIds()
                    guard let userId = pendingIds.first, !userId.isEmpty else { return }
                    await MainActor.run { chatsViewModel.openOrCreateChat(withContact: userId) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .contactRequestReceived)) { _ in
                // Silent push (or local banner tap path) — refresh the requests inbox
                // while Synaps is already visible so the new row appears without a re-tab.
                guard let vm = contactRequestsVM else { return }
                Task { await refreshContactRequests(vm: vm, reason: "push_received") }
            }
            .sheet(isPresented: $showingQRScanner) {
                RecoveryGated { QRScannerView { contactURL in handleScannedQR(contactURL) } }
            }
            .sheet(item: $selectedContact) { user in
                UserProfileView(
                    userId: user.id,
                    showMessageButton: true,
                    onOpenChat: { chatsViewModel.openOrCreateChat(withContact: user.id) },
                    onPrune: {
                        pruneTarget = user
                        showPruneConfirm = true
                    }
                )
                .sheetNavigation()
                .environment(\.managedObjectContext, context)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedRequest) { request in
                if let vm = contactRequestsVM {
                    ContactRequestSheet(
                        request: request,
                        onAccept: {
                            let user = try await vm.accept(request: request, context: context)
                            chatsViewModel.openOrCreateChat(withContact: user.id)
                        },
                        onDeclineBlock: { try await vm.declineAndBlock(requestId: request.id) },
                        onSpamBlock: { try await vm.reportSpamAndBlock(requestId: request.id) }
                    )
                    .sheetNavigation(closes: false)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .confirmationDialog(
            LocalizedStringKey("synapses_prune_title"),
            isPresented: $showPruneConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("synapses_prune_action"), role: .destructive) {
                if let user = pruneTarget {
                    Task { await chatsViewModel.pruneContact(userId: user.id) }
                }
                pruneTarget = nil
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) { pruneTarget = nil }
        } message: {
            if let name = pruneTarget?.displayName {
                Text(String(format: NSLocalizedString("synapses_prune_message", comment: ""), name))
            }
        }
    }

    // MARK: - Cloud

    /// The cloud on a canvas the size of the whole screen. `geo` is the safe area; the canvas
    /// extends past it by its insets, and the visible part — between the search field (and
    /// whatever overlays the top) and the tab bar — is where the cloud centres and fits.
    private func cloud(contacts: [ContactRecord], in geo: GeometryProxy) -> some View {
        let insets = geo.safeAreaInsets
        let canvas = CGSize(
            width: geo.size.width + insets.leading + insets.trailing,
            height: geo.size.height + insets.top + insets.bottom
        )
        let visible = CGRect(
            x: insets.leading,
            y: insets.top + topOverlayHeight,
            width: geo.size.width,
            height: Swift.max(0, geo.size.height - topOverlayHeight)
        )
        let focus = CGPoint(x: visible.midX, y: visible.midY)
        let layout = SynapsCloudLayout(contacts: contacts, metrics: contactMetricsByUser)
        return ZoomableCloud(
            scale:    $canvasScale,
            offset:   $canvasOffset,
            anchor:   UnitPoint(x: focus.x / canvas.width, y: focus.y / canvas.height),
            minScale: 0.20,
            maxScale: 3.0
        ) {
            SynapsCloud(
                layout:       layout,
                metricsByUser: contactMetricsByUser,
                selected:     $selectedContact,
                canvasScale:  canvasScale,
                canvasOffset: canvasOffset,
                focus:        focus,
                // The oval stops a rim circle's radius short of the visible edges.
                lens:         SynapsLens(radii: CGSize(
                    width: Swift.max(0, visible.width / 2 - Self.lensInset),
                    height: Swift.max(0, visible.height / 2 - Self.lensInset)
                ))
            )
        }
        .frame(width: canvas.width, height: canvas.height)
        .contentShape(Rectangle())
        .onTapGesture {
            // No ScrollView here — tap empty canvas to drop keyboard.
            dismissSearchKeyboard()
        }
        .offset(x: -insets.leading, y: -insets.top)
        .onAppear {
            // The lens keeps every contact inside the visible area at 1:1, so the cloud opens
            // there rather than fitted (which, under the lens, shrank everyone twice).
            canvasScale = 1
        }
    }

    private func rebuildContactMetrics() {
        contactMetricsByUser = ContactMetrics.byContact(contacts.map(\.id), in: context)
    }

    private func notificationContainsSynapsesMetricChanges(_ note: Notification) -> Bool {
        let relevantEntities: Set<String> = ["User", "Chat", "Message"]
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        for key in keys {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            if objects.contains(where: { object in
                guard let name = object.entity.name else { return false }
                return relevantEntities.contains(name)
            }) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func refreshContactRequests(
        vm: ContactRequestsViewModel,
        reason: String
    ) async {
        guard !isRefreshingContactRequests else {
            Log.debug("Skipping contact request refresh (\(reason)) — already in progress", category: "SynapsView")
            return
        }
        let sinceLast = Date().timeIntervalSince(lastContactRequestsRefresh)
        guard sinceLast >= Self.contactRequestsRefreshInterval else {
            Log.debug("Skipping contact request refresh (\(reason)) — throttled (\(Int(sinceLast))s ago)", category: "SynapsView")
            return
        }
        isRefreshingContactRequests = true
        lastContactRequestsRefresh = Date()
        defer { isRefreshingContactRequests = false }

        Log.info("Refreshing contact requests (\(reason))", category: "SynapsView")
        await vm.load()

        let pendingId = ContactRequestService.shared.consumePendingNavigationUserIds().first { !$0.isEmpty }

        let accepted = await vm.checkAcceptedRequests(context: context)
        if let first = accepted.first {
            chatsViewModel.openOrCreateChat(withContact: first.id)
        } else if let pendingId {
            chatsViewModel.openOrCreateChat(withContact: pendingId)
        }
    }

    private func dismissSearchKeyboard() {
        isSearchFocused = false
        #if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        #endif
    }

    private func isRequestAlreadySent(toUserId: String) -> Bool {
        if pendingSentUserIds.contains(toUserId) { return true }
        return contactRequestsVM?.hasPendingSentRequest(toUserId: toUserId) ?? false
    }

    // MARK: - Empty state

    // The QR scan (nav bar / iPad rail) and the search bar above are the real entry points; the
    // description already names both. No duplicate action buttons here.
    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(LocalizedStringKey("synapses_empty_title"))
                    .font(CTFont.headline)
            } icon: {
                Image(systemName: "circle.grid.cross")
            }
        } description: {
            Text(LocalizedStringKey("synapses_empty_subtitle"))
                .font(CTFont.body)
        }
    }

    // MARK: - Remote Search Card

    @ViewBuilder
    private var remoteSearchCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LocalizedStringKey("synapses_remote_result_header"))
                    .font(CTFont.ui(10, weight: .bold))
                    .foregroundStyle(Color.CT.accent)
                    .tracking(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            switch remoteState {
            case .idle:
                EmptyView()

            case .searching:
                HStack {
                    Text(LocalizedStringKey("synapses_searching"))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.textDim)
                    Spacer()
                    ProgressView().tint(Color.CT.accent).scaleEffect(0.7)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

            case .found(let profile):
                let alreadySent = isRequestAlreadySent(toUserId: profile.userID)
                let isSending = sendingRequestToUserId == profile.userID
                let fallbackQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                        .foregroundStyle(Color.CT.accent)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        if profile.hasDisplayName {
                            Text(profile.displayName)
                                .font(CTFont.headline)
                                .foregroundStyle(Color.CT.text)
                        }
                        if profile.hasUsername {
                            Text("@\(profile.username)")
                                .font(CTFont.secondary)
                                .foregroundStyle(Color.CT.textDim)
                        } else if !fallbackQuery.isEmpty {
                            Text("@\(fallbackQuery)")
                                .font(CTFont.secondary)
                                .foregroundStyle(Color.CT.text)
                        } else {
                            Text(DisplayNameGenerator.generate(from: profile.userID))
                                .font(CTFont.body)
                                .foregroundStyle(Color.CT.text)
                        }
                    }

                    Spacer(minLength: 8)

                    if alreadySent {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(CTIcon.font(CTIcon.row, weight: .semibold))
                            Text(NSLocalizedString("contact_request_sent", comment: ""))
                                .font(CTFont.secondary)
                        }
                        .foregroundStyle(Color.CT.textDim)
                    } else if isSending {
                        ProgressView()
                            .tint(Color.CT.accent)
                            .scaleEffect(0.85)
                    } else {
                        Button {
                            dismissSearchKeyboard()
                            Task { await sendContactRequest(to: profile) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "person.badge.plus")
                                    .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                                Text(NSLocalizedString("contact_request_send_action", comment: ""))
                                    .font(CTFont.ui(12, weight: .medium))
                            }
                            .foregroundStyle(Color.CT.bg)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.CT.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

            case .notFound:
                HStack {
                    Text(LocalizedStringKey("synapses_not_found"))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.textDim)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }

            Rectangle().fill(Color.CT.noise).frame(height: 1)
        }
        .background(Color.CT.bg)
    }

    // MARK: - Remote Search Logic

    private func performRemoteSearch(username: String, localMatchesExist: Bool) async {
        guard !localMatchesExist else { return }
        remoteState = .searching

        do {
            guard let userId = try await UserServiceClient.shared.findUser(username: username) else {
                remoteState = .notFound
                return
            }
            let profile = try await UserServiceClient.shared.getUserProfile(userId: userId)
            remoteState = .found(profile)
        } catch {
            remoteState = .notFound
        }
    }

    private func userMatchesQuery(_ user: ContactRecord, query: String) -> Bool {
        user.displayName.localizedCaseInsensitiveContains(query)
            || user.username.localizedCaseInsensitiveContains(query)
    }

    /// Sends a contact request to a discoverable user found via remote search.
    @MainActor
    private func sendContactRequest(to profile: Shared_Proto_Services_V1_UserProfile) async {
        guard let vm = contactRequestsVM else { return }
        guard !isRequestAlreadySent(toUserId: profile.userID) else { return }
        sendingRequestToUserId = profile.userID
        defer { sendingRequestToUserId = nil }
        do {
            let requestId = try await vm.sendRequest(toUserId: profile.userID)
            vm.markSentRequest(toUserId: profile.userID, requestId: requestId)
            // Drive visible “request sent” state (UserDefaults alone is not @Observable).
            pendingSentUserIds.insert(profile.userID)
            remoteState = .found(profile)
        } catch {
            // Surface the failure instead of swallowing it — a silent catch here hid the
            // real reason "Send request" did nothing (RPC rejected / no delivery). Log the
            // exact error and tell the user so it's retryable and diagnosable.
            // Transport blips surface as gRPC "Stream unexpectedly closed." — map to a
            // human-readable connection message (RPC already retried in UserServiceClient).
            Log.error("sendContactRequest failed for \(profile.userID.prefix(8))…: \(error)", category: "ContactRequest")
            // A connection failure gets the request's own sentence; anything else, the general one.
            // Classified by type, not by sniffing the error's words for "stream" or "timeout".
            let appError = AppError.from(error)
            if case .network = appError {
                ErrorRouter.shared.report(.said(UserText("contact_request_send_failed")))
            } else {
                ErrorRouter.shared.report(appError)
            }
        }
    }

    // MARK: - Requests Section

    @ViewBuilder
    private func requestsSection(vm: ContactRequestsViewModel) -> some View {
        VStack(spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("contact_requests_section", comment: ""))

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            ForEach(vm.incomingRequests) { request in
                Button {
                    selectedRequest = request
                } label: {
                    HStack(spacing: 12) {
                        MainAvatarView(userId: request.fromUserId, size: CTAvatarSize.row)
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = request.displayName, !name.isEmpty {
                                Text(name)
                                    .font(CTFont.body)
                                    .foregroundStyle(Color.CT.text)
                            } else if let username = request.username, !username.isEmpty {
                                Text("@\(username)")
                                    .font(CTFont.body)
                                    .foregroundStyle(Color.CT.text)
                            } else {
                                Text(DisplayNameGenerator.generate(from: request.fromUserId))
                                    .font(CTFont.body)
                                    .foregroundStyle(Color.CT.textDim)
                            }
                            Text(NSLocalizedString("contact_request_from_title", comment: ""))
                                .font(CTFont.caption)
                                .foregroundStyle(Color.CT.textDim)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                            .foregroundStyle(Color.CT.textDim)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)

                Rectangle().fill(Color.CT.noise).frame(height: 1).padding(.horizontal, 14)
            }
        }
        .background(Color.CT.bg)
    }

    /// Upserts the remote user in Core Data (marking as contact) and opens a chat.
    @MainActor
    private func addRemoteUserAndChat(profile: Shared_Proto_Services_V1_UserProfile) async {
        do {
            let user = try ContactLinkService.shared.createOrUpdateContact(
                userId: profile.userID,
                username: profile.hasUsername ? profile.username : nil,
                displayName: profile.hasDisplayName ? profile.displayName : nil,
                context: context
            )
            searchText = ""
            remoteState = .idle
            chatsViewModel.openOrCreateChat(withContact: user.id)
        } catch {
            Log.error("addRemoteUserAndChat failed: \(error)", category: "SynapsView")
        }
    }

    // MARK: - QR Handler

    private func handleScannedQR(_ urlString: String) {
        // A voucher scanned here is a voucher, not a malformed contact code.
        if let outcome = VeilVoucherRedemption.messageIfVoucher(urlString) {
            showingQRScanner = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                ErrorRouter.shared.report(outcome)
            }
            return
        }
        guard let url = URL(string: urlString) else {
            showingQRScanner = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                ErrorRouter.shared.report(.said(UserText("invalid_qr_code_construct")))
            }
            return
        }
        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                await MainActor.run {
                    showingQRScanner = false
                    if contactInfo.userId == AuthSessionManager.shared.currentUserId { return }
                    if let chat = chatsViewModel.startChat(
                        redeeming: contactInfo
                    ) {
                        chatsViewModel.selectedTab = 0
                        chatsViewModel.chatToOpen = chat.id
                        InviteRedeemUX.presentPostRedeemSafety(for: contactInfo)
                    }
                }
            } catch {
                await MainActor.run {
                    showingQRScanner = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        ErrorRouter.shared.report(error)
                    }
                }
            }
        }
    }
}

// MARK: - ZoomableCloud, SynapsCloudLayout, ContactMetrics
// → moved to SynapsLayoutEngine.swift (shared with DesktopSynapsView)

// MARK: - Cloud

private struct SynapsCloud: View {
    let layout:       SynapsCloudLayout
    let metricsByUser: [String: ContactMetrics]
    @Binding var selected: ContactRecord?
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    /// The middle of the visible part of the canvas; the cloud's centre and the lens sit here.
    let focus:        CGPoint
    let lens:         SynapsLens

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(layout.items) { item in
                let placed = place(item)
                ContactCircle(
                    user:         item.user,
                    pitch:        SynapsCloudLayout.pitch,
                    metrics:      metricsByUser[item.user.id] ?? .zero,
                    lensScale:    placed.scale,
                    lensOpacity:  placed.opacity,
                    labelOpacity: placed.labelOpacity
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        selected = item.user
                    }
                }
                .position(placed.position)
            }
        }
    }

    /// Where the lens draws a contact. ZoomableCloud scales the canvas about `focus` and then
    /// pans it, so the contact's screen point is worked out, moved by the lens, and taken back
    /// to the canvas point that lands there.
    private func place(_ item: SynapsCloudLayout.Item) -> (position: CGPoint, scale: CGFloat, opacity: Double, labelOpacity: Double) {
        let scale = Swift.max(canvasScale, 0.0001)
        let screen = CGPoint(
            x: focus.x + item.position.x * scale + canvasOffset.width,
            y: focus.y + item.position.y * scale + canvasOffset.height
        )
        let (drawn, rim) = lens.draw(screen, centre: focus)
        return (
            position: CGPoint(
                x: focus.x + (drawn.x - focus.x - canvasOffset.width) / scale,
                y: focus.y + (drawn.y - focus.y - canvasOffset.height) / scale
            ),
            scale: SynapsLens.scale(atRim: rim),
            opacity: SynapsLens.opacity(atRim: rim),
            labelOpacity: SynapsLens.labelOpacity(atDistance: hypot(drawn.x - focus.x, drawn.y - focus.y))
        )
    }
}

// MARK: - Contact Circle

private struct ContactCircle: View {
    let user: ContactRecord
    /// Centre-to-centre distance of neighbours (`SynapsCloudLayout.pitch`).
    let pitch:        CGFloat
    let metrics:      ContactMetrics
    /// Size and opacity under the lens: full in the middle, smaller and dimmer at the edge.
    let lensScale:    CGFloat
    let lensOpacity:  Double
    /// The name shows only around the middle.
    let labelOpacity: Double
    var onTap: () -> Void

    @State private var touchMoved = false

    // MARK: Size
    //
    // Frequency score drives rendered diameter in the range [0.50 … 0.66] × pitch, small
    // enough that the name under each circle clears the row below.
    private var effectiveSize: CGFloat {
        let f = 0.50 + 0.16 * metrics.frequencyScore  // [0.50 … 0.66]
        return pitch * f
    }

    /// Max width for the name under the avatar — slightly wider than the circle.
    private var labelWidth: CGFloat {
        min(pitch * 0.92, max(effectiveSize * 1.35, 56))
    }

    var body: some View {
        // The circle is the view and stands exactly on its point; the name hangs under it as an
        // overlay, two points below the rim, and takes no room of its own. Until 2026-10-08 the
        // circle sat in a frame a fifth larger (room for the halo) with the name below that, so
        // the name floated off the circle and the circle stood above its point.
        ZStack {
            ZStack {
                if let data = user.avatar, let img = PlatformImage(data: data) {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(accentColor.opacity(0.12))
                    IdenticonView(seed: user.id)
                }
            }
            .frame(width: effectiveSize, height: effectiveSize)
            .clipShape(Circle())
            .overlay(Circle().stroke(borderColor, lineWidth: metrics.activityRingLineWidth))
            // Soft halo — ambient “this node is live” (not a feed preview).
            .background {
                if metrics.showsActivityHalo && !user.isBlocked {
                    Circle()
                        .stroke(Color.CT.accent.opacity(0.28), lineWidth: 3)
                        .frame(width: effectiveSize * 1.14, height: effectiveSize * 1.14)
                }
            }

            if metrics.unreadCount > 0 {
                unreadBadge
                    .offset(x: effectiveSize * 0.34, y: -effectiveSize * 0.34)
            }
        }
        .overlay(alignment: .top) {
            // A name of two words wraps onto a second line rather than being cut.
            Text(user.resolvedDisplayName)
                .font(CTFont.ui(10, weight: .medium))
                .foregroundStyle(user.isBlocked ? Color.CT.textDim : Color.CT.text)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(width: labelWidth)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: effectiveSize + 2)
                .opacity(labelOpacity)
                .allowsHitTesting(false)
        }
        .scaleEffect(lensScale)
        .opacity(lensOpacity)
        // Use DragGesture(minimumDistance: 0) so we can distinguish a stationary
        // tap from a drag that happens to end over the contact. Only fire onTap
        // when the finger hasn't moved more than 8 pt — matching the parent
        // canvas drag threshold — so pan/zoom never triggers navigation.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if hypot(value.translation.width, value.translation.height) > 8 {
                        touchMoved = true
                    }
                }
                .onEnded { value in
                    defer { touchMoved = false }
                    guard !touchMoved else { return }
                    guard hypot(value.translation.width, value.translation.height) <= 8 else { return }
                    onTap()
                }
        )
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var unreadBadge: some View {
        let n = metrics.unreadCount
        let label = n > 99 ? "99+" : "\(n)"
        return Text(label)
            .font(CTFont.ui(n > 9 ? 8 : 9, weight: .bold))
            .foregroundStyle(Color.CT.bg)
            .padding(.horizontal, n > 9 ? 4 : 0)
            .frame(minWidth: 15, minHeight: 15)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.CT.accent)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.CT.bg.opacity(0.35), lineWidth: 0.5)
            )
    }

    private var accessibilityLabel: String {
        let name = user.resolvedDisplayName
        if metrics.unreadCount > 0 {
            return "\(name), \(metrics.unreadCount)"
        }
        return name
    }

    // MARK: Style

    private var accentColor: Color { .hexagonAccent(for: user.id) }
    private var borderColor: Color {
        if user.isBlocked { return Color.red.opacity(0.55) }
        return metrics.activityRingColor
    }
}

// MARK: - Preview

// DEBUG only: the previews seed `ContactsLive.useForPreview`, which a release build does not have.
#if DEBUG
#Preview("Cloud") {
    let container = PreviewHelpers.createPreviewContainer()
    ContactsLive.useForPreview(container)
    let context = container.viewContext

    let users: [(String, String, String)] = [
        ("u1",  "alice",   "Alice Wonderland"),
        ("u2",  "bob",     "Bob Builder"),
        ("u3",  "charlie", "Charlie Chaplin"),
        ("u4",  "dave",    "Dave Villain"),
        ("u5",  "eva",     "Eva Elfie"),
        ("u6",  "frank",   "Frank Ocean"),
        ("u7",  "grace",   "Grace Hopper"),
        ("u8",  "henry",   "Henry Ford"),
        ("u9",  "iris",    "Iris Chang"),
        ("u10", "james",   "James Webb"),
    ]
    for (id, username, name) in users {
        let user = PreviewHelpers.createSampleUser(context: context, id: id, username: username, displayName: name)
        user.isContact = true
        user.addedAt = Date()
    }
    let blocked = PreviewHelpers.createSampleUser(context: context, id: "u11", username: "blocked", displayName: "Blocked User")
    blocked.isContact = true
    blocked.isBlocked = true
    blocked.addedAt = Date()
    try? context.save()

    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)

    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    let container = PreviewHelpers.createPreviewContainer()
    ContactsLive.useForPreview(container)
    let context = container.viewContext
    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)
    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
        .preferredColorScheme(.dark)
}
#endif
