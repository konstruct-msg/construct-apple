//
//  LatticeBackgroundView.swift
//  Construct Messenger
//
//  CT-style ASCII matrix background — a static grid of terminal characters
//  that slowly mutates over time. Barely visible watermark effect.
//

import SwiftUI
import Combine

// MARK: - CTMatrixBackground

struct CTMatrixBackground: View {
    private static let chars: [Character] = Array("01ABCDEFabcdef><[]{}|~.")

    @State private var grid: [[Character]] = []

    let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, canvasSize in
            guard !grid.isEmpty else { return }
            let cellW: CGFloat = 36
            let cellH: CGFloat = 36
            for (ri, row) in grid.enumerated() {
                for (ci, ch) in row.enumerated() {
                    context.draw(
                        Text(String(ch))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.CT.text.opacity(0.05)),
                        at: CGPoint(x: CGFloat(ci) * cellW + cellW * 0.5,
                                    y: CGFloat(ri) * cellH + cellH * 0.5)
                    )
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { buildGrid(size: geo.size) }
                    .onChange(of: geo.size) { _, s in buildGrid(size: s) }
            }
        )
        .onReceive(timer) { _ in mutateSome() }
        .allowsHitTesting(false)
    }

    private func buildGrid(size: CGSize) {
        guard size.width > 0 else { return }
        let cellSize: CGFloat = 36
        let c = max(1, Int(size.width / cellSize) + 1)
        let r = max(1, Int(size.height / cellSize) + 1)
        grid = (0..<r).map { _ in (0..<c).map { _ in Self.chars.randomElement()! } }
    }

    private func mutateSome() {
        guard !grid.isEmpty else { return }
        let r = grid.count, c = grid[0].count
        let count = max(1, (r * c) / 20)  // ~5%
        for _ in 0..<count {
            let ri = Int.random(in: 0..<r)
            let ci = Int.random(in: 0..<c)
            grid[ri][ci] = Self.chars.randomElement()!
        }
    }
}

// MARK: - Deprecated alias

@available(*, deprecated, renamed: "CTMatrixBackground")
typealias LatticeBackgroundView = CTMatrixBackground

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        CTMatrixBackground()
    }
    .frame(width: 390, height: 844)
}
