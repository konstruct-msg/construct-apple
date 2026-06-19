//
//  SynapsView.swift
//  Construct Messenger
//
//  Synaps — persistent contact network, independent of chats.
//  Layout: Zoomable/pannable honeycomb cloud of round avatars.
//  Gestures: pinch-to-zoom + drag-to-pan. Contacts near the screen
//  center appear larger; peripheral contacts are dimmer — Apple Watch style.
//

import SwiftUI
import CoreData
import GRPCCore

// MARK: - SynapsView

struct SynapsView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(ChatsViewModel.self) private var chatsViewModel

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \User.displayName, ascending: true)],
        predicate: NSPredicate(format: "isContact == YES"),
        animation: .default
    )
    private var contacts: FetchedResults<User>

    @State private var searchText      = ""
    @State private var selectedContact: User? = nil
    @State private var pruneTarget:     User? = nil
    @State private var showPruneConfirm = false
    // Shared canvas transform — owned here so HoneycombCloud can read them for
    // the proximity effect while ZoomableCloud drives them via gestures.
    @State private var canvasScale:  CGFloat  = 1.0   // recalculated on appear
    @State private var canvasOffset: CGSize   = .zero

    // MARK: - Remote search state
    enum RemoteSearchState {
        case idle
        case searching
        case found(Shared_Proto_Services_V1_UserProfile)
        case notFound
    }
    @State private var remoteState: RemoteSearchState = .idle
    @State private var searchTask: Task<Void, Never>? = nil

    // MARK: - QR Scanner
    @State private var showingQRScanner = false

    // MARK: - Contact requests
    @State private var contactRequestsVM: ContactRequestsViewModel? = nil
    @State private var selectedRequest: ContactRequestsViewModel.IncomingRequest? = nil
    @State private var contactMetricsByUser: [String: ContactMetrics] = [:]
    @State private var isRefreshingContactRequests = false

    private var filtered: [User] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(contacts) }
        return contacts.filter { userMatchesQuery($0, query: query) }
    }

    var body: some View {
        let filteredContacts = filtered
        NavigationStack {
            ZStack {
                // Main content - full, padded top for floating search capsule
                VStack(spacing: 0) {
                    if !searchText.isEmpty, filteredContacts.isEmpty {
                        remoteSearchCard
                            .padding(.top, 8)
                    }
                    if let vm = contactRequestsVM, !vm.incomingRequests.isEmpty, searchText.isEmpty {
                        requestsSection(vm: vm)
                            .padding(.top, 8)
                    }
                    GeometryReader { geo in
                        ZStack {
                            CTMatrixBackground().ignoresSafeArea()

                            if contacts.isEmpty {
                                emptyState
                            } else {
                                ZoomableCloud(
                                    scale:    $canvasScale,
                                    offset:   $canvasOffset,
                                    minScale: 0.20,
                                    maxScale: 3.0
                                ) {
                                    HoneycombCloud(
                                        contacts:     filteredContacts,
                                        metricsByUser: contactMetricsByUser,
                                        selected:     $selectedContact,
                                        canvasScale:  canvasScale,
                                        canvasOffset: canvasOffset,
                                        screenSize:   geo.size
                                    )
                                }
                            }
                        }
                        .padding(.bottom, 72) // for floating tab capsule
                        .onAppear {
                            canvasScale = fitScale(contacts: Array(contacts), screenSize: geo.size)
                        }
                    }
                }

                // Floating independent search capsule (and keep nav above)
                VStack(spacing: 0) {
                    synapsNavBar
                    synapsSearchBar
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .ctBackground()
            .onAppear {
                rebuildContactMetrics()
            }
            .onChange(of: searchText) { _, newValue in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    canvasOffset = .zero
                }
                searchTask?.cancel()
                remoteState = .idle
                guard !newValue.isEmpty else { return }
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
                let vm = ContactRequestsViewModel(viewContext: context)
                contactRequestsVM = vm
                await refreshContactRequests(vm: vm, reason: "initial_task")
            }
            .onChange(of: chatsViewModel.selectedTab) { _, newTab in
                guard newTab == 1, let vm = contactRequestsVM else { return }
                Task { await refreshContactRequests(vm: vm, reason: "tab_selected") }
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
                    guard let userId = pendingIds.first,
                          let uuid = UUID(uuidString: userId) else { return }
                    let req = NSFetchRequest<User>(entityName: "User")
                    req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                    req.fetchLimit = 1
                    if let user = try? context.fetch(req).first {
                        await MainActor.run { chatsViewModel.openOrCreateChat(with: user) }
                    }
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { contactURL in handleScannedQR(contactURL) }
            }
            .sheet(item: $selectedContact) { user in
                UserProfileView(
                    user: user,
                    showMessageButton: true,
                    onOpenChat: { chatsViewModel.openOrCreateChat(with: user) },
                    onPrune: {
                        pruneTarget = user
                        showPruneConfirm = true
                    }
                )
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
                            chatsViewModel.openOrCreateChat(with: user)
                        },
                        onDeclineBlock: { try await vm.declineAndBlock(requestId: request.id) },
                        onSpamBlock: { try await vm.reportSpamAndBlock(requestId: request.id) }
                    )
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
                    chatsViewModel.pruneContact(userId: user.id)
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

    // MARK: - Initial scale

    /// Compute a zoom level that fits all contacts with ~12% breathing room.
    private func fitScale(contacts: [User], screenSize: CGSize) -> CGFloat {
        guard !contacts.isEmpty else { return 1.0 }
        let engine = HoneycombLayoutEngine(contacts: contacts, canvasSize: screenSize)
        return engine.initialScale
    }

    private func rebuildContactMetrics() {
        let users = Array(contacts)
        guard !users.isEmpty else {
            contactMetricsByUser = [:]
            return
        }

        var drafts: [(id: String, count: Int, lastMessage: Date?)] = []
        var maxCount = 0

        for user in users {
            let userChats = (user.chats?.allObjects as? [Chat]) ?? []
            let count = userChats.map { $0.messages?.count ?? 0 }.max() ?? 0
            maxCount = max(maxCount, count)
            let lastMessage = userChats.compactMap { $0.lastMessageTime }.max()
            drafts.append((id: user.id, count: count, lastMessage: lastMessage))
        }

        let now = Date()
        var nextMap: [String: ContactMetrics] = [:]
        for draft in drafts {
            let score: CGFloat = maxCount > 0 ? CGFloat(draft.count) / CGFloat(maxCount) : 0
            let recency: ContactMetrics.Recency
            if let t = draft.lastMessage {
                let age = now.timeIntervalSince(t)
                recency = age < 86_400 ? .fresh : age < 604_800 ? .recent : .none
            } else {
                recency = .none
            }
            nextMap[draft.id] = ContactMetrics(frequencyScore: score, recency: recency)
        }
        contactMetricsByUser = nextMap
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
        isRefreshingContactRequests = true
        defer { isRefreshingContactRequests = false }

        Log.info("Refreshing contact requests (\(reason))", category: "SynapsView")
        await vm.load()

        let pendingIds = ContactRequestService.shared.consumePendingNavigationUserIds()
        let pendingUser: User? = pendingIds.first.flatMap { userId in
            guard let uuid = UUID(uuidString: userId) else { return nil }
            let req = NSFetchRequest<User>(entityName: "User")
            req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            req.fetchLimit = 1
            return try? context.fetch(req).first
        }

        let accepted = await vm.checkAcceptedRequests(context: context)
        if let first = accepted.first ?? pendingUser {
            chatsViewModel.openOrCreateChat(with: first)
        }
    }

    // MARK: - Nav Bar

    private var synapsNavBar: some View {
        HStack(spacing: 10) {
            Text(NSLocalizedString("synapses", comment: "").uppercased())
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.text)
                .tracking(4)
            Spacer()
            #if os(iOS)
            Button { showingQRScanner = true } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: CTLayout.navIconSize, weight: .medium))
                    .foregroundColor(Color.CT.accent)
            }
            #endif
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .ctBorderBottom()
    }

    // MARK: - Search Bar

    private var synapsSearchBar: some View {
        CTSearchBar(text: $searchText)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text(LocalizedStringKey("synapses_empty_title"))
                .font(CTFont.bold(17))
                .foregroundStyle(Color.CT.text)
            Text(LocalizedStringKey("synapses_empty_subtitle"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Remote Search Card

    @ViewBuilder
    private var remoteSearchCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LocalizedStringKey("synapses_remote_result_header"))
                    .font(CTFont.bold(10))
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
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                    Spacer()
                    ProgressView().tint(Color.CT.accent).scaleEffect(0.7)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

            case .found(let profile):
                let alreadySent = contactRequestsVM.map {
                    $0.hasPendingSentRequest(toUserId: profile.userID)
                } ?? false
                let fallbackQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

                Button {
                    if !alreadySent {
                        Task { await sendContactRequest(to: profile) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text("[@]")
                            .font(CTFont.bold(14))
                            .foregroundStyle(Color.CT.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            if profile.hasDisplayName {
                                Text(profile.displayName)
                                    .font(CTFont.bold(14))
                                    .foregroundStyle(Color.CT.text)
                            }
                            if profile.hasUsername {
                                Text("@\(profile.username)")
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                            } else if !fallbackQuery.isEmpty {
                                Text("@\(fallbackQuery)")
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.text)
                            } else {
                                Text(DisplayNameGenerator.generate(from: profile.userID))
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.text)
                            }
                        }
                        Spacer()
                        Text(alreadySent
                             ? NSLocalizedString("contact_request_pending", comment: "")
                             : NSLocalizedString("contact_request_send_action", comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundStyle(alreadySent ? Color.CT.textDim : Color.CT.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(alreadySent)

            case .notFound:
                HStack {
                    Text(LocalizedStringKey("synapses_not_found"))
                        .font(CTFont.regular(13))
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

    private func userMatchesQuery(_ user: User, query: String) -> Bool {
        user.displayName.localizedCaseInsensitiveContains(query)
            || user.username.localizedCaseInsensitiveContains(query)
    }

    /// Sends a contact request to a discoverable user found via remote search.
    @MainActor
    private func sendContactRequest(to profile: Shared_Proto_Services_V1_UserProfile) async {
        guard let vm = contactRequestsVM else { return }
        do {
            let requestId = try await vm.sendRequest(toUserId: profile.userID)
            vm.markSentRequest(toUserId: profile.userID, requestId: requestId)
            // Refresh UI to show [pending] state.
            remoteState = .found(profile)
        } catch {
            // Surface the failure instead of swallowing it — a silent catch here hid the
            // real reason "Send request" did nothing (RPC rejected / no delivery). Log the
            // exact error and tell the user so it's retryable and diagnosable.
            Log.error("sendContactRequest failed for \(profile.userID.prefix(8))…: \(error)", category: "ContactRequest")
            ErrorRouter.shared.report(.unknown(error.userFacingMessage))
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
                    HStack(spacing: 10) {
                        Text("[@]")
                            .font(CTFont.bold(13))
                            .foregroundStyle(Color.CT.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = request.displayName, !name.isEmpty {
                                Text(name)
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.text)
                            } else if let username = request.username, !username.isEmpty {
                                Text("@\(username)")
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.text)
                            } else {
                                Text(DisplayNameGenerator.generate(from: request.fromUserId))
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
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
            chatsViewModel.openOrCreateChat(with: user)
        } catch {
            Log.error("addRemoteUserAndChat failed: \(error)", category: "SynapsView")
        }
    }

    // MARK: - QR Handler

    private func handleScannedQR(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            showingQRScanner = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                ErrorRouter.shared.report(.unknown(NSLocalizedString("invalid_qr_code_construct", comment: "")))
            }
            return
        }
        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                await MainActor.run {
                    showingQRScanner = false
                    if contactInfo.userId == AuthSessionManager.shared.currentUserId { return }
                    let publicUserInfo = PublicUserInfo(
                        id: contactInfo.userId,
                        username: contactInfo.username,
                        avatarUrl: nil,
                        bio: nil,
                        deviceId: contactInfo.deviceId
                    )
                    _ = chatsViewModel.startChat(with: publicUserInfo)
                }
            } catch {
                await MainActor.run {
                    showingQRScanner = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        ErrorRouter.shared.report(.unknown(error.localizedDescription))
                    }
                }
            }
        }
    }
}

// MARK: - ZoomableCloud, HoneycombLayoutEngine, ContactMetrics
// → moved to SynapsLayoutEngine.swift (shared with DesktopSynapsView)

// MARK: - Honeycomb Cloud

private struct HoneycombCloud: View {
    let contacts:     [User]
    let metricsByUser: [String: ContactMetrics]
    @Binding var selected: User?
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize

    var body: some View {
        GeometryReader { geo in
            let engine  = HoneycombLayoutEngine(contacts: contacts, canvasSize: geo.size)
            let metrics = metricsByUser

            // Canvas is screen-sized; contacts that overflow (large grids when
            // zoomed to 1:1) are clipped by ZoomableCloud and visible when zoomed out.
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: geo.size.width, height: geo.size.height)

                ForEach(engine.items) { item in
                    ContactCircle(
                        user:         item.user,
                        cellSize:     engine.cellSize,
                        metrics:      metrics[item.user.id] ?? .zero,
                        canvasPos:    item.position,
                        canvasScale:  canvasScale,
                        canvasOffset: canvasOffset,
                        screenSize:   screenSize
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            selected = item.user
                        }
                    }
                    .position(item.position)
                }
            }
        }
    }
}

// MARK: - Contact Circle

private struct ContactCircle: View {
    @ObservedObject var user: User
    /// Base cell size from the layout engine (cellWidth × 0.74).
    let cellSize:     CGFloat
    let metrics:      ContactMetrics
    let canvasPos:    CGPoint
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onTap: () -> Void

    @State private var touchMoved = false

    // MARK: Size
    //
    // Frequency score drives rendered diameter in the range [0.55 … 0.75] × cellWidth.
    // Upper bound kept well below the hex vertical step (cellWidth × 0.866) so that
    // even with the proximity scale boost circles never visually overlap.
    private var effectiveSize: CGFloat {
        let f = 0.55 + 0.20 * metrics.frequencyScore  // [0.55 … 0.75]
        return cellSize / 0.74 * f                     // remap: cellSize = cellWidth×0.74
    }

    var body: some View {
        ZStack {
            if let data = user.avatarData, let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(accentColor.opacity(0.18))
                Text(initials)
                    .font(CTFont.bold(effectiveSize * 0.26))
                    .foregroundStyle(accentColor)
            }
        }
        .frame(width: effectiveSize, height: effectiveSize)
        .clipShape(Circle())
        .overlay(Circle().stroke(borderColor, lineWidth: 1.5))
        .scaleEffect(proximityScale)
        .opacity(proximityOpacity)
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
    }

    // MARK: Proximity effect
    //
    // Compute where this contact actually appears on screen after the canvas
    // transform (scaleEffect + offset). Contacts close to the screen centre
    // get a scale boost (≤ +30%) and full opacity; peripheral ones fade out.

    private var screenPos: CGPoint {
        let cx = screenSize.width  / 2
        let cy = screenSize.height / 2
        return CGPoint(
            x: (canvasPos.x - cx) * canvasScale + cx + canvasOffset.width,
            y: (canvasPos.y - cy) * canvasScale + cy + canvasOffset.height
        )
    }

    private var distanceToCenter: CGFloat {
        let c = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        return hypot(screenPos.x - c.x, screenPos.y - c.y)
    }

    /// Contacts within ~50% of the shortest screen half-dimension are "central".
    private var proximityScale: CGFloat {
        let radius = Swift.min(screenSize.width, screenSize.height) * 0.5
        let t = Swift.max(0, 1 - distanceToCenter / radius)
        return 1.0 + 0.10 * t  // max ×1.10 — keeps circles within their hex cells
    }

    /// Peripheral contacts fade to 40% opacity.
    private var proximityOpacity: Double {
        let radius = Swift.min(screenSize.width, screenSize.height) * 0.65
        let t = Swift.max(0, 1 - distanceToCenter / radius)
        return 0.40 + 0.60 * t
    }

    // MARK: Style

    private var accentColor: Color { .hexagonAccent(for: user.id) }
    private var borderColor: Color {
        user.isBlocked ? Color.red.opacity(0.55) : Color.CT.textDim.opacity(0.5)
    }

    private var initials: String {
        let words = user.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        switch words.count {
        case 0:  return "?"
        case 1:  return String(words[0].prefix(2)).uppercased()
        default: return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
    }
}

// MARK: - Preview

#Preview("Honeycomb") {
    let container = PreviewHelpers.createPreviewContainer()
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
    let context = container.viewContext
    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)
    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
        .preferredColorScheme(.dark)
}
