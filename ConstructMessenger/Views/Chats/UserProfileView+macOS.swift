//
//  UserProfileView+macOS.swift
//  Construct Messenger
//
//  The macOS contact card of UserProfileView, split out of UserProfileView.swift.
//

import SwiftUI
import CoreData

#if os(macOS)
extension UserProfileView {
    // MARK: - macOS card

    /// On the Mac the card is a popover off the chat's info button, as Messages shows details:
    /// the system's grouped form and its switch, rows that act as rows, and no close button — a
    /// click outside or Esc closes it (owner, 2026-10-18). The phone's hero header and
    /// round buttons were a copy of a portrait screen in a landscape window.
    var macCard: some View {
        Form {
            Section { macHeader }

            Section(Self.sectionTitle("identity_section")) {
                // Edited in place: a field that saves on Return or when the card closes.
                LabeledContent(NSLocalizedString("local_name", comment: "")) {
                    TextField(
                        "",
                        text: $draftLocalName,
                        prompt: Text(NSLocalizedString("local_name_unset", comment: ""))
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(saveLocalNameIfChanged)
                }
                .help(NSLocalizedString("local_name_footer", comment: ""))

                LabeledContent(NSLocalizedString("identity_fingerprint", comment: "")) {
                    if let fp = user.knownIdentityKey.flatMap({ IdentityFingerprint.short(from: $0) }) {
                        HStack(spacing: CTLayout.inlinePad) {
                            Text(fp)
                                .font(CTFont.mono(12))
                                .foregroundStyle(Color.CT.accent)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Button {
                                PlatformClipboard.copy(fp)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(NSLocalizedString("identity_fingerprint_copy_hint", comment: ""))
                        }
                    } else {
                        Text(NSLocalizedString("identity_fingerprint_unknown", comment: ""))
                            .foregroundStyle(Color.CT.textDim)
                    }
                }

                #if DEBUG
                LabeledContent(NSLocalizedString("user_id", comment: "")) {
                    Text(user.id)
                        .font(CTFont.mono(11))
                        .foregroundStyle(Color.CT.textDim)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                #endif
            }

            Section(Self.sectionTitle("profile_sharing_section")) {
                Toggle(isOn: Binding(
                    get: { user.amISharingWith },
                    set: { handleShareToggle($0) }
                )) {
                    Text(NSLocalizedString("share_my_profile", comment: ""))
                    Text(NSLocalizedString("share_profile_explanation", comment: ""))
                }
                .toggleStyle(.switch)
                .disabled(isSharingInProgress)

                if let sharedAt = user.sharedWithMeAt, user.isSharingWithMe {
                    Text(String(format: NSLocalizedString("sharing_with_you", comment: ""), formatDate(sharedAt)))
                        .foregroundStyle(Color.CT.textDim)
                }
            }

            Section(Self.sectionTitle("security")) {
                if let alert = user.trustAlert {
                    keyChangeWarningBlock(alert)
                }
                LabeledContent {
                    HStack(spacing: CTLayout.inlinePad) {
                        CTStatusBadge(status: hasSession ? .ok : .off, size: 13)
                        Text(hasSession ? NSLocalizedString("encrypted", comment: "") : sessionSuiteLabel)
                            .foregroundStyle(hasSession ? Color.CT.text : Color.CT.textDim)
                    }
                } label: {
                    Text(NSLocalizedString("session_crypto_suite", comment: ""))
                    if hasSession {
                        Text(sessionSuiteLabel).font(CTFont.mono(11))
                    }
                }
                macRowButton(NSLocalizedString("safety_numbers", comment: ""), color: Color.CT.text, chevron: true) {
                    showingSafetyNumbers = true
                }
            }

            Section(Self.sectionTitle("danger_zone")) {
                macRowButton(
                    NSLocalizedString(user.isBlocked ? "unblock_user" : "block_user", comment: ""),
                    color: user.isBlocked ? Color.CT.text : Color.CT.danger
                ) { showingBlockConfirmation = true }
                macRowButton(NSLocalizedString("report_spam", comment: ""), color: Color.CT.danger) {
                    showingReportConfirmation = true
                }
                if let prune = onPrune {
                    macRowButton(NSLocalizedString("synapses_prune_action", comment: ""), color: Color.CT.danger) {
                        prune(); dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(CTFont.body)
        .scrollContentBackground(.hidden)
        .background(Color.CT.bg)
        // As tall as what it holds, up to most of the screen — a key-change warning makes it taller.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            macContentHeight = height
        }
        .frame(height: macContentHeight > 0 ? min(macContentHeight, Self.macMaxHeight) : nil)
        .onAppear { draftLocalName = user.localAlias ?? "" }
        .onChange(of: userId) { _, _ in
            draftLocalName = user.localAlias ?? ""
            refreshSessionSecurityState()
        }
        .onDisappear(perform: saveLocalNameIfChanged)
    }

    /// The person beside their photo, in one row: the card is narrow and tall, and a 96-pt
    /// photo above a centred name spent its first third on whitespace.
    private var macHeader: some View {
        let avatarImage: PlatformImage? = user.avatar.flatMap { PlatformImage(data: $0) }
        return HStack(spacing: CTLayout.edgePad) {
            MainAvatarView(
                userId: user.id,
                displayName: user.resolvedDisplayName,
                image: avatarImage,
                size: CTAvatarSize.header,
                isActive: false
            )
            .contentShape(Rectangle())
            .onTapGesture { if avatarImage != nil { showAvatarViewer = true } }

            VStack(alignment: .leading, spacing: 2) {
                Text(user.resolvedDisplayName)
                    .font(CTFont.headline)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(2)
                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                        .textSelection(.enabled)
                }
                if user.isBlocked {
                    Label(NSLocalizedString("profile_blocked_badge", comment: ""), systemImage: "nosign")
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.danger)
                }
            }
            Spacer(minLength: 0)
            ForEach(actionButtons, id: \.self) { action in
                switch action {
                case .message:
                    Button { onOpenChat?(); dismiss() } label: { Image(systemName: "message") }
                        .help(NSLocalizedString("message", comment: ""))
                case .call:
                    Button { startCall(hasVideo: false) } label: { Image(systemName: "phone") }
                        .help(NSLocalizedString("chat_action_call", comment: ""))
                case .video:
                    Button { startCall(hasVideo: true) } label: { Image(systemName: "video") }
                        .help(NSLocalizedString("chat_action_video", comment: ""))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .sheet(isPresented: $showAvatarViewer) {
            if let avatarImage {
                FullScreenImageView(image: avatarImage, isPresented: $showAvatarViewer)
            }
        }
    }

    /// A form row that acts: the whole row is the target, as in System Settings. A push button in
    /// a grouped form drew as a tinted capsule against the left edge, and lost the danger colour.
    private func macRowButton(_ title: String, color: Color, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(color)
                Spacer()
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Section titles as the system's are, first letter capitalised: the keys were written for
    /// the phone's uppercased headers, and "identity" sat beside "Danger Zone".
    private static func sectionTitle(_ key: String) -> String {
        let title = NSLocalizedString(key, comment: "")
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    private static var macMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
    }

    private func saveLocalNameIfChanged() {
        let trimmed = draftLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (user.localAlias ?? "") else { return }
        saveLocalName()
    }
}
#endif
