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
/// When `collapsed = true` all dots converge to center and fade out.
///
/// Uses `TimelineView` for CADisplayLink-accurate 60/120Hz rendering.
struct ConvergingSignalView: View {
    let progress: Double   // 0.0 → 1.0
    var dotColor: Color = Color("SecondColor")
    /// Set to true to trigger the collapse-to-dot exit animation
    var collapsed: Bool = false

    // MARK: - Configuration

    private enum Config {
        static let dotCount: Int = 28
        static let animationSpeed: Double = 1.5
        static let amplitudeFraction: Double = 0.40
        static let settleCutoff: Double = 0.04
        static let dotBlendBack: Double = 0.08
        static let dotBlendFront: Double = 0.02
        static let envelopeBlendFront: Double = 0.06
        static let settledRadius: CGFloat = 2.2
        static let unsettledRadius: CGFloat = 2.5
        static let dotRadiusVariance: CGFloat = 0.5
        static let settledAlpha: Double = 0.92
        static let unsettledAlphaBase: Double = 0.25
        static let unsettledAlphaRange: Double = 0.45
        static let flickerPhaseScale: Double = 0.7
        static let flickerTickScale: Double = 0.9
        static let lineOpacity: Double = 0.22
        static let lineWidth: CGFloat = 1.2
        static let wave2Freq: Double = 2.3
        static let wave3Freq: Double = 3.7
        static let wave2Weight: Double = 0.5
        static let wave3Weight: Double = 0.25
        static let waveNorm: Double = 1.0 + wave2Weight + wave3Weight
        /// Duration of the collapse-to-center animation
        static let collapseDuration: Double = 0.55
    }

    // MARK: - State

    @State private var phase1: [Double] = (0..<Config.dotCount).map { _ in .random(in: 0..<2 * .pi) }
    @State private var phase2: [Double] = (0..<Config.dotCount).map { _ in .random(in: 0..<2 * .pi) }
    @State private var phase3: [Double] = (0..<Config.dotCount).map { _ in .random(in: 0..<2 * .pi) }
    @State private var startDate = Date()
    /// 0 = normal, 1 = fully collapsed to center dot
    @State private var collapseT: Double = 0.0

    // MARK: - Body

    var body: some View {
        TimelineView(.animation) { timeline in
            let tick = timeline.date.timeIntervalSince(startDate) * Config.animationSpeed
            Canvas { context, size in
                let cx = size.width / 2.0
                let cy = size.height / 2.0
                let spacing = size.width / CGFloat(Config.dotCount - 1)
                let maxAmp = size.height * Config.amplitudeFraction

                let points: [CGPoint] = (0..<Config.dotCount).map { i in
                    let xNormal = CGFloat(i) * spacing
                    // During collapse, x also converges to center
                    let x = xNormal + (cx - xNormal) * CGFloat(collapseT)
                    let y = yForDot(i: i, cy: cy, maxAmp: maxAmp, tick: tick,
                                    collapseT: collapseT)
                    return CGPoint(x: x, y: y)
                }

                let globalAlpha = 1.0 - collapseT * 0.85

                // Polyline fades out during collapse
                var line = Path()
                line.move(to: points[0])
                for i in 1..<Config.dotCount { line.addLine(to: points[i]) }
                context.stroke(line,
                               with: .color(dotColor.opacity(Config.lineOpacity * globalAlpha)),
                               lineWidth: Config.lineWidth)

                // Dots converge and merge into one bright point
                for i in 0..<Config.dotCount {
                    let norm = Double(i) / Double(Config.dotCount - 1)
                    let settled = norm < progress - Config.settleCutoff
                    let blend = smoothstep(norm,
                                           lo: progress - Config.dotBlendBack,
                                           hi: progress + Config.dotBlendFront)
                    // During collapse all dots grow toward center dot size
                    let baseR: CGFloat = settled
                        ? Config.settledRadius
                        : Config.unsettledRadius - Config.dotRadiusVariance * CGFloat(blend)
                    let r = baseR + (Config.settledRadius * 1.4 - baseR) * CGFloat(collapseT)
                    let baseAlpha: Double = settled
                        ? Config.settledAlpha
                        : Config.unsettledAlphaBase
                            + Config.unsettledAlphaRange
                            * abs(sin(phase1[i] * Config.flickerPhaseScale
                                      + tick * Config.flickerTickScale))
                    let alpha = (baseAlpha + (1.0 - baseAlpha) * collapseT) * globalAlpha
                    context.fill(
                        Path(ellipseIn: CGRect(x: points[i].x - r, y: points[i].y - r,
                                               width: r * 2, height: r * 2)),
                        with: .color(dotColor.opacity(alpha))
                    )
                }
            }
        }
        .onAppear { startDate = Date() }
        .onChange(of: collapsed) { _, isCollapsed in
            guard isCollapsed else { return }
            withAnimation(.easeInOut(duration: Config.collapseDuration)) {
                collapseT = 1.0
            }
        }
    }

    // MARK: - Helpers

    private func yForDot(i: Int, cy: CGFloat, maxAmp: CGFloat,
                         tick: Double, collapseT: Double) -> CGFloat {
        let norm = Double(i) / Double(Config.dotCount - 1)
        guard norm >= progress - Config.settleCutoff else {
            // Settled dots also pull toward cy during collapse
            return cy
        }
        let envelope = smoothstep(norm,
                                  lo: progress - Config.settleCutoff,
                                  hi: progress + Config.envelopeBlendFront)
        let w1 = sin(phase1[i] + tick)
        let w2 = sin(phase2[i] + tick * Config.wave2Freq) * Config.wave2Weight
        let w3 = sin(phase3[i] + tick * Config.wave3Freq) * Config.wave3Weight
        let wave = (w1 + w2 + w3) / Config.waveNorm
        let normalY = cy + maxAmp * CGFloat(envelope) * CGFloat(wave)
        // Collapse: lerp toward center line
        return normalY + (cy - normalY) * CGFloat(collapseT)
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
