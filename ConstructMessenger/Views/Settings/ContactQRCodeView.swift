//
//  ContactQRCodeView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//  Updated for Dynamic Invites on 30.01.2026.
//  Merged with the copy-link action and MultiInviteView on 2026-08-15.
//
//  One surface for inviting someone, replacing three.
//
//  Settings used to carry a [QR][COPY LINK] pair plus a caption linking to
//  `MultiInviteView`, which pre-minted five capabilities on open so a group could be
//  invited. That screen existed only because the rule making it unnecessary — every tap
//  of "copy" mints a fresh one-time invite — was never stated anywhere the user could
//  read it. The rule now sits under the button, and the screen is gone.
//

import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins

struct ContactQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.containerWidth) private var containerWidth
    let userId: String
    let username: String

    @State private var qrPayloadBytes: Data?
    @State private var qrImage: UIImage?
    @State private var generationError: String?
    @State private var generatedAt: Date?

    /// Links minted from the copy button in this sitting. Drives the button's feedback:
    /// tap two is only distinguishable from tap one because this number moved.
    @State private var copiedCount = 0
    @State private var lastCopyAt: Date?
    @State private var copyError: String?

    private let timer = Timer.publish(every: InviteConfig.qrCountdownTickSeconds, on: .main, in: .common).autoconnect()
    private let generator = InviteGenerator()

    /// Preview-only compact binary (or empty → live generate).
    private let previewPayload: Data?

    init(userId: String, username: String, previewPayload: Data? = nil) {
        self.userId = userId
        self.username = username
        self.previewPayload = previewPayload
    }

    private var displayName: String {
        username.isEmpty ? DisplayNameGenerator.generate(from: userId) : "@\(username)"
    }

    var body: some View {
        VStack(spacing: ContactQRCodeLayout.contentSpacing) {
            CTNavBar(
                title: NSLocalizedString("invite", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
            Rectangle().fill(Color.CT.noise).frame(height: 1)

            ScrollView(showsIndicators: false) {
                VStack(spacing: ContactQRCodeLayout.contentSpacing) {

                    // Identity header
                    VStack(spacing: ContactQRCodeLayout.identityHeaderSpacing) {
                        Text(displayName)
                            .font(CTFont.bold(15))
                            .foregroundStyle(Color.CT.text)
                        Text(NSLocalizedString("qr_caption_trust", comment: ""))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.accent.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ContactQRCodeLayout.identityVerticalPadding)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    // QR block
                    VStack(spacing: ContactQRCodeLayout.qrBlockSpacing) {
                        qrBlock
                            .accessibilityIdentifier(A11y.ContactQR.code)
                        refreshRow
                    }
                    .padding(.vertical, ContactQRCodeLayout.qrBlockVerticalPadding)
                    .frame(maxWidth: .infinity)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    copyLinkButton
                        .accessibilityIdentifier(A11y.ContactQR.copyLink)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    footer
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .frame(
            idealWidth: ContactQRCodeLayout.idealWidth,
            idealHeight: ContactQRCodeLayout.idealHeight
        )
        .onAppear {
            if let preview = previewPayload {
                qrPayloadBytes = preview
                qrImage = QRCodeGenerator.generate(from: preview)
                generatedAt = Date()
            } else {
                generateInitialQRCode()
            }
        }
        .onReceive(timer) { _ in maybeRotateQR() }
        // Closes the journal's QR sitting. Without it the next code minted — possibly days
        // later — would append to an act timestamped by a sheet the user no longer
        // remembers opening.
        .onDisappear { InviteJournal.shared.closeQRSession() }
    }

    // MARK: - QR block

    @ViewBuilder
    private var qrBlock: some View {
        let size = QRCodeSize.standard(in: containerWidth)

        if qrPayloadBytes != nil, let qrImage {
            // White bg required for camera readability; bordered with CT noise
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(QRCodeSize.padding)
                .background(Color.white)
                .clipShape(CTShape.card())
                .overlay(CTShape.card().strokeBorder(Color.CT.noise, lineWidth: ContactQRCodeLayout.qrCodeBorderWidth))
        } else if let error = generationError {
            CTShape.card()
                .fill(Color.CT.bgMsg)
                .frame(width: size, height: size)
                .overlay(CTShape.card().strokeBorder(Color.CT.noise, lineWidth: ContactQRCodeLayout.qrCodeBorderWidth))
                .overlay {
                    VStack(spacing: ContactQRCodeLayout.qrCodeErrorSpacing) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(CTFont.regular(20))
                            .foregroundStyle(Color.CT.danger)
                        Text(error)
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ContactQRCodeLayout.qrCodeErrorHorizontalPadding)
                    }
                }
        } else {
            CTShape.card()
                .fill(Color.CT.bgMsg)
                .frame(width: size, height: size)
                .overlay(CTShape.card().strokeBorder(Color.CT.noise, lineWidth: ContactQRCodeLayout.qrCodeBorderWidth))
                .overlay {
                    ProgressView()
                        .tint(Color.CT.textDim)
                }
        }
    }

    /// Manual re-mint for the person the code did not scan for.
    ///
    /// The countdown that used to live here ("new in 0:23") was removed with the rest of
    /// the multi-invite scaffolding: it counted down to something the user cannot act on,
    /// and it invited the question "what happens at zero" whose answer — your code is
    /// already a different one — is not what a countdown normally means. Rotation itself
    /// stays; see `maybeRotateQR`.
    @ViewBuilder
    private var refreshRow: some View {
        if previewPayload == nil, qrPayloadBytes != nil || generationError != nil {
            Button { regenerateQRCode() } label: {
                Text(NSLocalizedString("qr_new_code", comment: "").lowercased())
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.accent)
                    .padding(.horizontal, ContactQRCodeLayout.refreshButtonHorizontalPadding)
                    .padding(.vertical, ContactQRCodeLayout.refreshButtonVerticalPadding)
                    .background(
                        CTShape.card()
                            .fill(Color.CT.bgMsg)
                            .overlay(
                                CTShape.card().strokeBorder(
                                    Color.CT.accent.opacity(ContactQRCodeLayout.refreshButtonStrokeOpacity),
                                    lineWidth: ContactQRCodeLayout.refreshButtonStrokeWidth
                                )
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("qr_new_code", comment: ""))
            .accessibilityIdentifier(A11y.ContactQR.regenerate)
        }
    }

    // MARK: - Copy link

    private var copyFeedback: InviteShareDecision.CopyFeedback {
        InviteShareDecision.feedback(copiedCount: copiedCount)
    }

    private var copyLabel: String {
        switch copyFeedback {
        case .idle:
            return NSLocalizedString("invite_copy_link", comment: "")
        case .copied:
            return NSLocalizedString("share_copied", comment: "")
        case .copiedAgain(let n):
            return String(format: NSLocalizedString("invite_copied_nth_fmt", comment: ""), n)
        }
    }

    private var copyLinkButton: some View {
        Button { copyLink() } label: {
            HStack(spacing: SettingsShareLayout.actionSpacing) {
                Image(systemName: copyFeedback == .idle ? "link" : "checkmark")
                    .font(.system(size: SettingsShareLayout.actionIconSize, weight: .regular))
                Text(copyLabel.uppercased())
                    .font(CTFont.regular(11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(copyFeedback == .idle ? Color.CT.text : Color.CT.accent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: SettingsShareLayout.actionMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("invite_copy_link", comment: ""))
        .accessibilityHint(
            String(
                format: NSLocalizedString("invite_share_rule_fmt", comment: ""),
                InviteConfig.ttlDescription
            )
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: ContactQRCodeLayout.identityHeaderSpacing) {
            Text(
                "> " + String(
                    format: NSLocalizedString("invite_share_rule_fmt", comment: ""),
                    InviteConfig.ttlDescription
                )
            )
            .font(CTFont.regular(11))
            .foregroundStyle(Color.CT.textDim)

            if let copyError {
                Text("> \(copyError)")
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ContactQRCodeLayout.footerHorizontalPadding)
        .padding(.vertical, ContactQRCodeLayout.footerVerticalPadding)
    }

    // MARK: - Actions

    /// Mint a fresh one-time invite and put it on the clipboard.
    ///
    /// Failure is surfaced, never swallowed: `try?` here leaves a button that reports
    /// "copied" over a clipboard holding whatever was there before.
    private func copyLink() {
        guard InviteShareDecision.shouldMint(
            now: Date(),
            lastMintAt: lastCopyAt,
            debounce: SettingsShareLayout.copyDebounce
        ) else { return }

        guard let deviceId = KeychainManager.shared.loadDeviceID() else {
            copyError = NSLocalizedString("invite_create_failed", comment: "")
            return
        }
        do {
            // HTTPS share can land in third-party messenger logs/previews — never embed `un`.
            let minted = try generator.generateDeepLink(
                userId: userId,
                deviceId: deviceId,
                username: nil,
                server: ServerConfig.inviteHost,
                useHTTPS: true
            )
            PlatformClipboard.copy(minted.artifact)
            // Recorded only once the link is actually on the clipboard: a jti journalled
            // for a link the user never received is an entry they cannot account for, and
            // the screen listing it has no way to tell the difference.
            InviteJournal.shared.recordCopiedLink(jti: minted.jti, at: minted.issuedAt)
            lastCopyAt = Date()
            copyError = nil
            withAnimation { copiedCount += 1 }
        } catch {
            Log.error("ContactQRCodeView: invite generation failed: \(error)", category: "Invite")
            copyError = NSLocalizedString("invite_create_failed", comment: "")
        }
    }

    // MARK: - QR Code Generation

    private func generateInitialQRCode() {
        Task { await generateInitialQRCodeAsync() }
    }

    @MainActor
    private func generateInitialQRCodeAsync() async {
        if !KeychainManager.shared.isDeviceRegistered() {
            generationError = "Device not registered"
            return
        }
        do {
            let serverHostname = ServerConfig.inviteHost
            guard let deviceId = KeychainManager.shared.loadDeviceID() else {
                generationError = "Device ID not found"
                return
            }
            // Text-safe base64url(CIv1) in UTF-8 QR — AVFoundation reliably returns
            // stringValue for this. Pure byte-mode CIv1 often yields nil stringValue
            // on device (no haptic, no redeem). Scanner still dual-reads Latin-1
            // byte-mode for already-printed binary QRs.
            // Metadata minimization (thread 5): do not embed plaintext username in the
            // signed invite by default — identity chrome stays in UI only (`displayName`).
            let minted = try generator.generateQRBinary(
                userId: userId,
                deviceId: deviceId,
                username: nil,
                server: serverHostname
            )
            let textPayload = InviteBinaryCodec.base64URLEncode(minted.artifact)
            qrPayloadBytes = minted.artifact
            qrImage = QRCodeGenerator.generate(from: textPayload)
            generatedAt = Date()
            generationError = nil
            // Every rotation joins the sitting opened by the first code, so a sheet held up
            // at a table is one entry in the journal rather than one per 30 seconds.
            InviteJournal.shared.recordQRCode(jti: minted.jti, at: minted.issuedAt)
            #if DEBUG
            Log.debug(
                "Invite QR binary=\(minted.artifact.count)B textPayload=\(textPayload.count) chars",
                category: "ContactQR"
            )
            #endif
        } catch {
            generationError = "Failed to generate code"
        }
    }

    private func regenerateQRCode() {
        qrPayloadBytes = nil
        qrImage = nil
        generationError = nil
        generatedAt = nil
        generateInitialQRCode()
    }

    /// Mint a fresh jti every `qrRotateIntervalSeconds` while the code is on screen.
    ///
    /// An invite is burned by its first redeemer, and the sender gets no signal that it
    /// happened — so without this, the second person to scan the same screen is told the
    /// invite is already used. Rotation is the only thing making "show my QR to a few
    /// people" work at all, until [[decisions/invite-two-modes-deferred]] is revisited.
    /// Manual "new code" is the same mint, on demand, so the next person does not wait.
    private func maybeRotateQR() {
        guard previewPayload == nil else { return }
        guard generationError == nil, qrPayloadBytes != nil else { return }
        guard let generatedAt else { return }
        let elapsed = Date().timeIntervalSince(generatedAt)
        guard elapsed >= InviteConfig.qrRotateIntervalSeconds else { return }
        Log.debug("Rotating invite QR after \(Int(elapsed))s", category: "ContactQR")
        regenerateQRCode()
    }
}

#Preview {
    ContactQRCodeView(
        userId: "user123",
        username: "john_doe",
        previewPayload: Data("CIv1-preview".utf8)
    )
    .preferredColorScheme(.dark)
}
