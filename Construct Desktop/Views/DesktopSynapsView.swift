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

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \User.displayName, ascending: true)],
        predicate: NSPredicate(format: "isContact == YES"),
        animation: .default
    )
    private var contacts: FetchedResults<User>

    @State private var searchText      = ""
    @State private var pruneTarget:    User? = nil
    @State private var showPruneAlert  = false
    @State private var canvasScale:    CGFloat = 1.0
    @State private var canvasOffset:   CGSize  = .zero

    private var filtered: [User] {
        guard !searchText.isEmpty else { return Array(contacts) }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            synapsToolbar
            Rectangle().fill(Color.CT.noise).frame(height: 1)

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
                            DesktopHoneycombCloud(
                                contacts:     filtered,
                                canvasScale:  canvasScale,
                                canvasOffset: canvasOffset,
                                screenSize:   geo.size,
                                onMessage: { user in
                                    chatsViewModel.openOrCreateChat(with: user)
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
                    canvasScale = fitScale(contacts: Array(contacts), screenSize: geo.size)
                }
            }
        }
        .background(Color.CT.bg)
        .onChange(of: searchText) { _, _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                canvasOffset = .zero
            }
        }
        .alert(
            NSLocalizedString("synaps_prune_title", comment: ""),
            isPresented: $showPruneAlert
        ) {
            Button(NSLocalizedString("synaps_prune_action", comment: ""), role: .destructive) {
                if let user = pruneTarget { chatsViewModel.pruneContact(userId: user.id) }
                pruneTarget = nil
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) { pruneTarget = nil }
        } message: {
            if let name = pruneTarget?.displayName {
                Text(String(format: NSLocalizedString("synaps_prune_message", comment: ""), name))
            }
        }
    }

    // MARK: - Column toolbar

    private var synapsToolbar: some View {
        HStack(spacing: 0) {
            // Back to Chats (visible when Synaps occupies full canvas)
            if let switchBack = onSwitchToChats {
                Button(action: switchBack) {
                    Text("CHATS")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)

                Rectangle().fill(Color.CT.noise).frame(width: 1, height: 16)
                    .padding(.horizontal, 8)
            }

            Text(NSLocalizedString("synaps", comment: "").uppercased())
                .font(CTFont.bold(11))
                .tracking(4)
                .foregroundStyle(Color.CT.text)
                .padding(.leading, onSwitchToChats == nil ? 14 : 0)

            Spacer()

            // Inline search
            HStack(spacing: 4) {
                Text("[")
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.textDim)
                TextField("", text: $searchText,
                          prompt: Text(LocalizedStringKey("synaps_search_prompt"))
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.textDim))
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.text)
                    .tint(Color.CT.accent)
                    .frame(width: 110)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Text("×")
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("]")
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                }
            }

            Spacer().frame(width: 6)

            // Add node button
            Button {
                NotificationCenter.default.post(name: .desktopShowAddContact, object: nil)
            } label: {
                Text("[+]")
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("add_contact", comment: ""))
            .padding(.trailing, 10)
        }
        .frame(height: 36)
        .background(Color.CT.bg)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text(LocalizedStringKey("synaps_empty_title"))
                .font(CTFont.bold(14))
                .foregroundStyle(Color.CT.text)
            Text(LocalizedStringKey("synaps_empty_subtitle"))
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                NotificationCenter.default.post(name: .desktopShowAddContact, object: nil)
            } label: {
                Text("ADD NODE")
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(
                        Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fitScale(contacts: [User], screenSize: CGSize) -> CGFloat {
        guard !contacts.isEmpty else { return 1.0 }
        return HoneycombLayoutEngine(contacts: contacts, canvasSize: screenSize).initialScale
    }
}

// MARK: - DesktopHoneycombCloud

private struct DesktopHoneycombCloud: View {
    let contacts:     [User]
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onMessage:    (User) -> Void
    var onRemove:     (User) -> Void

    private var rawCounts: [String: Int] {
        var result: [String: Int] = [:]
        for user in contacts {
            let chats = (user.chats?.allObjects as? [Chat]) ?? []
            result[user.id] = chats.map { $0.messages?.count ?? 0 }.max() ?? 0
        }
        return result
    }

    private var metricsMap: [String: ContactMetrics] {
        let counts = rawCounts
        let maxCount = counts.values.max() ?? 0
        let now = Date()
        var map: [String: ContactMetrics] = [:]
        for user in contacts {
            let count = counts[user.id] ?? 0
            let score: CGFloat = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
            let lastMsg = ((user.chats?.allObjects as? [Chat]) ?? [])
                .compactMap { $0.lastMessageTime }
                .max()
            let recency: ContactMetrics.Recency
            if let t = lastMsg {
                let age = now.timeIntervalSince(t)
                recency = age < 86_400 ? .fresh : age < 604_800 ? .recent : .none
            } else {
                recency = .none
            }
            map[user.id] = ContactMetrics(frequencyScore: score, recency: recency)
        }
        return map
    }

    var body: some View {
        GeometryReader { geo in
            let engine  = HoneycombLayoutEngine(contacts: contacts, canvasSize: geo.size)
            let metrics = metricsMap

            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: geo.size.width, height: geo.size.height)

                ForEach(engine.items) { item in
                    DesktopContactNode(
                        user:         item.user,
                        cellSize:     engine.cellSize,
                        metrics:      metrics[item.user.id] ?? .zero,
                        canvasPos:    item.position,
                        canvasScale:  canvasScale,
                        canvasOffset: canvasOffset,
                        screenSize:   screenSize,
                        onMessage:    { onMessage(item.user) },
                        onRemove:     { onRemove(item.user) }
                    )
                    .position(item.position)
                }
            }
        }
    }
}

// MARK: - DesktopContactNode

private struct DesktopContactNode: View {
    @ObservedObject var user: User
    let cellSize:     CGFloat
    let metrics:      ContactMetrics
    let canvasPos:    CGPoint
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    let screenSize:   CGSize
    var onMessage:    () -> Void
    var onRemove:     () -> Void

    @State private var showPopover = false
    @State private var isHovered   = false

    private var effectiveSize: CGFloat {
        let f = 0.55 + 0.20 * metrics.frequencyScore
        return cellSize / 0.74 * f
    }

    var body: some View {
        ZStack {
            if let data = user.avatarData, let img = PlatformImage(data: data) {
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
                lineWidth: isHovered ? 2 : 1.5
            )
        )
        .scaleEffect(proximityScale)
        .opacity(proximityOpacity)
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
                Text(NSLocalizedString("synaps_prune_action", comment: ""))
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
            .environment(\.managedObjectContext, user.managedObjectContext ?? NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType))
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
        user.isBlocked ? Color.red.opacity(0.55) : Color.CT.textDim.opacity(0.5)
    }

}

// MARK: - DesktopNodePopover

/// Compact contact card shown in a popover anchored to the node.
/// Actions: message → opens chat in detail column; remove → prune with confirmation.
private struct DesktopNodePopover: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var user: User
    var onMessage: () -> Void
    var onRemove:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header: avatar + name
            VStack(spacing: 8) {
                avatarView
                    .padding(.top, 16)

                Text(user.displayName)
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.text)

                Text("@\(user.username)")
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            // Actions
            VStack(spacing: 0) {
                popoverButton(
                    label: "[\(NSLocalizedString("message", comment: "").uppercased()) →]",
                    color: Color.CT.accent
                ) {
                    onMessage()
                }

                Rectangle().fill(Color.CT.noise.opacity(0.5)).frame(height: 1)
                    .padding(.horizontal, 12)

                popoverButton(
                    label: "[✕ \(NSLocalizedString("synaps_prune_action", comment: "").uppercased())]",
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
            if let data = user.avatarData, let img = PlatformImage(data: data) {
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

    private func popoverButton(label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(CTFont.regular(12))
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
