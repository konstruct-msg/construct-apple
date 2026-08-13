//
//  ContactQRCodeView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//  Updated for Dynamic Invites on 30.01.2026.
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
    @State private var timeRemaining: TimeInterval = InviteConfig.ttlSeconds
    @State private var generationError: String?
    @State private var generatedAt: Date?
    
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
            // Nav bar
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
                        timerBlock
                    }
                    .padding(.vertical, ContactQRCodeLayout.qrBlockVerticalPadding)
                    .frame(maxWidth: .infinity)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    // Footer hint
                    Text("> \(NSLocalizedString("qr_scan_hint", comment: ""))")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ContactQRCodeLayout.footerHorizontalPadding)
                        .padding(.vertical, ContactQRCodeLayout.footerVerticalPadding)
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
                timeRemaining = InviteConfig.ttlSeconds
                generatedAt = Date()
            } else {
                generateInitialQRCode()
            }
        }
        .onReceive(timer) { _ in
            updateTimeRemaining()
            maybeRotateQR()
        }
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

    // MARK: - Timer block

    @ViewBuilder
    private var timerBlock: some View {
        if timeRemaining > 0 {
            let isWarning = timeRemaining < InviteConfig.qrWarningThresholdSeconds
            HStack(spacing: ContactQRCodeLayout.timerRowSpacing) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isWarning ? Color.CT.danger : Color.CT.textDim)
                Text(String(format: NSLocalizedString("expires_in", comment: ""), formatTime(timeRemaining)))
                    .font(CTFont.regular(13))
                    .foregroundStyle(isWarning ? Color.CT.danger : Color.CT.text)
                    .monospacedDigit()
            }
        } else {
            VStack(spacing: ContactQRCodeLayout.expiredBlockSpacing) {
                Text("[ \(NSLocalizedString("code_expired", comment: "").lowercased()) ]")
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.danger)

                Button { regenerateQRCode() } label: {
                    Text("[\(NSLocalizedString("generate_new_code", comment: "").lowercased())]")
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
                .accessibilityIdentifier(A11y.ContactQR.regenerate)
            }
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
            let binary = try generator.generateQRBinary(
                userId: userId,
                deviceId: deviceId,
                username: nil,
                server: serverHostname
            )
            let textPayload = InviteBinaryCodec.base64URLEncode(binary)
            qrPayloadBytes = binary
            qrImage = QRCodeGenerator.generate(from: textPayload)
            generatedAt = Date()
            timeRemaining = InviteConfig.ttlSeconds
            generationError = nil
            #if DEBUG
            Log.debug(
                "Invite QR binary=\(binary.count)B textPayload=\(textPayload.count) chars",
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

    /// m:ss is only readable while the remainder is minutes. At a 12-hour TTL the
    /// same formatter printed "720:00", which is not a time anyone reads — so the
    /// last hour keeps the countdown and everything above it switches to units the
    /// OS localizes for us (no new strings, and correct in ru/ja on arrival).
    /// Mint a fresh jti every `qrRotateIntervalSeconds` while the code is on screen.
    ///
    /// An invite is burned by its first redeemer, and the sender gets no signal that it
    /// happened — so without this, the second person to scan the same screen is told the
    /// invite is already used. Rotation is the only thing making "show my QR to a few
    /// people" work at all, until [[decisions/invite-two-modes-deferred]] is revisited.
    private func maybeRotateQR() {
        guard previewPayload == nil else { return }
        guard generationError == nil, qrPayloadBytes != nil else { return }
        guard let generatedAt else { return }
        let elapsed = Date().timeIntervalSince(generatedAt)
        guard elapsed >= InviteConfig.qrRotateIntervalSeconds else { return }
        Log.debug("Rotating invite QR after \(Int(elapsed))s", category: "ContactQR")
        regenerateQRCode()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            return formatter.string(from: seconds) ?? ""
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func updateTimeRemaining() {
        guard let generatedAt else { return }
        timeRemaining = max(InviteConfig.ttlSeconds - Date().timeIntervalSince(generatedAt), 0)
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
