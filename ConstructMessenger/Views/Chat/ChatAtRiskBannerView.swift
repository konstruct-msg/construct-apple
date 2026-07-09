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
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(CTFont.regular(16))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("session_at_risk_title"))
                        .font(.footnote.weight(.semibold))
                    Text(LocalizedStringKey("session_at_risk_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .bottom)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
