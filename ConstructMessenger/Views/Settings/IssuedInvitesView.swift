//
//  IssuedInvitesView.swift
//  Construct Messenger
//
//  Created 2026-08-15.
//
//  What this device handed out and has not yet expired.
//
//  Copied links can be revoked here. QR sittings cannot, and the hint at the top says so
//  rather than leaving the asymmetry to be noticed: a sitting holds up to
//  `ttlSeconds / qrRotateIntervalSeconds` capabilities — 1440 today — so the honest button
//  behind it is 1440 requests. Spec §4 (a QR gets its own short TTL) is what changes that.
//

import SwiftUI
import Combine

struct IssuedInvitesView: View {
    @Environment(\.dismiss) private var dismiss

    private var journal = InviteJournal.shared

    /// Recomputed on a slow tick so a row does not sit there claiming time it no longer
    /// has. Nothing here animates, so the interval is about honesty, not smoothness.
    @State private var now = Date()

    /// The act whose revoke button was tapped, awaiting confirmation. Revoking cannot be
    /// undone and the other side learns nothing — their link simply stops working — so the
    /// step is worth one tap.
    @State private var pendingRevoke: InviteIssuance?
    @State private var revokingID: UUID?
    /// Outcome of the last attempt. Cleared when another is started.
    @State private var notice: (text: String, isError: Bool)?

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

                    // Why only some rows offer revocation. An asymmetry nobody can account
                    // for reads as a bug in the rows that lack the button.
                    Text("> " + NSLocalizedString("issued_invites_revoke_scope", comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, CTLayout.edgePad)

                    if let notice {
                        Text("> \(notice.text)")
                            .font(CTFont.regular(11))
                            .foregroundStyle(notice.isError ? Color.CT.danger : Color.CT.accent)
                            .padding(.horizontal, CTLayout.edgePad)
                            .accessibilityIdentifier(A11y.IssuedInvites.notice)
                    }

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
        // Every pushed settings screen hides the system bar and draws its own CTNavBar;
        // without this the two stack up and the screen shows two back buttons.
        .hideSystemNavBar()
        .onReceive(tick) { _ in now = Date() }
        .onAppear { now = Date() }
        .confirmationDialog(
            NSLocalizedString("invite_revoke_confirm_title", comment: ""),
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("revoke", comment: ""), role: .destructive) {
                if let act = pendingRevoke { revoke(act) }
                pendingRevoke = nil
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {
                pendingRevoke = nil
            }
        } message: {
            Text(NSLocalizedString("invite_revoke_confirm_message", comment: ""))
        }
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
        HStack(spacing: SecuritySettingsLayout.rowContentSpacing) {
            Image(systemName: act.kind == .link ? "link" : "qrcode")
                .font(.system(size: SettingsShareLayout.actionIconSize, weight: .regular))
                .foregroundStyle(Color.CT.text)
                .frame(width: IssuedInvitesLayout.iconColumnWidth)

            VStack(alignment: .leading, spacing: IssuedInvitesLayout.rowMetaSpacing) {
                Text(label(for: act))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.text)
                Text(remainingText(for: act))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
            }
            // Scoped to the label, not to the row. An identifier on a container overwrites
            // its descendants': while this sat on the whole HStack it stamped the revoke
            // button too, and `A11y.IssuedInvites.revoke(id)` matched nothing on a live
            // simulator — the one control a scenario needs to reach was unaddressable.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11y.IssuedInvites.act(act.id))

            Spacer(minLength: CTLayout.inlinePad)

            if InviteRevocationDecision.canRevoke(kind: act.kind) {
                revokeButton(for: act)
            }
        }
        .padding(.horizontal, SecuritySettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SecuritySettingsLayout.compactRowVerticalPadding)
    }

    @ViewBuilder
    private func revokeButton(for act: InviteIssuance) -> some View {
        if revokingID == act.id {
            ProgressView()
                .tint(Color.CT.textDim)
                .padding(.horizontal, ContactQRCodeLayout.refreshButtonHorizontalPadding)
        } else {
            Button { pendingRevoke = act } label: {
                Text(NSLocalizedString("revoke", comment: "").lowercased())
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.danger)
                    .padding(.horizontal, ContactQRCodeLayout.refreshButtonHorizontalPadding)
                    .padding(.vertical, ContactQRCodeLayout.refreshButtonVerticalPadding)
                    .background(
                        CTShape.card()
                            .fill(Color.CT.bgMsg)
                            .overlay(
                                CTShape.card().strokeBorder(
                                    Color.CT.danger.opacity(ContactQRCodeLayout.refreshButtonStrokeOpacity),
                                    lineWidth: ContactQRCodeLayout.refreshButtonStrokeWidth
                                )
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(revokingID != nil)
            .accessibilityLabel(NSLocalizedString("revoke", comment: ""))
            .accessibilityIdentifier(A11y.IssuedInvites.revoke(act.id))
        }
    }

    // MARK: - Revoking

    private func revoke(_ act: InviteIssuance) {
        revokingID = act.id
        notice = nil
        Task {
            let outcome = await InviteRevocation.revoke(act, now: Date())
            revokingID = nil

            // The row leaves only on a confirmed answer. An unconfirmed attempt keeps it,
            // because the capability may still be perfectly good and this list is the only
            // place the user can see that.
            if InviteRevocationDecision.removesFromJournal(outcome) {
                journal.forget(actID: act.id)
            }
            now = Date()

            switch outcome {
            case .revoked:
                notice = (NSLocalizedString("invite_revoked", comment: ""), false)
            case .alreadyUsed:
                notice = (NSLocalizedString("invite_already_used", comment: ""), false)
            case .unconfirmed:
                notice = (NSLocalizedString("invite_revoke_unconfirmed", comment: ""), true)
            }
        }
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
