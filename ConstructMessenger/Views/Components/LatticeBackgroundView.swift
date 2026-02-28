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
    let speed: Double       // drift speed (subtle variation per node)
    let amplitude: CGFloat  // max drift radius

    func position(at t: Double) -> CGPoint {
        CGPoint(
            x: origin.x + amplitude * CGFloat(sin(t * speed + phaseX)),
            y: origin.y + amplitude * CGFloat(cos(t * speed + phaseY))
        )
    }
}

// MARK: - View

struct LatticeBackgroundView: View {

    // Configuration
    var nodeCount: Int = 48
    var maxEdgeDistance: CGFloat = 160
    var nodeOpacity: Double = 0.55
    var edgeBaseOpacity: Double = 0.18
    var color: Color = Color.AppBrand.second

    @State private var nodes: [LatticeNode] = []
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                guard !nodes.isEmpty else { return }

                let t = timeline.date.timeIntervalSinceReferenceDate
                let positions = nodes.map { $0.position(at: t) }
                let resolved = context.resolve(color)

                // Draw edges first (underneath nodes)
                for i in 0 ..< positions.count {
                    for j in (i + 1) ..< positions.count {
                        let a = positions[i]
                        let b = positions[j]
                        let dist = hypot(b.x - a.x, b.y - a.y)
                        guard dist < maxEdgeDistance else { continue }

                        // Fade out as distance approaches threshold
                        let strength = 1.0 - dist / maxEdgeDistance
                        let opacity = edgeBaseOpacity * strength * strength

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

                // Draw nodes
                let nodeRadius: CGFloat = 1.8
                for pos in positions {
                    let rect = CGRect(
                        x: pos.x - nodeRadius,
                        y: pos.y - nodeRadius,
                        width: nodeRadius * 2,
                        height: nodeRadius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(resolved.color.opacity(nodeOpacity))
                    )
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                if newSize != canvasSize {
                    canvasSize = newSize
                    rebuildNodes(in: newSize)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Node Generation

    private func rebuildNodes(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        // Distribute nodes using a jittered grid for even coverage,
        // then add random variation so it looks irregular — not a grid.
        let cols = Int(ceil(sqrt(Double(nodeCount) * size.width / size.height)))
        let rows = Int(ceil(Double(nodeCount) / Double(cols)))
        let cellW = size.width  / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        var built: [LatticeNode] = []
        for row in 0 ..< rows {
            for col in 0 ..< cols {
                guard built.count < nodeCount else { break }

                // Cell center + random jitter up to 45% of cell size
                let jitterX = CGFloat.random(in: -0.45 ... 0.45) * cellW
                let jitterY = CGFloat.random(in: -0.45 ... 0.45) * cellH
                let ox = (CGFloat(col) + 0.5) * cellW + jitterX
                let oy = (CGFloat(row) + 0.5) * cellH + jitterY

                built.append(LatticeNode(
                    origin:    CGPoint(x: ox, y: oy),
                    phaseX:    Double.random(in: 0 ..< .pi * 2),
                    phaseY:    Double.random(in: 0 ..< .pi * 2),
                    speed:     Double.random(in: 0.12 ... 0.28),
                    amplitude: CGFloat.random(in: 12 ... 28)
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
