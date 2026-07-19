import SwiftUI

struct ChatFloodBannerView: View {
    let isVisible: Bool
    let onAllow: () -> Void
    let onBlock: () -> Void

    var body: some View {
        if isVisible {
            HStack(spacing: CTLayout.chromeGap) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(CTFont.regular(16))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("flood_banner_title"))
                        .font(CTFont.bold(12))
                        .foregroundStyle(Color.CT.text)
                    Text(LocalizedStringKey("flood_banner_subtitle"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }

                Spacer(minLength: 0)

                Button(action: onAllow) {
                    Image(systemName: "chevron.right")
                        .font(CTFont.regular(12))
                        .foregroundStyle(.orange)
                        .frame(width: CTLayout.hitTarget * 0.75, height: CTLayout.hitTarget * 0.75)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onBlock) {
                    Image(systemName: "nosign")
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.danger)
                        .frame(width: CTLayout.hitTarget * 0.75, height: CTLayout.hitTarget * 0.75)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTLayout.chromeGap)
            .background(Color.orange.opacity(0.08))
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
            .padding(.horizontal, ChatUIConstants.Shell.auxOuterPad)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
