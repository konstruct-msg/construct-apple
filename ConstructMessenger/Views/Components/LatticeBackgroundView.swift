//
//  LatticeBackgroundView.swift
//  Construct Messenger
//
//  Animated lattice background — random nodes connected by proximity edges.
//  A visual nod to lattice-based cryptography (CRYSTALS-Kyber / ML-KEM).
//

import SwiftUI

// MARK: - Node

private struct LatticeNode {
    let origin: CGPoint     // rest position
    let phaseX: Double      // sin phase for horizontal drift
    let phaseY: Double      // cos phase for vertical drift
    let speed: Double       // drift speed — very slow, barely perceptible
    let amplitude: CGFloat  // max drift radius (pixels)

    func position(at t: Double) -> CGPoint {
        CGPoint(
            x: origin.x + amplitude * CGFloat(sin(t * speed + phaseX)),
            y: origin.y + amplitude * CGFloat(cos(t * speed + phaseY))
        )
    }
}

// MARK: - View

struct LatticeBackgroundView: View {

    var nodeCount: Int           = 72
    var maxEdgeDistance: CGFloat = 240
    var nodeOpacity: Double      = 0.60
    var edgeBaseOpacity: Double  = 0.48
    var color: Color             = Color.AppBrand.second
    /// Extra padding beyond the visible canvas on each side — nodes placed here
    /// are invisible (Canvas clips them) but their edges enter the frame from the
    /// border, giving the illusion of a much larger network extending off-screen.
    var overflow: CGFloat        = 120

    @State private var nodes: [LatticeNode] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                // Lazy init: if nodes are empty but Canvas has a real size, generate them
                if nodes.isEmpty {
                    if size.width > 0 {
                        DispatchQueue.main.async { rebuildNodes(in: size) }
                    }
                    return
                }

                let t = timeline.date.timeIntervalSinceReferenceDate
                let positions = nodes.map { $0.position(at: t) }

                // Edges (drawn first, underneath nodes)
                for i in 0 ..< positions.count {
                    for j in (i + 1) ..< positions.count {
                        let a = positions[i]
                        let b = positions[j]
                        let dist = hypot(b.x - a.x, b.y - a.y)
                        guard dist < maxEdgeDistance else { continue }

                        // Linear falloff — remains visible across full distance range
                        let strength = 1.0 - dist / maxEdgeDistance
                        let opacity  = edgeBaseOpacity * strength

                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        context.stroke(
                            path,
                            with: .color(color.opacity(opacity)),
                            lineWidth: 0.7
                        )
                    }
                }

                // Nodes
                let r: CGFloat = 2.0
                for pos in positions {
                    let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(color.opacity(nodeOpacity))
                    )
                }
            }
        }
        // Use a hidden GeometryReader in background to measure size without affecting layout
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rebuildNodes(in: proxy.size) }
                    .onChange(of: proxy.size) { _, newSize in rebuildNodes(in: newSize) }
            }
        )
        .allowsHitTesting(false)
    }

    // MARK: - Node Generation

    private func rebuildNodes(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        // Extend grid beyond visible bounds so edges enter from all sides
        let extW = size.width  + overflow * 2
        let extH = size.height + overflow * 2

        let cols = Int(ceil(sqrt(Double(nodeCount) * extW / extH)))
        let rows = Int(ceil(Double(nodeCount) / Double(cols)))
        let cellW = extW / CGFloat(cols)
        let cellH = extH / CGFloat(rows)

        var built: [LatticeNode] = []
        for row in 0 ..< rows {
            for col in 0 ..< cols {
                guard built.count < nodeCount else { break }

                let jitterX = CGFloat.random(in: -0.30 ... 0.30) * cellW
                let jitterY = CGFloat.random(in: -0.30 ... 0.30) * cellH
                // Shift back by overflow so the extended grid is centred on the canvas
                let ox = (CGFloat(col) + 0.5) * cellW + jitterX - overflow
                let oy = (CGFloat(row) + 0.5) * cellH + jitterY - overflow

                built.append(LatticeNode(
                    origin:    CGPoint(x: ox, y: oy),
                    phaseX:    Double.random(in: 0 ..< .pi * 2),
                    phaseY:    Double.random(in: 0 ..< .pi * 2),
                    speed:     Double.random(in: 0.09 ... 0.25),
                    amplitude: CGFloat.random(in: 5 ... 12)
                ))
            }
        }
        nodes = built
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        LatticeBackgroundView()
    }
    .frame(width: 390, height: 844)
}
