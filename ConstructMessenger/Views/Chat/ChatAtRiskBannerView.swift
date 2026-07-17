import SwiftUI

/// Non-blocking informational banner shown when the session with the contact was established
/// via a DEGRADED (stale-SPK) init — the contact had been offline too long to rotate their keys.
/// The session is still authentic and usable; this just tells the user the keys aren't fresh and
/// will be refreshed automatically once the contact comes back online. See the
/// `stale-peer-reachability` decision record.
struct ChatAtRiskBannerView: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            HStack(spacing: CTLayout.chromeGap) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(CTFont.regular(16))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("session_at_risk_title"))
                        .font(CTFont.bold(12))
                        .foregroundStyle(Color.CT.text)
                    Text(LocalizedStringKey("session_at_risk_subtitle"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTLayout.chromeGap)
            .background(Color.orange.opacity(0.08))
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
            .padding(.horizontal, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
