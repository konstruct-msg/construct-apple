//
//  SynapsLayoutEngine.swift
//  Construct Messenger
//
//  Shared layout primitives for the Synaps node cloud.
//  Used by SynapsView (iOS) and DesktopSynapsView (macOS).
//

import SwiftUI
import CoreData

// MARK: - Layout engine

/// Lays the Synaps cloud out as a hexagonal spiral from the centre, as the Apple Watch home
/// screen does (TODO 74): one contact in the middle, then rings of 6, 12, 18, … The most active
/// contact (`ContactMetrics.frequencyScore`) takes the centre and activity falls off ring by ring,
/// so the people someone talks to are where the eye lands. Until 2026-10-08 this was a rectangle
/// four wide, filled in list order.
///
/// Positions are in points around the cloud's centre at scale 1 — the canvas size plays no part,
/// so the same contacts keep the same places whatever the screen. Fitting is `fitScale(in:)`.
struct SynapsCloudLayout {
    /// Centre-to-centre distance of two neighbours in a row, at scale 1.
    static let pitch: CGFloat = 96
    /// Rows sit further apart than pure hex packing (√3/2): a name of up to two lines is drawn
    /// under each avatar and must clear the row below, the centre one at its largest (frequency
    /// and proximity both up). At 1.08, with one line, the centre name touched the ring under it.
    static let rowStretch: CGFloat = 1.35

    struct Item: Identifiable {
        let id: String
        let user: ContactRecord
        /// Offset from the cloud's centre, in points at scale 1.
        let position: CGPoint
    }

    let items: [Item]

    init(contacts: [ContactRecord], metrics: [String: ContactMetrics]) {
        let ordered = Self.order(contacts, metrics: metrics)
        let points = Self.spiral(count: ordered.count)
        items = zip(ordered, points).map { Item(id: $0.id, user: $0, position: $1) }
    }

    /// Most active first; ties keep a stable order by id so a contact does not wander between
    /// launches while nothing about them changed.
    static func order(_ contacts: [ContactRecord], metrics: [String: ContactMetrics]) -> [ContactRecord] {
        contacts.sorted { a, b in
            let sa = metrics[a.id]?.frequencyScore ?? 0
            let sb = metrics[b.id]?.frequencyScore ?? 0
            return sa != sb ? sa > sb : a.id < b.id
        }
    }

    /// The first `count` cells of a hexagonal spiral, centre first, ring by ring.
    static func spiral(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        // Axial directions for a pointy-top grid, in walking order around a ring.
        let directions = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
        var cells = [(q: 0, r: 0)]
        var ring = 1
        while cells.count < count {
            // A ring starts `ring` steps out along direction 4 and walks its six sides.
            var q = directions[4].0 * ring, r = directions[4].1 * ring
            for side in 0..<6 {
                for _ in 0..<ring {
                    cells.append((q, r))
                    q += directions[side].0
                    r += directions[side].1
                }
            }
            ring += 1
        }
        return cells.prefix(count).map(point)
    }

    static func point(_ cell: (q: Int, r: Int)) -> CGPoint {
        CGPoint(
            x: pitch * (CGFloat(cell.q) + CGFloat(cell.r) / 2),
            y: pitch * (3.0.squareRoot() / 2) * rowStretch * CGFloat(cell.r)
        )
    }

    /// Half the extent of the cloud on each axis, one cell's margin included.
    var halfExtent: CGSize {
        let xs = items.map { abs($0.position.x) }, ys = items.map { abs($0.position.y) }
        return CGSize(
            width: (xs.max() ?? 0) + Self.pitch / 2,
            height: (ys.max() ?? 0) + Self.pitch / 2
        )
    }

    /// The zoom at which the whole cloud fits `visible` with some room, never above 1.
    func fitScale(in visible: CGSize) -> CGFloat {
        let half = halfExtent
        guard half.width > 0, half.height > 0, visible.width > 0, visible.height > 0 else { return 1 }
        let fit = Swift.min(visible.width / (2 * half.width), visible.height / (2 * half.height))
        return Swift.min(fit * 0.92, 1)
    }
}

// MARK: - Contact activity metrics

/// Locally-derived activity signals — no server data, no social graph.
/// Used for ambient density on the Synaps cloud (P1 spatial track): place, size, ring, badge.
struct ContactMetrics {
    /// Normalised message count across all contacts: 0 = fewest/none, 1 = most active.
    let frequencyScore: CGFloat
    /// Time-based glow tier (last message age).
    let recency: Recency
    /// Sum of unread counts on chats with this contact (local Core Data).
    let unreadCount: Int

    enum Recency {
        case fresh     // last message < 24 h
        case recent    // last message < 7 days
        case none
    }

    static let zero = ContactMetrics(frequencyScore: 0, recency: .none, unreadCount: 0)

    /// Stroke for the node ring — unread wins over recency; blocked handled by the view.
    var activityRingColor: Color {
        if unreadCount > 0 { return Color.CT.accent }
        switch recency {
        case .fresh:  return Color.CT.accent.opacity(0.90)
        case .recent: return Color.CT.accent.opacity(0.45)
        case .none:   return Color.CT.textDim.opacity(0.50)
        }
    }

    var activityRingLineWidth: CGFloat {
        unreadCount > 0 ? 2.25 : (recency == .fresh ? 2.0 : 1.5)
    }

    /// Soft outer halo for “live” nodes (unread or fresh).
    var showsActivityHalo: Bool {
        unreadCount > 0 || recency == .fresh
    }
}

// MARK: - ZoomableCloud

/// Wraps any content with simultaneous pinch-to-zoom and drag-to-pan gestures.
/// Works on iOS (touch) and macOS (trackpad).
/// Exposes `scale` and `offset` as bindings so child views can read the current
/// transform for custom effects (e.g. proximity-based local scaling).
struct ZoomableCloud<Content: View>: View {
    @Binding var scale:  CGFloat
    @Binding var offset: CGSize
    /// The point zoom grows from, as a fraction of the canvas — the middle of what is visible,
    /// which is not the canvas middle when the canvas runs under the bars.
    var anchor: UnitPoint = .center
    var minScale: CGFloat = 0.25
    var maxScale: CGFloat = 3.0
    @ViewBuilder var content: () -> Content

    @State private var gestureScale:    CGFloat = 1
    @State private var lastTranslation: CGSize  = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content()
                    .scaleEffect(scale, anchor: anchor)
                    .offset(offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .highPriorityGesture(magnificationGesture(size: proxy.size))
            .simultaneousGesture(dragGesture(size: proxy.size))
        }
    }

    // MARK: Gestures

    private func magnificationGesture(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / gestureScale
                gestureScale = value
                if abs(1 - delta) > 0.005 {
                    let newScale = scale * delta
                    scale = min(max(newScale, minScale), maxScale)
                }
            }
            .onEnded { _ in
                gestureScale = 1
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    clampOffset(size: size)
                }
            }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let diff = CGSize(
                    width:  value.translation.width  - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height
                )
                offset = CGSize(
                    width:  offset.width  + diff.width,
                    height: offset.height + diff.height
                )
                lastTranslation = value.translation
            }
            .onEnded { _ in
                lastTranslation = .zero
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    clampOffset(size: size)
                }
            }
    }

    /// Allow panning to see edge contacts (extra 20% margin) but prevent canvas
    /// from flying completely off screen.
    private func clampOffset(size: CGSize) {
        let extraX = size.width  * 0.20
        let extraY = size.height * 0.20
        let maxX   = Swift.max(0, (size.width  * scale - size.width)  / 2 + extraX)
        let maxY   = Swift.max(0, (size.height * scale - size.height) / 2 + extraY)
        offset = CGSize(
            width:  min(max(offset.width,  -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}

extension ContactMetrics {
    /// Each contact's metrics from their chats, found by the peer id each chat names — one fetch
    /// for all of them. Shared by Synapses on iOS and on the Desktop, which each kept a copy
    /// walking `User.chats`; the chats are still Core Data, the contacts no longer are.
    @MainActor
    static func byContact(_ ids: [String], in context: NSManagedObjectContext, now: Date = Date()) -> [String: ContactMetrics] {
        guard !ids.isEmpty else { return [:] }
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "otherUser.id IN %@", ids)
        var chatsByPeer: [String: [Chat]] = [:]
        for chat in (try? context.fetch(req)) ?? [] {
            guard let peer = chat.otherUser?.id else { continue }
            chatsByPeer[peer, default: []].append(chat)
        }
        let counts = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, (chatsByPeer[id] ?? []).map { $0.messages?.count ?? 0 }.max() ?? 0)
        })
        let maxCount = counts.values.max() ?? 0
        var map: [String: ContactMetrics] = [:]
        for id in ids {
            let chats = chatsByPeer[id] ?? []
            let count = counts[id] ?? 0
            let recency: Recency
            if let last = chats.compactMap(\.lastMessageTime).max() {
                let age = now.timeIntervalSince(last)
                recency = age < 86_400 ? .fresh : age < 604_800 ? .recent : .none
            } else {
                recency = .none
            }
            map[id] = ContactMetrics(
                frequencyScore: maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0,
                recency: recency,
                unreadCount: chats.reduce(0) { $0 + Int($1.unreadCount) }
            )
        }
        return map
    }
}
