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
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("device_link_qr_title", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            Rectangle().fill(Color.CT.noise).frame(height: 1)

            if vm.isGenerating {
                loadingState
            } else if let content = vm.qrContent, vm.isTokenValid {
                qrContent(content: content)
            } else if vm.qrContent != nil && !vm.isTokenValid {
                expiredView
            } else if let error = vm.errorMessage {
                errorView(message: error)
            } else {
                loadingState
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .task { await vm.generateLinkCode() }
        .onDisappear { stopCountdown() }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            Text(CTSymbol.loading)
                .font(CTFont.regular(24))
                .foregroundColor(Color.CT.textDim)
            Text(NSLocalizedString("generating", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - QR code panel

    private func qrContent(content: String) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Sub-header
                HStack(spacing: 6) {
                    Text(">")
                        .font(CTFont.bold(11))
                        .foregroundColor(Color.CT.accentDim)
                    Text(NSLocalizedString("device_link_section", comment: "").uppercased())
                        .font(CTFont.bold(11))
                        .foregroundColor(Color.CT.accentDim)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                Text(NSLocalizedString("device_link_qr_instructions", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let image = generateQRCode(from: content) {
                    qrImageView(image)
                }

                if !countdown.isEmpty {
                    Text(countdown)
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.textDim)
                        .onAppear { startCountdown() }
                }

                Text(NSLocalizedString("device_link_scan_hint", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
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
            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
        #else
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 220)
            .padding(16)
            .background(Color.white)
            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
        #endif
    }

    // MARK: - Expired state

    private var expiredView: some View {
        VStack(spacing: 16) {
            Text("[!]")
                .font(CTFont.bold(36))
                .foregroundColor(Color.CT.danger)
            Text(NSLocalizedString("device_link_expired", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
            Button {
                Task { await vm.generateLinkCode() }
            } label: {
                Text("[\(NSLocalizedString("device_link_refresh", comment: "")) →]")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error state

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Text("[!]")
                .font(CTFont.bold(36))
                .foregroundColor(.orange)
            Text(message)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                vm.errorMessage = nil
                Task { await vm.generateLinkCode() }
            } label: {
                Text("[\(NSLocalizedString("device_link_refresh", comment: "")) →]")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        QRCodeGenerator.generate(from: string)
    }
}

#Preview {
    DeviceLinkQRSheet()
        .preferredColorScheme(.dark)
}
