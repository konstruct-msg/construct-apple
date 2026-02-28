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

    var nodeCount: Int       = 48
    var maxEdgeDistance: CGFloat = 160
    var nodeOpacity: Double  = 0.50
    var edgeBaseOpacity: Double = 0.16
    var color: Color         = Color.AppBrand.second

    @State private var nodes: [LatticeNode] = []

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, _ in
                    guard !nodes.isEmpty else { return }

                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let positions = nodes.map { $0.position(at: t) }
                    let resolved = context.resolve(color)

                    // Edges (drawn first, underneath nodes)
                    for i in 0 ..< positions.count {
                        for j in (i + 1) ..< positions.count {
                            let a = positions[i]
                            let b = positions[j]
                            let dist = hypot(b.x - a.x, b.y - a.y)
                            guard dist < maxEdgeDistance else { continue }

                            let strength = 1.0 - dist / maxEdgeDistance
                            let opacity  = edgeBaseOpacity * strength * strength

                            var path = Path()
                            path.move(to: a)
                            path.addLine(to: b)
                            context.stroke(
                                path,
                                with: .color(resolved.color.opacity(opacity)),
                                lineWidth: 0.6
                            )
                        }
                    }

                    // Nodes
                    let r: CGFloat = 1.8
                    for pos in positions {
                        let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(resolved.color.opacity(nodeOpacity))
                        )
                    }
                }
            }
            .onAppear { rebuildNodes(in: proxy.size) }
            .onChange(of: proxy.size) { _, newSize in rebuildNodes(in: newSize) }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Node Generation

    private func rebuildNodes(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let cols = Int(ceil(sqrt(Double(nodeCount) * size.width / size.height)))
        let rows = Int(ceil(Double(nodeCount) / Double(cols)))
        let cellW = size.width  / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        var built: [LatticeNode] = []
        for row in 0 ..< rows {
            for col in 0 ..< cols {
                guard built.count < nodeCount else { break }

                let jitterX = CGFloat.random(in: -0.45 ... 0.45) * cellW
                let jitterY = CGFloat.random(in: -0.45 ... 0.45) * cellH
                let ox = (CGFloat(col) + 0.5) * cellW + jitterX
                let oy = (CGFloat(row) + 0.5) * cellH + jitterY

                built.append(LatticeNode(
                    origin:    CGPoint(x: ox, y: oy),
                    phaseX:    Double.random(in: 0 ..< .pi * 2),
                    phaseY:    Double.random(in: 0 ..< .pi * 2),
                    speed:     Double.random(in: 0.006 ... 0.014), // ~1–2 min full cycle
                    amplitude: CGFloat.random(in: 5 ... 12)         // 5–12 pt drift radius
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
