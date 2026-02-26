//
//  ConvergingSignalView.swift
//  Construct Messenger
//
//  A self-contained animation component. Takes `progress` (0→1) as input
//  and renders a chaotic jagged polyline that settles left-to-right into a
//  straight center line — like a signal locking in.
//
//  Has no dependency on ViewModels, services or data models.
//  Internal @State is purely presentational (random phases, start date).
//

import SwiftUI

/// Dots start chaotic (jagged polyline), settle left-to-right into the center
/// line as `progress` increases from 0→1 — like a signal locking in.
///
/// Uses `TimelineView` for CADisplayLink-accurate 60/120Hz rendering.
/// The unsettled segment uses multiple overlapping sine waves (chaos).
/// Connecting line is a raw polyline (no smoothing) → visible jagged shape.
struct ConvergingSignalView: View {
    let progress: Double   // 0.0 → 1.0
    var dotColor: Color = Color("SecondColor")

    // MARK: - Configuration

    private enum Config {
        // How many dots in the line
        static let dotCount: Int = 28
        // Timeline tick multiplier — controls overall animation speed
        static let animationSpeed: Double = 1.5
        // Max vertical oscillation as a fraction of the view height (stays within frame after normalization)
        static let amplitudeFraction: Double = 0.40

        // Settle front: dots whose norm is below (progress - settleCutoff) snap to center
        static let settleCutoff: Double = 0.04
        // Blend window around the settle front used for dot radius/opacity
        static let dotBlendBack: Double = 0.08   // progress - this
        static let dotBlendFront: Double = 0.02  // progress + this
        // Blend window used for the amplitude envelope in yForDot
        static let envelopeBlendFront: Double = 0.06  // progress + this

        // Dot radii
        static let settledRadius: CGFloat = 2.2
        static let unsettledRadius: CGFloat = 2.5
        static let dotRadiusVariance: CGFloat = 0.5   // shrinks unsettledRadius by blend * this

        // Dot opacity
        static let settledAlpha: Double = 0.92
        static let unsettledAlphaBase: Double = 0.25
        static let unsettledAlphaRange: Double = 0.45
        // Phase/tick scale for the unsettled dot flicker
        static let flickerPhaseScale: Double = 0.7
        static let flickerTickScale: Double = 0.9

        // Connecting polyline
        static let lineOpacity: Double = 0.22
        static let lineWidth: CGFloat = 1.2

        // Wave frequencies (multiples of base) and amplitude weights
        static let wave2Freq: Double = 2.3
        static let wave3Freq: Double = 3.7
        static let wave2Weight: Double = 0.5
        static let wave3Weight: Double = 0.25
        // Normalizer: max |w1+w2+w3| = 1 + wave2Weight + wave3Weight
        static let waveNorm: Double = 1.0 + wave2Weight + wave3Weight
    }

    // MARK: - State

    @State private var phase1: [Double] = (0..<Config.dotCount).map { _ in .random(in: 0..<2 * .pi) }
    @State private var phase2: [Double] = (0..<Config.dotCount).map { _ in .random(in: 0..<2 * .pi) }
    @State private var phase3: [Double] = (0..<Config.dotCount).map { _ in .random(in: 0..<2 * .pi) }
    @State private var startDate = Date()

    // MARK: - Body

    var body: some View {
        TimelineView(.animation) { timeline in
            let tick = timeline.date.timeIntervalSince(startDate) * Config.animationSpeed
            Canvas { context, size in
                let cy = size.height / 2.0
                let spacing = size.width / CGFloat(Config.dotCount - 1)
                let maxAmp = size.height * Config.amplitudeFraction

                let points: [CGPoint] = (0..<Config.dotCount).map { i in
                    CGPoint(
                        x: CGFloat(i) * spacing,
                        y: yForDot(i: i, cy: cy, maxAmp: maxAmp, tick: tick)
                    )
                }

                // Jagged polyline — no Bezier, intentionally angular
                var line = Path()
                line.move(to: points[0])
                for i in 1..<Config.dotCount { line.addLine(to: points[i]) }
                context.stroke(line, with: .color(dotColor.opacity(Config.lineOpacity)),
                               lineWidth: Config.lineWidth)

                // Dots
                for i in 0..<Config.dotCount {
                    let norm = Double(i) / Double(Config.dotCount - 1)
                    let settled = norm < progress - Config.settleCutoff
                    let blend = smoothstep(norm,
                                           lo: progress - Config.dotBlendBack,
                                           hi: progress + Config.dotBlendFront)
                    let r: CGFloat = settled
                        ? Config.settledRadius
                        : Config.unsettledRadius - Config.dotRadiusVariance * CGFloat(blend)
                    let alpha: Double = settled
                        ? Config.settledAlpha
                        : Config.unsettledAlphaBase
                            + Config.unsettledAlphaRange
                            * abs(sin(phase1[i] * Config.flickerPhaseScale
                                      + tick * Config.flickerTickScale))
                    context.fill(
                        Path(ellipseIn: CGRect(x: points[i].x - r, y: points[i].y - r,
                                               width: r * 2, height: r * 2)),
                        with: .color(dotColor.opacity(alpha))
                    )
                }
            }
        }
        .onAppear {
            startDate = Date()
        }
    }

    // MARK: - Helpers

    private func yForDot(i: Int, cy: CGFloat, maxAmp: CGFloat, tick: Double) -> CGFloat {
        let norm = Double(i) / Double(Config.dotCount - 1)
        guard norm >= progress - Config.settleCutoff else { return cy }
        // Uniform amplitude ahead of the front: 0 on settled side, 1 past transition
        let envelope = smoothstep(norm,
                                  lo: progress - Config.settleCutoff,
                                  hi: progress + Config.envelopeBlendFront)
        let w1 = sin(phase1[i] + tick)
        let w2 = sin(phase2[i] + tick * Config.wave2Freq) * Config.wave2Weight
        let w3 = sin(phase3[i] + tick * Config.wave3Freq) * Config.wave3Weight
        // Normalize so combined waves never exceed [-1, 1] → dots stay inside frame
        let wave = (w1 + w2 + w3) / Config.waveNorm
        return cy + maxAmp * CGFloat(envelope) * CGFloat(wave)
    }

    private func smoothstep(_ x: Double, lo: Double, hi: Double) -> Double {
        let t = max(0, min(1, (x - lo) / max(0.001, hi - lo)))
        return t * t * (3 - 2 * t)
    }
}

#Preview {
    VStack(spacing: 32) {
        ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { p in
            VStack(spacing: 4) {
                ConvergingSignalView(progress: p)
                    .frame(height: 60)
                Text("progress: \(p, specifier: "%.1f")")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
    .padding()
}
