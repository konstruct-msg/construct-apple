import SwiftUI

struct ChatFloodBannerView: View {
    let isVisible: Bool
    let onAllow: () -> Void
    let onBlock: () -> Void

    var body: some View {
        if isVisible {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(CTFont.regular(16))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("flood_banner_title"))
                        .font(.footnote.weight(.semibold))
                    Text(LocalizedStringKey("flood_banner_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onAllow) {
                    Image(systemName: "chevron.right")
                        .font(CTFont.regular(12))
                        .foregroundStyle(.orange)
                }

                Button(action: onBlock) {
                    Image(systemName: "nosign")
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.danger)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .bottom)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
