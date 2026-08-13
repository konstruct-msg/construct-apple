//
//  MultiInviteView.swift
//  Construct Messenger
//
//  Created 2026-08-13.
//
//  Why this screen exists:
//
//  An invite is burned by its first redeemer. One link pasted into a group chat works
//  for exactly one person, and the other four are told the invite was already used —
//  which reads as a broken link, not as a rule. The workaround already existed (tap
//  "copy" once per friend, since every tap mints a fresh invite) but nothing in the UI
//  said so, and a workaround nobody can discover is not a feature.
//
//  This is deliberately NOT reusable-invite mode. Every link here is the same v4
//  one-time signed capability with the same TTL and the same jti burn; there are simply
//  N of them, one per person. Multi-use invites need a security model that
//  `decisions/invite-two-modes-deferred.md` says must be written before any code —
//  first-contact material per redeemer, spam funnel, revoke — and none of that is
//  needed to invite six people you know.
//

import SwiftUI

struct MultiInviteView: View {
    @Environment(\.dismiss) private var dismiss

    let userId: String

    /// One generated invite. `id` is only for `ForEach`; the link itself is the payload.
    private struct GeneratedInvite: Identifiable {
        let id = UUID()
        let link: String
        var copied = false
    }

    @State private var invites: [GeneratedInvite] = []
    @State private var generationError: String?

    private let generator = InviteGenerator()

    /// Enough for a tester round without turning the screen into a list nobody reads.
    /// More are minted one at a time on demand, which also keeps unused capabilities
    /// from being created for people who only needed two.
    private static let initialCount = 5

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("invite_several", comment: ""),
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
                    Text(
                        String(
                            format: NSLocalizedString("invite_several_hint_fmt", comment: ""),
                            InviteConfig.ttlDescription
                        )
                    )
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.top, CTLayout.edgePad)

                    if let generationError {
                        Text("> \(generationError)")
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.danger)
                            .padding(.horizontal, CTLayout.edgePad)
                    }

                    CTSectionGroup {
                        ForEach(Array(invites.enumerated()), id: \.element.id) { index, invite in
                            if index > 0 { CTSep(style: .thin) }
                            Button { copy(at: index) } label: {
                                CTSettingsRow(
                                    label: String(
                                        format: NSLocalizedString("invite_link_index_fmt", comment: ""),
                                        index + 1
                                    ),
                                    value: invite.copied
                                        ? NSLocalizedString("link_copied", comment: "").uppercased()
                                        : NSLocalizedString("copy", comment: "").uppercased(),
                                    icon: invite.copied ? "checkmark" : "link",
                                    labelColor: invite.copied ? Color.CT.textDim : Color.CT.text,
                                    isAction: true
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11y.MultiInvite.link(index))
                        }
                    }

                    Button { mintOne() } label: {
                        Text("[\(NSLocalizedString("invite_one_more", comment: "").lowercased())]")
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.accent)
                            .padding(.horizontal, CTLayout.edgePad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11y.MultiInvite.oneMore)

                    Spacer(minLength: CTLayout.edgePad)
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .onAppear {
            guard invites.isEmpty else { return }
            for _ in 0..<Self.initialCount { mintOne() }
        }
    }

    // MARK: - Actions

    private func copy(at index: Int) {
        guard invites.indices.contains(index) else { return }
        PlatformClipboard.copy(invites[index].link)
        invites[index].copied = true
    }

    /// Mint one more invite. Failure is surfaced, not swallowed: `try?` here would leave
    /// a button that does nothing, which is the shape of defect this whole screen exists
    /// downstream of.
    private func mintOne() {
        guard let deviceId = KeychainManager.shared.loadDeviceID() else {
            generationError = NSLocalizedString("invite_create_failed", comment: "")
            return
        }
        do {
            let link = try generator.generateDeepLink(
                userId: userId,
                deviceId: deviceId,
                // Never embed `un` in an HTTPS share link — it can land in third-party
                // message previews and logs. Same rule as SettingsView.copyContactLink.
                username: nil,
                server: ServerConfig.inviteHost,
                useHTTPS: true
            )
            invites.append(GeneratedInvite(link: link))
            generationError = nil
        } catch {
            Log.error("MultiInviteView: invite generation failed: \(error)", category: "Invite")
            generationError = NSLocalizedString("invite_create_failed", comment: "")
        }
    }
}

#if DEBUG
#Preview {
    MultiInviteView(userId: "14f28d31-1234-4abc-8def-0123456789ab")
        .preferredColorScheme(.dark)
}
#endif
