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
    /// Rows sit a little further apart than pure hex packing (√3/2): the names near the centre
    /// are drawn under their circles and must clear the ring below. Only those are named (the
    /// lens fades the rest), which is what lets this stay close to 1 and the cloud round — at
    /// 1.35, with every contact named, it read as rows of a grid.
    static let rowStretch: CGFloat = 1.15

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

// MARK: - Lens

/// The Apple Watch lens over the cloud (TODO 74): a contact keeps its size near the middle of
/// the visible area and shrinks towards the edge, and is pulled in as it goes so the cloud reads
/// as one round shape rather than as the grid it is laid out on. It works on where a contact is
/// on screen, so panning moves contacts through the lens, as on the watch.
///
/// The lens is an oval filling the visible area, not a circle: a phone's visible area is twice
/// as tall as it is wide, and a circle as wide as the screen left the top and bottom thirds
/// empty. Distances are measured in units of the radius along each axis, so "how far out" is
/// one number, `rim`: 0 in the middle, 1 at the oval's edge.
struct SynapsLens {
    /// Half the oval's width and height.
    let radii: CGSize
    /// The size of a contact at the rim, relative to one in the middle.
    static let rimScale: CGFloat = 0.35
    /// The opacity of a contact at the rim. The outermost ring is pressed against the edge,
    /// where its circles crowd; dimming it keeps it from reading as a border of its own.
    static let rimOpacity: Double = 0.35

    /// How far out a contact `rim` units away is drawn: unchanged near the middle, pulled in ever
    /// harder towards the edge, never past it.
    static func drawnRim(_ rim: CGFloat) -> CGFloat { tanh(rim) }

    /// Where a point at `screen` is drawn, and how far out (0…1) that is.
    func draw(_ screen: CGPoint, centre: CGPoint) -> (point: CGPoint, rim: CGFloat) {
        guard radii.width > 0, radii.height > 0 else { return (screen, 0) }
        let ux = (screen.x - centre.x) / radii.width
        let uy = (screen.y - centre.y) / radii.height
        let rim = hypot(ux, uy)
        guard rim > 0 else { return (screen, 0) }
        let drawn = Self.drawnRim(rim)
        let k = drawn / rim
        return (CGPoint(x: centre.x + ux * k * radii.width, y: centre.y + uy * k * radii.height), drawn)
    }

    /// Size at a drawn rim distance: 1 in the inner third, `rimScale` at the edge.
    static func scale(atRim rim: CGFloat) -> CGFloat {
        1 - (1 - rimScale) * smoothstep(0.3, 1, rim)
    }

    /// The circle fades only in the outermost band.
    static func opacity(atRim rim: CGFloat) -> Double {
        1 - (1 - rimOpacity) * Double(smoothstep(0.82, 0.98, rim))
    }

    /// Only the middle contact and the ring around it are named. Measured in points on screen,
    /// not in rim units: the oval is narrow across, so by rim the first ring's left and right
    /// neighbours counted as further out than its upper ones and lost their names, while the
    /// second ring's upper and lower ones kept theirs half-drawn over the circles below.
    static func labelOpacity(atDistance d: CGFloat) -> Double {
        let pitch = SynapsCloudLayout.pitch
        // The first ring is drawn at most ~1.07 pitches out, the second from ~1.48 (measured with
        // thirty contacts); the fade sits between them.
        return Double(1 - smoothstep(pitch * 1.15, pitch * 1.4, d))
    }

    static func smoothstep(_ lo: CGFloat, _ hi: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = Swift.min(Swift.max((x - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
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
