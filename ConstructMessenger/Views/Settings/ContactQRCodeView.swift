//
//  ContactQRCodeView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//  Updated for Dynamic Invites on 30.01.2026.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ContactQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.containerWidth) private var containerWidth
    let userId: String
    let username: String
    
    @State private var qrPayload: String?
    @State private var qrImage: UIImage?
    @State private var timeRemaining: TimeInterval = InviteConfig.ttlSeconds
    @State private var generationError: String?
    @State private var generatedAt: Date?
    
    private let timer = Timer.publish(every: InviteConfig.qrCountdownTickSeconds, on: .main, in: .common).autoconnect()
    private let generator = InviteGenerator()
    
    private let previewPayload: String?
    
    init(userId: String, username: String, previewPayload: String? = nil) {
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
            )
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
                qrPayload = preview
                qrImage = generateQRCode(from: preview)
                timeRemaining = InviteConfig.ttlSeconds
                generatedAt = Date()
            } else {
                generateInitialQRCode()
            }
        }
        .onReceive(timer) { _ in updateTimeRemaining() }
    }

    // MARK: - QR block

    @ViewBuilder
    private var qrBlock: some View {
        let size = QRCodeSize.standard(in: containerWidth)

        if qrPayload != nil, let qrImage {
            // White bg required for camera readability; bordered with CT noise
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(QRCodeSize.padding)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.CT.noise, lineWidth: ContactQRCodeLayout.qrCodeBorderWidth))
        } else if let error = generationError {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.CT.bgMsg)
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.CT.noise, lineWidth: ContactQRCodeLayout.qrCodeBorderWidth))
                .overlay {
                    VStack(spacing: ContactQRCodeLayout.qrCodeErrorSpacing) {
                        Text("[!]")
                            .font(CTFont.bold(20))
                            .foregroundStyle(Color.CT.danger)
                        Text(error)
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ContactQRCodeLayout.qrCodeErrorHorizontalPadding)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.CT.bgMsg)
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.CT.noise, lineWidth: ContactQRCodeLayout.qrCodeBorderWidth))
                .overlay {
                    Text(CTSymbol.loading)
                        .font(CTFont.regular(16))
                        .foregroundStyle(Color.CT.textDim)
                }
        }
    }

    // MARK: - Timer block

    @ViewBuilder
    private var timerBlock: some View {
        if timeRemaining > 0 {
            let isWarning = timeRemaining < InviteConfig.qrWarningThresholdSeconds
            HStack(spacing: ContactQRCodeLayout.timerRowSpacing) {
                Text(CTSymbol.ttl)
                    .font(CTFont.regular(11))
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
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.CT.bgMsg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                                        Color.CT.accent.opacity(ContactQRCodeLayout.refreshButtonStrokeOpacity),
                                        lineWidth: ContactQRCodeLayout.refreshButtonStrokeWidth
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
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
            let deepLink = try generator.generateDeepLink(
                userId: userId,
                deviceId: deviceId,
                username: username.isEmpty ? nil : username,
                server: serverHostname,
                useHTTPS: false
            )
            qrPayload = deepLink
            qrImage = generateQRCode(from: deepLink)
            generatedAt = Date()
            timeRemaining = InviteConfig.ttlSeconds
            generationError = nil
        } catch {
            generationError = "Failed to generate code"
        }
    }

    private func regenerateQRCode() {
        qrPayload = nil
        qrImage = nil
        generationError = nil
        generatedAt = nil
        generateInitialQRCode()
    }

    private func generateQRCode(from string: String) -> UIImage? {
        QRCodeGenerator.generate(from: string)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
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
        previewPayload: "konstrukt://invite?userId=user123&username=john_doe&deviceId=device456&server=ams.konstruct.cc"
    )
    .preferredColorScheme(.dark)
}
