import SwiftUI

/// Isolated full-screen sandbox for LiquidLogoView — used to dial in timings,
/// amplitudes and haptics before wiring the animation into SplashView or onboarding.
/// Tap anywhere to replay. Dismiss with the close button.
struct LiquidLogoShowcaseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var replay: Int = 0
    @State private var hapticsOn: Bool = true
    @State private var logoSize: CGFloat = 240

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise(rows: 48, cols: 24).ignoresSafeArea()
                .opacity(0.35)

            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("liquid_logo.title", comment: ""),
                    showBack: true,
                    isModal: true,
                    backAction: { dismiss() }
                )

                Spacer()

                LiquidLogoView(
                    size: logoSize,
                    enableHaptics: hapticsOn,
                    replayToken: replay
                )

                Spacer()

                VStack(spacing: 14) {
                    HStack(spacing: 16) {
                        Text(NSLocalizedString("liquid_logo.size", comment: ""))
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                        Slider(value: $logoSize, in: 96...320)
                            .tint(Color.CT.accent)
                        Text("\(Int(logoSize))")
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.text)
                            .frame(width: 36, alignment: .trailing)
                    }

                    Toggle(isOn: $hapticsOn) {
                        Text(NSLocalizedString("liquid_logo.haptics", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.text)
                    }
                    .tint(Color.CT.accent)

                    Button {
                        replay &+= 1
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 18))
                            Text(NSLocalizedString("liquid_logo.replay", comment: ""))
                                .font(CTFont.regular(13))
                        }
                        .foregroundColor(Color.CT.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(
                            Rectangle().stroke(Color.CT.accent.opacity(0.5), lineWidth: 1)
                        )
                    }

                    Text(NSLocalizedString("liquid_logo.hint", comment: ""))
                        .font(CTFont.regular(10))
                        .foregroundColor(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { replay &+= 1 }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }
}

#Preview {
    LiquidLogoShowcaseView()
}
