//
//  IssuedInvitesView.swift
//  Construct Messenger
//
//  Created 2026-08-15.
//
//  What this device handed out and has not yet expired.
//
//  Read-only for now. Revocation is a wiring job, not a design one — `RevokeInvite` has
//  worked server-side all along (it pre-burns the `jti` with a retention derived to
//  outlive the invite) and iOS simply never called it. It lands next; the rows are shaped
//  so a trailing action fits without rearranging them.
//

import SwiftUI

struct IssuedInvitesView: View {
    @Environment(\.dismiss) private var dismiss

    private var journal = InviteJournal.shared

    /// Recomputed on a slow tick so a row does not sit there claiming time it no longer
    /// has. Nothing here animates, so the interval is about honesty, not smoothness.
    @State private var now = Date()

    private let tick = Timer.publish(
        every: IssuedInvitesLayout.refreshIntervalSeconds, on: .main, in: .common
    ).autoconnect()

    private var acts: [InviteIssuance] { journal.live(at: now) }

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("issued_invites", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
            Rectangle().fill(Color.CT.noise).frame(height: 1)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: CTLayout.edgePad) {
                    // The scope is in the copy on purpose. This list is per-device by
                    // construction, so an empty one means "this device issued nothing
                    // recently", never "the account has nothing outstanding" — and the two
                    // render identically unless the sentence says which it is.
                    Text(
                        "> " + String(
                            format: NSLocalizedString("issued_invites_hint_fmt", comment: ""),
                            InviteConfig.ttlDescription
                        )
                    )
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.top, CTLayout.edgePad)

                    if acts.isEmpty {
                        emptyState
                    } else {
                        CTSectionGroup {
                            ForEach(Array(acts.enumerated()), id: \.element.id) { index, act in
                                if index > 0 { CTSep(style: .thin) }
                                row(for: act)
                            }
                        }
                    }

                    Spacer(minLength: CTLayout.edgePad)
                }
            }
        }
        .ctBackground()
        .onReceive(tick) { _ in now = Date() }
        .onAppear { now = Date() }
    }

    private var emptyState: some View {
        Text(
            String(
                format: NSLocalizedString("issued_invites_empty_fmt", comment: ""),
                InviteConfig.ttlDescription
            )
        )
        .font(CTFont.regular(12))
        .foregroundStyle(Color.CT.textDim)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, IssuedInvitesLayout.emptyVerticalPadding)
        .accessibilityIdentifier(A11y.IssuedInvites.empty)
    }

    private func row(for act: InviteIssuance) -> some View {
        CTSettingsRow(
            label: label(for: act),
            value: remainingText(for: act),
            icon: act.kind == .link ? "link" : "qrcode",
            valueColor: Color.CT.textDim
        )
        .accessibilityIdentifier(A11y.IssuedInvites.act(act.id))
    }

    /// A link is one capability and reads as one; a QR sitting reads as the number of
    /// codes it put on screen, because that is what revoking it will have to cover.
    private func label(for act: InviteIssuance) -> String {
        let time = act.startedAt.formatted(date: .omitted, time: .shortened)
        switch act.kind {
        case .link:
            return "\(NSLocalizedString("issued_invite_link", comment: "").uppercased()) · \(time)"
        case .qrSession:
            let count = act.liveMints(at: now).count
            let kind = String(
                format: NSLocalizedString("issued_invite_qr_fmt", comment: ""), count
            )
            return "\(kind.uppercased()) · \(time)"
        }
    }

    private func remainingText(for act: InviteIssuance) -> String {
        let seconds = max(0, act.expiresAt().timeIntervalSince(now))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        let value = formatter.string(from: seconds) ?? ""
        return String(format: NSLocalizedString("issued_invite_expires_fmt", comment: ""), value)
    }
}

#if DEBUG
#Preview {
    IssuedInvitesView()
        .preferredColorScheme(.dark)
}
#endif
