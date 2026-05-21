//
//  ConstructAppLoadingPrototypeView.swift
//  Construct Messenger
//
//  Design-only loading screen prototype based on:
//  /Users/maximeliseyev/Code/construct-docs/logo_animation.md
//

import SwiftUI

struct ConstructAppLoadingPrototypeView: View {

    enum Behavior: String, CaseIterable {
        case clean
        case delayedMerge
        case recoil

        var previewTitle: String {
            switch self {
            case .clean: return "Loading / clean"
            case .delayedMerge: return "Loading / delayed merge"
            case .recoil: return "Loading / recoil"
            }
        }
    }

    var behavior: Behavior = .clean

    private let cycleDuration: TimeInterval = 3.8

    private var stageTitles: [String] {
        [
            NSLocalizedString("app_loading_stage_transport", comment: ""),
            NSLocalizedString("app_loading_stage_identity", comment: ""),
            NSLocalizedString("app_loading_stage_streams", comment: ""),
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let motion = motionState(at: timeline.date)
                let logoSize = min(proxy.size.width * 0.62, 260)

                VStack(spacing: 0) {
                    Spacer(minLength: 72)

                    VStack(spacing: 28) {
                        LiquidInkLogoView(
                            behavior: behavior,
                            mergeProgress: motion.mergeProgress,
                            cycleProgress: motion.cycleProgress,
                            logoReveal: motion.logoReveal
                        )
                        .frame(width: logoSize, height: logoSize)

                        VStack(spacing: 8) {
                            Text(NSLocalizedString("construct_app_name", comment: "").uppercased())
                                .font(CTFont.bold(18))
                                .tracking(6)
                                .foregroundStyle(Color.CT.text)

                            Text(NSLocalizedString("app_loading_state", comment: "").uppercased())
                                .font(CTFont.regular(11))
                                .tracking(3)
                                .foregroundStyle(Color.CT.accentDim)
                        }

                        LoadingStagesPanel(
                            titles: stageTitles,
                            mergeProgress: motion.mergeProgress,
                            pulse: motion.pulse
                        )
                        .frame(maxWidth: 320)
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ctBackground()
    }

    private func motionState(at date: Date) -> MotionState {
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
        let cycleProgress = CGFloat(elapsed / cycleDuration)
        let mergeProgress = mergeProgress(for: cycleProgress)
        let logoReveal = smoothstep(cycleProgress, 0.62, 0.96)
        let pulse = 0.58 + 0.42 * sin(cycleProgress * .pi * 2.0)

        return MotionState(
            cycleProgress: cycleProgress,
            mergeProgress: mergeProgress,
            logoReveal: logoReveal,
            pulse: pulse
        )
    }

    private func mergeProgress(for cycleProgress: CGFloat) -> CGFloat {
        switch behavior {
        case .clean:
            return smoothstep(cycleProgress, 0.08, 0.86)
        case .delayedMerge:
            return smoothstep(cycleProgress, 0.18, 0.90)
        case .recoil:
            let base = smoothstep(cycleProgress, 0.08, 0.82)
            let recoilWindow = smoothstep(cycleProgress, 0.72, 1.0)
            let recoil = sin(cycleProgress * .pi * 5.0) * 0.04 * recoilWindow
            return max(0, min(1, base - recoil))
        }
    }

    private func smoothstep(_ value: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        let denominator = max(0.001, end - start)
        let t = max(0, min(1, (value - start) / denominator))
        return t * t * (3 - 2 * t)
    }

    private struct MotionState {
        let cycleProgress: CGFloat
        let mergeProgress: CGFloat
        let logoReveal: CGFloat
        let pulse: CGFloat
    }
}

private struct LiquidInkLogoView: View {
    let behavior: ConstructAppLoadingPrototypeView.Behavior
    let mergeProgress: CGFloat
    let cycleProgress: CGFloat
    let logoReveal: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Canvas { context, canvasSize in
                    drawMetaballs(in: &context, size: canvasSize)
                }

                CTLogoView(size: size * 0.64, color: Color.CT.accent.opacity(0.22 + Double(logoReveal) * 0.14))
                    .blur(radius: 14)
                    .opacity(0.35 + Double(logoReveal) * 0.35)
                    .blendMode(.plusLighter)

                CTLogoView(size: size * 0.58, color: Color.CT.text)
                    .opacity(Double(logoReveal) * 0.24)
            }
            .drawingGroup()
        }
    }

    private func drawMetaballs(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let bridgeProgress = smoothstep(mergeProgress, behavior == .delayedMerge ? 0.34 : 0.18, 0.80)
        let settleProgress = smoothstep(mergeProgress, 0.68, 1.0)
        let shimmer = 0.5 + 0.5 * sin(cycleProgress * .pi * 2.0)

        let recoil: CGFloat
        switch behavior {
        case .recoil:
            recoil = sin(settleProgress * .pi * 3.0) * (1 - settleProgress) * 10
        default:
            recoil = 0
        }

        let wobble = (1 - mergeProgress) * 8
        let breathing = sin(cycleProgress * .pi * 6.0) * settleProgress * 2.0

        let leftX = center.x - interpolate(from: 94, to: 44, progress: mergeProgress) + recoil
        let rightX = center.x + interpolate(from: 94, to: 40, progress: mergeProgress) - recoil * 0.85
        let leftY = center.y - 28 + sin(cycleProgress * .pi * 2.4) * wobble * 0.28 + breathing
        let rightY = center.y + 24 - sin(cycleProgress * .pi * 2.1 + 0.7) * wobble * 0.24 - breathing * 0.6

        let leftRect = CGRect(
            x: leftX - 68,
            y: leftY - 118,
            width: 136,
            height: 236
        )
        let rightRect = CGRect(
            x: rightX - 60,
            y: rightY - 102,
            width: 120,
            height: 208
        )
        let bridgeRect = CGRect(
            x: center.x - interpolate(from: 14, to: 70, progress: bridgeProgress),
            y: center.y - 18 + breathing * 0.6,
            width: interpolate(from: 28, to: 140, progress: bridgeProgress),
            height: interpolate(from: 10, to: 44, progress: bridgeProgress)
        )

        context.drawLayer { layer in
            layer.addFilter(.alphaThreshold(min: 0.52, color: Color.CT.text))
            layer.addFilter(.blur(radius: 24))

            layer.fill(Path(ellipseIn: leftRect), with: .color(.white))
            layer.fill(Path(ellipseIn: rightRect), with: .color(.white))
            layer.fill(
                Path(roundedRect: bridgeRect, cornerRadius: bridgeRect.height / 2),
                with: .color(.white)
            )
        }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 24))
            layer.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - 96,
                    y: center.y - 84,
                    width: 192,
                    height: 168
                )),
                with: .color(Color.CT.accent.opacity(0.16 + Double(logoReveal) * 0.12))
            )
        }

        let highlightRect = CGRect(
            x: center.x - 70 + shimmer * 18,
            y: center.y - 88,
            width: 90,
            height: 54
        )

        context.fill(
            Path(ellipseIn: highlightRect),
            with: .linearGradient(
                Gradient(colors: [
                    .white.opacity(0.72),
                    .white.opacity(0.08),
                    .clear,
                ]),
                startPoint: CGPoint(x: highlightRect.minX, y: highlightRect.minY),
                endPoint: CGPoint(x: highlightRect.maxX, y: highlightRect.maxY)
            )
        )
    }

    private func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func smoothstep(_ value: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        let denominator = max(0.001, end - start)
        let t = max(0, min(1, (value - start) / denominator))
        return t * t * (3 - 2 * t)
    }
}

private struct LoadingStagesPanel: View {
    let titles: [String]
    let mergeProgress: CGFloat
    let pulse: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                let isComplete = mergeProgress >= completionThresholds[index]
                let isActive = !isComplete && activeStageIndex == index

                HStack(spacing: 12) {
                    Text(symbol(isComplete: isComplete, isActive: isActive))
                        .font(CTFont.bold(11))
                        .foregroundStyle(symbolColor(isComplete: isComplete, isActive: isActive))
                        .opacity(isActive ? Double(pulse) : 1)

                    Text(title.uppercased())
                        .font(CTFont.regular(12))
                        .tracking(1.6)
                        .foregroundStyle(textColor(isComplete: isComplete, isActive: isActive))

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if index < titles.count - 1 {
                    Rectangle()
                        .fill(Color.CT.noise)
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.CT.bg)
                        .frame(height: 3)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.CT.accentDim, Color.CT.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(18, proxy.size.width * mergeProgress), height: 3)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.CT.outMsgBg.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.CT.noise, lineWidth: 0.5)
        )
    }

    private let completionThresholds: [CGFloat] = [0.28, 0.62, 0.92]

    private var activeStageIndex: Int {
        switch mergeProgress {
        case ..<0.28:
            return 0
        case ..<0.62:
            return 1
        default:
            return 2
        }
    }

    private func symbol(isComplete: Bool, isActive: Bool) -> String {
        if isComplete { return CTSymbol.ok }
        if isActive { return CTSymbol.loading }
        return "[ ]"
    }

    private func symbolColor(isComplete: Bool, isActive: Bool) -> Color {
        if isComplete || isActive {
            return Color.CT.accent
        }
        return Color.CT.textDim
    }

    private func textColor(isComplete: Bool, isActive: Bool) -> Color {
        if isComplete {
            return Color.CT.text
        }
        if isActive {
            return Color.CT.accentDim
        }
        return Color.CT.textDim
    }
}

#Preview("Loading / clean") {
    ConstructAppLoadingPrototypeView(behavior: .clean)
        .preferredColorScheme(.dark)
}

#Preview("Loading / delayed merge") {
    ConstructAppLoadingPrototypeView(behavior: .delayedMerge)
        .preferredColorScheme(.dark)
}

#Preview("Loading / recoil") {
    ConstructAppLoadingPrototypeView(behavior: .recoil)
        .preferredColorScheme(.dark)
}
