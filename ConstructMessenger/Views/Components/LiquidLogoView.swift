import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Procedural metaball logo: two vertical ellipses appear, drift together, fuse through
/// a liquid bridge, then settle into the Konstruct silhouette with a slow surface-tension
/// pulse. Optional haptics fire at proximity, merge, and on each loop pulse.
///
/// Pure Canvas / SwiftUI — no raster fallback. The final shape is the metaball itself
/// (per Standalone preview decision), not a cross-fade into the static PDF asset.
struct LiquidLogoView: View {
    var size: CGFloat = 240
    var enableHaptics: Bool = true
    /// Stable token — changing it restarts the animation from t=0.
    var replayToken: AnyHashable = 0

    @State private var startDate = Date()
    @State private var hapticTask: Task<Void, Never>?

    private enum Const {
        // ── Intro phase boundaries on tIntro ∈ [0, 1] ───────────────────────────
        static let appearEnd:    Double = 0.20   // both drops visible
        static let approachEnd:  Double = 0.45   // drops close to final x
        static let bridgeEnd:    Double = 0.65   // metaball fusion complete
        static let settleEnd:    Double = 0.85   // spring damping done
        // → 0.85–1.00 = first loop pulse begins blending in

        static let introDuration: Double = 2.8
        static let pulsePeriod:   Double = 2.4   // loop surface-tension breath

        // ── Final geometry in unit space [0,1] (measured off Konstruct-Logo) ───
        // Left drop sits slightly higher and is a touch fatter; right drop hangs
        // lower with a marginally narrower waist. The diagonal axis is what gives
        // the logo its tilted personality — keep it.
        static let leftCenterFinal  = CGPoint(x: 0.38, y: 0.42)
        static let rightCenterFinal = CGPoint(x: 0.62, y: 0.58)
        static let leftRadiusFinal  = CGSize(width: 0.205, height: 0.345)
        static let rightRadiusFinal = CGSize(width: 0.190, height: 0.340)

        // Pre-approach separation (added to each side along the diagonal).
        static let initialSeparation: CGFloat = 0.18

        // ── Metaball tuning ─────────────────────────────────────────────────────
        // Blur must be large enough to bridge at final distance but small enough
        // that the waist visibly cinches. Threshold tuned together with blur.
        static let blurFraction:   CGFloat = 0.060
        static let alphaThreshold: Double  = 0.58

        // ── Wobble during approach (drops "feeling" each other) ────────────────
        static let wobbleFreq:      Double  = 11.0
        static let wobbleAmpX:      CGFloat = 0.008
        static let wobbleAmpY:      CGFloat = 0.011

        // ── Spring overshoot at merge ──────────────────────────────────────────
        static let overshootAmp:    CGFloat = 0.022
        static let overshootFreq:   Double  = 14.0
        static let overshootDecay:  Double  = 6.5

        // ── Surface tension breathing (loop) ───────────────────────────────────
        static let pulseAmplitude:  Double  = 0.022

        // ── Haptic moment percentages within intro ─────────────────────────────
        static let hapticProximityT: Double = 0.22
        static let hapticMergeT:     Double = 0.58
        // Loop micro-pulse cadence (one impact per visual breath).
        static let hapticLoopGap:    Double = pulsePeriod
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startDate))
            let tIntro  = min(elapsed / Const.introDuration, 1.0)
            let loopT   = max(0, elapsed - Const.introDuration)

            let blobSpecs = makeBlobs(tIntro: tIntro, loopT: loopT)

            // Mercury gradient masked by the procedural metaball silhouette.
            LinearGradient(
                colors: [
                    Color.CT.text.opacity(0.98),
                    Color.CT.text.opacity(0.74),
                    Color.CT.text.opacity(0.62)
                ],
                startPoint: .topLeading,
                endPoint:   .bottomTrailing
            )
            .frame(width: size, height: size)
            .mask {
                Canvas { ctx, canvasSize in
                    let s = canvasSize.width
                    ctx.addFilter(.alphaThreshold(min: Const.alphaThreshold, color: .white))
                    ctx.addFilter(.blur(radius: s * Const.blurFraction))
                    ctx.drawLayer { layer in
                        for blob in blobSpecs {
                            let cx = blob.center.x * s
                            let cy = blob.center.y * s
                            let rx = blob.radius.width  * s
                            let ry = blob.radius.height * s
                            let rect = CGRect(
                                x: cx - rx, y: cy - ry,
                                width: rx * 2, height: ry * 2
                            )
                            layer.opacity = blob.opacity
                            layer.fill(Path(ellipseIn: rect), with: .color(.white))
                        }
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            startDate = Date()
            scheduleHaptics()
        }
        .onDisappear {
            hapticTask?.cancel()
            hapticTask = nil
        }
        .onChange(of: replayToken) { _, _ in
            startDate = Date()
            scheduleHaptics()
        }
    }

    // MARK: - Geometry

    private struct BlobSpec {
        let center: CGPoint
        let radius: CGSize
        let opacity: Double
    }

    private func makeBlobs(tIntro: Double, loopT: Double) -> [BlobSpec] {
        let appear   = smoothstep(tIntro, 0,                  Const.appearEnd)
        let approach = smoothstep(tIntro, Const.appearEnd,    Const.approachEnd)
        let bridge   = smoothstep(tIntro, Const.approachEnd,  Const.bridgeEnd)
        let settle   = smoothstep(tIntro, Const.bridgeEnd,    Const.settleEnd)

        // Pre-approach offsets along the diagonal — left drifts up-left,
        // right drifts down-right (matches the final tilt).
        let leftInit = CGPoint(
            x: Const.leftCenterFinal.x - Const.initialSeparation * 0.85,
            y: Const.leftCenterFinal.y - Const.initialSeparation * 0.20
        )
        let rightInit = CGPoint(
            x: Const.rightCenterFinal.x + Const.initialSeparation * 0.85,
            y: Const.rightCenterFinal.y + Const.initialSeparation * 0.20
        )

        // Wobble: only meaningful while approaching but not yet bridged.
        let wobbleWindow = approach * (1 - bridge)
        let wPhase = tIntro * Const.wobbleFreq
        let wobbleX = CGFloat(sin(wPhase)            * wobbleWindow) * Const.wobbleAmpX
        let wobbleY = CGFloat(cos(wPhase * 0.83)     * wobbleWindow) * Const.wobbleAmpY

        // Spring overshoot at merge — decaying sine. Active around bridgeEnd → settleEnd.
        let springT  = max(0, tIntro - Const.bridgeEnd)
        let envelope = exp(-springT * Const.overshootDecay) * (bridge - settle)
        let overshoot = CGFloat(sin(springT * Const.overshootFreq) * envelope) * Const.overshootAmp

        let leftCx  = lerp(leftInit.x,  Const.leftCenterFinal.x,  approach) + wobbleX  + overshoot
        let leftCy  = lerp(leftInit.y,  Const.leftCenterFinal.y,  approach) + wobbleY
        let rightCx = lerp(rightInit.x, Const.rightCenterFinal.x, approach) - wobbleX  - overshoot
        let rightCy = lerp(rightInit.y, Const.rightCenterFinal.y, approach) - wobbleY

        // Surface-tension breathing — engages after settle. Counter-phased blobs
        // give the liquid an off-kilter "alive" feel rather than synchronous swell.
        let pulseAmp = Const.pulseAmplitude * settle
        let pulseA   = sin(loopT / Const.pulsePeriod * 2 * .pi)
        let pulseB   = sin(loopT / Const.pulsePeriod * 2 * .pi + .pi / 2)

        let lRx = Const.leftRadiusFinal.width  * CGFloat(1.0 + pulseA * pulseAmp)
        let lRy = Const.leftRadiusFinal.height * CGFloat(1.0 - pulseA * pulseAmp * 0.5)
        let rRx = Const.rightRadiusFinal.width  * CGFloat(1.0 + pulseB * pulseAmp)
        let rRy = Const.rightRadiusFinal.height * CGFloat(1.0 - pulseB * pulseAmp * 0.5)

        return [
            BlobSpec(
                center:  CGPoint(x: leftCx,  y: leftCy),
                radius:  CGSize(width: lRx,  height: lRy),
                opacity: Double(appear)
            ),
            BlobSpec(
                center:  CGPoint(x: rightCx, y: rightCy),
                radius:  CGSize(width: rRx,  height: rRy),
                opacity: Double(appear)
            )
        ]
    }

    private func smoothstep(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        let t = max(0, min(1, (x - lo) / max(0.0001, hi - lo)))
        return t * t * (3 - 2 * t)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    // MARK: - Haptics

    private func scheduleHaptics() {
        hapticTask?.cancel()
        guard enableHaptics else { return }
        #if os(iOS)
        let proxAt  = Const.introDuration * Const.hapticProximityT
        let mergeAt = Const.introDuration * Const.hapticMergeT
        let loopStart = Const.introDuration

        hapticTask = Task { @MainActor in
            // 1. Proximity — soft, low intensity (drops "feel" each other).
            try? await sleep(proxAt)
            if Task.isCancelled { return }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.45)

            // 2. Merge — rigid, the moment the bridge snaps closed.
            try? await sleep(mergeAt - proxAt)
            if Task.isCancelled { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.85)

            // 3. Loop — quiet surface tension micro-pulses, one per breath.
            try? await sleep(loopStart - mergeAt)
            while !Task.isCancelled {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.22)
                try? await sleep(Const.hapticLoopGap)
            }
        }
        #endif
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

#Preview("LiquidLogo · 240pt") {
    ZStack {
        Color.CT.bg.ignoresSafeArea()
        LiquidLogoView(size: 240, enableHaptics: false)
    }
}

#Preview("LiquidLogo · sizes") {
    ZStack {
        Color.CT.bg.ignoresSafeArea()
        VStack(spacing: 40) {
            LiquidLogoView(size: 96,  enableHaptics: false)
            LiquidLogoView(size: 160, enableHaptics: false)
            LiquidLogoView(size: 240, enableHaptics: false)
        }
    }
}
