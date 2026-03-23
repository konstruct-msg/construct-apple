//
//  DeviceLinkQRSheet.swift
//  Construct Messenger
//
//  Device A flow: show QR code so Device B can scan and link.
//  Called from DevicesView when the user taps "Link New Device".
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct DeviceLinkQRSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var vm = DeviceLinkViewModel()
    @State private var countdown: String = ""
    @State private var countdownTimer: Timer? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if vm.isGenerating {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if let content = vm.qrContent, vm.isTokenValid {
                    qrContent(content: content)

                } else if vm.qrContent != nil && !vm.isTokenValid {
                    expiredView

                } else if let error = vm.errorMessage {
                    errorView(message: error)

                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            .navigationTitle(LocalizedStringKey("device_link_qr_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("done")) { dismiss() }
                }
            }
        }
        .task { await vm.generateLinkCode() }
        .onDisappear { stopCountdown() }
    }

    // MARK: - QR code panel

    private func qrContent(content: String) -> some View {
        VStack(spacing: 20) {
            Text(LocalizedStringKey("device_link_qr_instructions"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let image = generateQRCode(from: content) {
                qrImageView(image)
            }

            if !countdown.isEmpty {
                Label(countdown, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onAppear { startCountdown() }
            }
        }
    }

    @ViewBuilder
    private func qrImageView(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 220)
            .padding(16)
            .background(Color.white)
            .cornerRadius(16)
        #else
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 220)
            .padding(16)
            .background(Color.white)
            .cornerRadius(16)
        #endif
    }

    // MARK: - Expired state

    private var expiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey("device_link_expired"))
                .foregroundStyle(.secondary)
            Button(LocalizedStringKey("device_link_refresh")) {
                Task { await vm.generateLinkCode() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Error state

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(LocalizedStringKey("device_link_refresh")) {
                vm.errorMessage = nil
                Task { await vm.generateLinkCode() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Countdown timer

    private func startCountdown() {
        stopCountdown()
        updateCountdown()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateCountdown()
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func updateCountdown() {
        guard let exp = vm.tokenExpiresAt else { countdown = ""; return }
        let remaining = exp.timeIntervalSinceNow
        if remaining <= 0 {
            countdown = ""
            stopCountdown()
        } else {
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            countdown = String(format: NSLocalizedString("device_link_expires_in", comment: ""), "\(mins):\(String(format: "%02d", secs))")
        }
    }

    // MARK: - QR generation (CoreImage)

    private func generateQRCode(from string: String) -> PlatformImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

#Preview {
    DeviceLinkQRSheet()
}
