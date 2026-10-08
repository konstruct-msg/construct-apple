//
//  DesktopSynapsView.swift
//  Construct Desktop
//
//  macOS adaptation of SynapsView.
//  Layout: zoomable honeycomb node cloud — trackpad-first design.
//  Gestures: pinch-to-zoom (MagnificationGesture), two-finger drag (DragGesture).
//  Interaction: click = popover, right-click = context menu, hover = ring highlight.
//  Profile: popover anchored to the node — no sheet, no navigation push.
//

import SwiftUI
import CoreData
import AppKit

// MARK: - DesktopSynapsView

struct DesktopSynapsView: View {

    var onSwitchToChats: (() -> Void)? = nil

    @Environment(\.managedObjectContext) private var context
    @Environment(ChatsViewModel.self)    private var chatsViewModel

    /// People marked as contacts, in the order shown (`ContactsLive.contacts`).
    private var contacts: [ContactRecord] { ContactsLive.shared.contacts() }

    @State private var searchText      = ""
    @State private var pruneTarget:    ContactRecord? = nil
    @State private var showPruneAlert  = false
    @State private var canvasScale:    CGFloat = 1.0
    @State private var canvasOffset:   CGSize  = .zero

    // Contact requests (parity with iOS SynapsView)
    @State private var contactRequestsVM: ContactRequestsViewModel? = nil
    @State private var selectedRequest: ContactRequestsViewModel.IncomingRequest? = nil
    @State private var isRefreshingContactRequests = false
    @State private var lastContactRequestsRefresh: Date = .distantPast

    private static let contactRequestsRefreshInterval: TimeInterval = 8

    private var filtered: [ContactRecord] {
        guard !searchText.isEmpty else { return contacts }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let vm = contactRequestsVM, !vm.incomingRequests.isEmpty, searchText.isEmpty {
                requestsSection(vm: vm)
                Rectangle().fill(Color.CT.noise).frame(height: 1)
            }

            GeometryReader { geo in
                ZStack {
                    Color.CT.bg
                    CTMatrixBackground()

                    if contacts.isEmpty {
                        emptyState
                    } else {
                        ZoomableCloud(
                            scale:    $canvasScale,
                            offset:   $canvasOffset,
                            minScale: 0.20,
                            maxScale: 3.0
                        ) {
                            DesktopSynapsCloud(
                                contacts:     filtered,
                                canvasScale:  canvasScale,
                                canvasOffset: canvasOffset,
                                screenSize:   geo.size,
                                onMessage: { user in
                                    chatsViewModel.openOrCreateChat(withContact: user.id)
                                },
                                onRemove: { user in
                                    pruneTarget = user
                                    showPruneAlert = true
                                }
                            )
                        }
                    }
                }
                .onAppear {
                    canvasScale = fitScale(contacts: contacts, screenSize: geo.size)
                }
            }
        }
        .background(Color.CT.bg)
        .navigationTitle(NSLocalizedString("people", comment: ""))
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: LocalizedStringKey("synapses_search_prompt")
        )
        .task {
            let vm = contactRequestsVM ?? ContactRequestsViewModel(viewContext: context)
            contactRequestsVM = vm
            await refreshContactRequests(vm: vm, reason: "synaps_appear")
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidBecomeActive)) { _ in
            guard let vm = contactRequestsVM else { return }
            Task { await refreshContactRequests(vm: vm, reason: "app_active") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contactRequestAccepted)) { _ in
            Task {
                let pendingIds = ContactRequestService.shared.consumePendingNavigationUserIds()
                guard let userId = pendingIds.first, !userId.isEmpty else { return }
                await MainActor.run {
                    chatsViewModel.openOrCreateChat(withContact: userId)
                    onSwitchToChats?()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contactRequestReceived)) { _ in
            guard let vm = contactRequestsVM else { return }
            Task { await refreshContactRequests(vm: vm, reason: "push_received") }
        }
        .sheet(item: $selectedRequest) { request in
            if let vm = contactRequestsVM {
                ContactRequestSheet(
                    request: request,
                    onAccept: {
                        let user = try await vm.accept(request: request, context: context)
                        chatsViewModel.openOrCreateChat(with: user)
                        onSwitchToChats?()
                    },
                    onDeclineBlock: { try await vm.declineAndBlock(requestId: request.id) },
                    onSpamBlock: { try await vm.reportSpamAndBlock(requestId: request.id) }
                )
                .sheetNavigation(closes: false)
                .frame(minWidth: 400, minHeight: 280)
            }
        }
        .onChange(of: searchText) { _, _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                canvasOffset = .zero
            }
        }
        .alert(
            NSLocalizedString("synapses_prune_title", comment: ""),
            isPresented: $showPruneAlert
        ) {
            Button(NSLocalizedString("synapses_prune_action", comment: ""), role: .destructive) {
                if let user = pruneTarget {
                    Task { await chatsViewModel.pruneContact(userId: user.id) }
                }
                pruneTarget = nil
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) { pruneTarget = nil }
        } message: {
            if let name = pruneTarget?.displayName {
                Text(String(format: NSLocalizedString("synapses_prune_message", comment: ""), name))
            }
        }
    }

    // MARK: - Contact requests

    @MainActor
    private func refreshContactRequests(
        vm: ContactRequestsViewModel,
        reason: String
    ) async {
        guard !isRefreshingContactRequests else {
            Log.debug("Skipping contact request refresh (\(reason)) — already in progress", category: "DesktopSynapsView")
            return
        }
        let sinceLast = Date().timeIntervalSince(lastContactRequestsRefresh)
        guard sinceLast >= Self.contactRequestsRefreshInterval else {
            Log.debug("Skipping contact request refresh (\(reason)) — throttled (\(Int(sinceLast))s ago)", category: "DesktopSynapsView")
            return
        }
        isRefreshingContactRequests = true
        lastContactRequestsRefresh = Date()
        defer { isRefreshingContactRequests = false }

        Log.info("Refreshing contact requests (\(reason))", category: "DesktopSynapsView")
        await vm.load()

        let pendingId = ContactRequestService.shared.consumePendingNavigationUserIds().first { !$0.isEmpty }

        let accepted = await vm.checkAcceptedRequests(context: context)
        if let first = accepted.first {
            chatsViewModel.openOrCreateChat(with: first)
            onSwitchToChats?()
        } else if let pendingId {
            chatsViewModel.openOrCreateChat(withContact: pendingId)
            onSwitchToChats?()
        }
    }

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
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(CTFont.ui(12, weight: .semibold))
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text(LocalizedStringKey("synapses_empty_title"))
                .font(CTFont.headline)
                .foregroundStyle(Color.CT.text)
            Text(LocalizedStringKey("synapses_empty_subtitle"))
                .font(CTFont.secondary)
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                NotificationCenter.default.post(name: .desktopShowAddContact, object: nil)
            } label: {
                Label {
                    Text(LocalizedStringKey("new_contact"))
                        .font(CTFont.ui(12, weight: .medium))
                } icon: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(CTFont.ui(12, weight: .medium))
                }
                .foregroundStyle(Color.CT.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(
                    CTShape.control().stroke(Color.CT.accent.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fitScale(contacts: [ContactRecord], screenSize: CGSize) -> CGFloat {
        guard !contacts.isEmpty else { return 1.0 }
        let metrics = ContactMetrics.byContact(contacts.map(\.id), in: context)
        return SynapsCloudLayout(contacts: contacts, metrics: metrics).fitScale(in: screenSize)
    }
}

// MARK: - DesktopSynapsCloud

private struct DesktopSynapsCloud: View {
    @Environment(\.managedObjectContext) private var context
    let contacts:     [ContactRecord]
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onMessage:    (ContactRecord) -> Void
    var onRemove:     (ContactRecord) -> Void

    private var metricsMap: [String: ContactMetrics] {
        ContactMetrics.byContact(contacts.map(\.id), in: context)
    }

    var body: some View {
        GeometryReader { geo in
            let metrics = metricsMap
            let layout  = SynapsCloudLayout(contacts: contacts, metrics: metrics)
            let centre  = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: geo.size.width, height: geo.size.height)

                ForEach(layout.items) { item in
                    let position = CGPoint(x: centre.x + item.position.x, y: centre.y + item.position.y)
                    DesktopContactNode(
                        user:         item.user,
                        pitch:        SynapsCloudLayout.pitch,
                        metrics:      metrics[item.user.id] ?? .zero,
                        canvasPos:    position,
                        canvasScale:  canvasScale,
                        canvasOffset: canvasOffset,
                        screenSize:   screenSize,
                        onMessage:    { onMessage(item.user) },
                        onRemove:     { onRemove(item.user) }
                    )
                    .position(position)
                }
            }
        }
    }
}

// MARK: - DesktopContactNode

private struct DesktopContactNode: View {
    let user: ContactRecord
    /// Centre-to-centre distance of neighbours (`SynapsCloudLayout.pitch`).
    let pitch:        CGFloat
    let metrics:      ContactMetrics
    let canvasPos:    CGPoint
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onMessage:    () -> Void
    var onRemove:     () -> Void

    @State private var showPopover = false
    @State private var isHovered   = false


    /// Slightly smaller circles so a name label fits under each node (mirrors iOS).
    private var effectiveSize: CGFloat {
        let f = 0.50 + 0.16 * metrics.frequencyScore  // [0.50 … 0.66]
        return pitch * f
    }

    private var labelWidth: CGFloat {
        min(pitch * 0.92, max(effectiveSize * 1.35, 56))
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if metrics.showsActivityHalo && !user.isBlocked {
                    Circle()
                        .stroke(Color.CT.accent.opacity(0.28), lineWidth: 3)
                        .frame(width: effectiveSize * 1.14, height: effectiveSize * 1.14)
                }

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
                .overlay(
                    Circle().stroke(
                        isHovered ? Color.CT.accent : borderColor,
                        lineWidth: isHovered ? 2.5 : metrics.activityRingLineWidth
                    )
                )

                if metrics.unreadCount > 0 {
                    let n = metrics.unreadCount
                    let label = n > 99 ? "99+" : "\(n)"
                    Text(label)
                        .font(CTFont.ui(n > 9 ? 8 : 9, weight: .bold))
                        .foregroundStyle(Color.CT.bg)
                        .padding(.horizontal, n > 9 ? 4 : 0)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule(style: .continuous).fill(Color.CT.accent))
                        .offset(x: effectiveSize * 0.34, y: -effectiveSize * 0.34)
                }
            }
            .frame(width: effectiveSize * 1.2, height: effectiveSize * 1.2)
            .opacity(proximityOpacity)

            // Two lines' height always, as on iOS — see ContactCircle.
            ZStack(alignment: .top) {
                Text(verbatim: "X\nX").hidden()
                Text(user.resolvedDisplayName)
                    .foregroundStyle(user.isBlocked ? Color.CT.textDim : Color.CT.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }
            .font(CTFont.ui(10, weight: .medium))
            .frame(width: labelWidth)
            .opacity(min(1.0, proximityOpacity + 0.35))
        }
        .scaleEffect(proximityScale)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        // Hover: ring highlight + pointer cursor
        .onHover { inside in
            isHovered = inside
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        // Click: open profile popover
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                showPopover = true
            }
        }
        // Right-click: context menu
        .contextMenu {
            Button {
                onMessage()
            } label: {
                Text(NSLocalizedString("message", comment: ""))
            }
            Divider()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text(NSLocalizedString("synapses_prune_action", comment: ""))
            }
        }
        // Profile popover anchored to the node
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DesktopNodePopover(
                user: user,
                onMessage: {
                    showPopover = false
                    onMessage()
                },
                onRemove: {
                    showPopover = false
                    onRemove()
                }
            )
        }
    }

    // MARK: Proximity effect (mirrors iOS SynapsView logic)

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

    private var proximityScale: CGFloat {
        let radius = Swift.min(screenSize.width, screenSize.height) * 0.5
        let t = Swift.max(0, 1 - distanceToCenter / radius)
        return 1.0 + 0.10 * t
    }

    private var proximityOpacity: Double {
        let radius = Swift.min(screenSize.width, screenSize.height) * 0.65
        let t = Swift.max(0, 1 - distanceToCenter / radius)
        return 0.40 + 0.60 * t
    }

    // MARK: Style

    private var accentColor: Color { .hexagonAccent(for: user.id) }
    private var borderColor: Color {
        if user.isBlocked { return Color.red.opacity(0.55) }
        return metrics.activityRingColor
    }

}

// MARK: - DesktopNodePopover

/// Compact contact card shown in a popover anchored to the node.
/// Actions: message → opens chat in detail column; remove → prune with confirmation.
private struct DesktopNodePopover: View {
    @Environment(\.dismiss) private var dismiss
    let user: ContactRecord
    var onMessage: () -> Void
    var onRemove:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header: avatar + name
            VStack(spacing: 8) {
                avatarView
                    .padding(.top, 16)

                Text(user.displayName)
                    .font(CTFont.bodyEmphasis)
                    .foregroundStyle(Color.CT.text)

                Text("@\(user.username)")
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            // Actions
            VStack(spacing: 0) {
                popoverButton(
                    label: NSLocalizedString("message", comment: ""),
                    symbol: "bubble.left.fill",
                    color: Color.CT.accent
                ) {
                    onMessage()
                }

                Rectangle().fill(Color.CT.noise.opacity(0.5)).frame(height: 1)
                    .padding(.horizontal, 12)

                popoverButton(
                    label: NSLocalizedString("synapses_prune_action", comment: ""),
                    symbol: "xmark.circle",
                    color: Color.CT.danger
                ) {
                    onRemove()
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 220)
        .background(Color.CT.bg)
        .overlay(
            Rectangle().stroke(Color.CT.noise, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var avatarView: some View {
        let size: CGFloat = 52
        ZStack {
            if let data = user.avatar, let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                let accent = Color.hexagonAccent(for: user.id)
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: size, height: size)
                IdenticonView(seed: user.id)
                    .frame(width: size, height: size)
            }
        }
        .overlay(
            Circle().stroke(
                user.isBlocked ? Color.red.opacity(0.5) : Color.CT.textDim.opacity(0.4),
                lineWidth: 1.5
            )
        )
    }

    private func popoverButton(label: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(CTFont.ui(12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            // subtle row hover
            _ = inside
        }
    }

}
