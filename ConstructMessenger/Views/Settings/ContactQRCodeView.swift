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
    @State private var timeRemaining: TimeInterval = InviteConfig.ttlSeconds
    @State private var generationError: String?
    @State private var generatedAt: Date?
    
    private let timer = Timer.publish(every: InviteConfig.qrCountdownTickSeconds, on: .main, in: .common).autoconnect()
    private let generator = InviteGenerator()
    
    /// Pass a pre-built payload only in Previews to skip Keychain/network calls.
    private let previewPayload: String?
    
    init(userId: String, username: String, previewPayload: String? = nil) {
        self.userId = userId
        self.username = username
        self.previewPayload = previewPayload
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 24) {

                    // QR Code
                    if let payload = qrPayload, let qrImage = generateQRCode(from: payload) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: QRCodeSize.standard(in: containerWidth), height: QRCodeSize.standard(in: containerWidth))
                            .padding(QRCodeSize.padding)
                            .background(Color.white)
                            .cornerRadius(QRCodeSize.cornerRadius)
                    } else if let error = generationError {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: QRCodeSize.standard(in: containerWidth), height: QRCodeSize.standard(in: containerWidth))
                            .cornerRadius(QRCodeSize.cornerRadius)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.largeTitle)
                                        .foregroundColor(.orange)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                            }
                    } else {
                        ProgressView()
                            .frame(width: QRCodeSize.standard(in: containerWidth), height: QRCodeSize.standard(in: containerWidth))
                    }

                    VStack(spacing: 8) {
                        if !username.isEmpty {
                            Text("@\(username)")
                                .font(.headline)
                                .foregroundColor(.primary)
                        } else {
                            Text(DisplayNameGenerator.generate(from: userId))
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }

                        // Countdown timer
                        if timeRemaining > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.caption)
                                Text("Expires in \(formatTime(timeRemaining))")
                                    .font(.caption)
                            }
                            .foregroundColor(timeRemaining < InviteConfig.qrWarningThresholdSeconds ? .orange : .secondary)
                        } else {
                            Text("Code expired")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        Text("show_this_code_to_someone_nearby")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                Spacer()

                // Regenerate button if expired
                if timeRemaining <= 0 {
                    Button {
                        regenerateQRCode()
                    } label: {
                        Label("Generate New Code", systemImage: "arrow.clockwise")
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 32)
                }
                
                // Hint text
                Text("scan_with_camera_or_screenshot")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }

            // Close button — rendered as overlay so it always sits inside the sheet
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .buttonStyle(.plain)
        }
        .onAppear {
                if let preview = previewPayload {
                    qrPayload = preview
                    generatedAt = Date()
                } else {
                    generateInitialQRCode()
                }
            }
            .onReceive(timer) { _ in
                updateTimeRemaining()
            }
        }

    // MARK: - QR Code Generation
    
    private func generateInitialQRCode() {
        Task { await generateInitialQRCodeAsync() }
    }

    @MainActor
    private func generateInitialQRCodeAsync() async {
        Log.info("🔐 Starting QR code generation...", category: "ContactQRCodeView")
        Log.info("   - userId: \(userId)", category: "ContactQRCodeView")
        Log.info("   - username: \(username)", category: "ContactQRCodeView")
        
        // Check if device is registered
        if !KeychainManager.shared.isDeviceRegistered() {
            generationError = "Device not registered"
            Log.error("❌ Cannot generate QR: Device not registered in Keychain", category: "ContactQRCodeView")
            return
        }
        
        do {
            // ✅ Use public invite host (.well-known lives here)
            let serverHostname = ServerConfig.inviteHost
            Log.debug("🔐 Using server hostname for QR: \(serverHostname)", category: "ContactQRCodeView")
            
            // ✅ Get deviceId from Keychain
            guard let deviceId = KeychainManager.shared.loadDeviceID() else {
                generationError = "Device ID not found"
                Log.error("❌ Cannot generate QR: deviceId not found in Keychain", category: "ContactQRCodeView")
                return
            }

            // ✅ Generate deep link with both userId and deviceId
            let deepLink = try generator.generateDeepLink(
                userId: userId,
                deviceId: deviceId,
                server: serverHostname,
                useHTTPS: false
            )
            qrPayload = deepLink
            generatedAt = Date()
            timeRemaining = InviteConfig.ttlSeconds
            generationError = nil
            Log.info("✅ Generated QR code for \(username): userId=\(userId.prefix(8))..., deviceId=\(deviceId)", category: "ContactQRCodeView")
        } catch {
            generationError = "Failed to generate code"
            Log.error("❌ Failed to generate QR: \(error)", category: "ContactQRCodeView")
        }
    }
    
    private func regenerateQRCode() {
        qrPayload = nil
        generationError = nil
        generatedAt = nil
        generateInitialQRCode()
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        if let outputImage = filter.outputImage {
            // Scale up the QR code
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private func updateTimeRemaining() {
        guard let generatedAt else { return }
        let elapsed = Date().timeIntervalSince(generatedAt)
        let remaining = max(InviteConfig.ttlSeconds - elapsed, 0)
        if remaining != timeRemaining {
            timeRemaining = remaining
            }
}

}

#Preview {
    ContactQRCodeView(
        userId: "user123",
        username: "john_doe",
        previewPayload: "konstrukt://invite?userId=user123&username=john_doe&deviceId=device456&server=ams.konstruct.cc"
    )
}
