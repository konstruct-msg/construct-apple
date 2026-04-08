//
//  SynapsLayoutEngine.swift
//  Construct Messenger
//
//  Shared layout primitives for the Synaps node cloud.
//  Used by SynapsView (iOS) and DesktopSynapsView (macOS).
//

import SwiftUI

// MARK: - Layout engine

/// Computes deterministic honeycomb positions for a flat contact list.
/// Even rows: `wideCols` circles. Odd rows: `wideCols - 1` circles, offset right
/// by half a cell — classic hex packing.
struct HoneycombLayoutEngine {
    let contacts:   [User]
    let canvasSize: CGSize
    let wideCols = 4

    var cellWidth: CGFloat { canvasSize.width / CGFloat(wideCols) }
    var cellSize:  CGFloat { cellWidth * 0.74 }
    var vStep:     CGFloat { cellWidth * 0.866 }  // √3/2
    var totalHeight: CGFloat { CGFloat(rawRows.count) * vStep + cellWidth * 0.6 }

    /// Zoom level that fits the whole grid with ~12% breathing room.
    var initialScale: CGFloat {
        guard totalHeight > 0, canvasSize.height > 0 else { return 1.0 }
        return Swift.min(canvasSize.height / totalHeight * 0.88, 1.0)
    }

    struct Item: Identifiable {
        let id: String
        let user: User
        let position: CGPoint
    }

    /// Hex positions translated so the grid bounding-box centre = canvas centre.
    var items: [Item] {
        let raw = rawItems
        guard !raw.isEmpty else { return [] }
        let xs = raw.map(\.position.x), ys = raw.map(\.position.y)
        let gcx = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        let gcy = ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
        let dx = canvasSize.width  / 2 - gcx
        let dy = canvasSize.height / 2 - gcy
        return raw.map {
            Item(id: $0.id, user: $0.user,
                 position: CGPoint(x: $0.position.x + dx, y: $0.position.y + dy))
        }
    }

    private var rawItems: [Item] {
        var result: [Item] = []
        for (rowIdx, row) in rawRows.enumerated() {
            let xShift = rowIdx % 2 == 1 ? cellWidth / 2 : 0
            for (colIdx, user) in row.enumerated() {
                let cx = xShift + CGFloat(colIdx) * cellWidth + cellWidth / 2
                let cy = CGFloat(rowIdx) * vStep + cellWidth / 2
                result.append(Item(id: user.id, user: user, position: CGPoint(x: cx, y: cy)))
            }
        }
        return result
    }

    private var rawRows: [[User]] {
        var result: [[User]] = []
        var idx = 0, rowIdx = 0
        while idx < contacts.count {
            let n = rowIdx % 2 == 0 ? wideCols : wideCols - 1
            result.append(Array(contacts[idx ..< Swift.min(idx + n, contacts.count)]))
            idx += n; rowIdx += 1
        }
        return result
    }
}

// MARK: - Contact activity metrics

/// Locally-derived activity signals — no server data, no social graph.
struct ContactMetrics {
    /// Normalised message count across all contacts: 0 = fewest/none, 1 = most active.
    let frequencyScore: CGFloat
    /// Time-based glow tier.
    let recency: Recency

    enum Recency {
        case fresh     // last message < 24 h
        case recent    // last message < 7 days
        case none
    }

    static let zero = ContactMetrics(frequencyScore: 0, recency: .none)
}

// MARK: - ZoomableCloud

/// Wraps any content with simultaneous pinch-to-zoom and drag-to-pan gestures.
/// Works on iOS (touch) and macOS (trackpad).
/// Exposes `scale` and `offset` as bindings so child views can read the current
/// transform for custom effects (e.g. proximity-based local scaling).
struct ZoomableCloud<Content: View>: View {
    @Binding var scale:  CGFloat
    @Binding var offset: CGSize
    var minScale: CGFloat = 0.25
    var maxScale: CGFloat = 3.0
    @ViewBuilder var content: () -> Content

    @State private var gestureScale:    CGFloat = 1
    @State private var lastTranslation: CGSize  = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content()
                    .scaleEffect(scale, anchor: .center)
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
