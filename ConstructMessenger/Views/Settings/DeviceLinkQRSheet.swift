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
        VStack(spacing: DeviceLinkQRLayout.rootSpacing) {
            CTNavBar(
                title: NSLocalizedString("device_link_qr_title", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
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
        VStack(spacing: DeviceLinkQRLayout.loadingSpacing) {
            ProgressView()
                .tint(Color.CT.textDim)
                .scaleEffect(DeviceLinkQRLayout.loadingIndicatorScale)
            Text(NSLocalizedString("generating", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - QR code panel

    private func qrContent(content: String) -> some View {
        ScrollView {
            VStack(spacing: DeviceLinkQRLayout.contentSpacing) {
                // Sub-header
                HStack(spacing: DeviceLinkQRLayout.sectionHeaderSpacing) {
                    Text(">")
                        .font(CTFont.bold(11))
                        .foregroundColor(Color.CT.accentDim)
                    Text(NSLocalizedString("device_link_section", comment: "").uppercased())
                        .font(CTFont.bold(11))
                        .foregroundColor(Color.CT.accentDim)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, DeviceLinkQRLayout.sectionHeaderHorizontalPadding)
                .padding(.top, DeviceLinkQRLayout.sectionHeaderTopPadding)

                Text(NSLocalizedString("device_link_qr_instructions", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DeviceLinkQRLayout.instructionsHorizontalPadding)

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
                    .padding(.horizontal, DeviceLinkQRLayout.scanHintHorizontalPadding)
                    .padding(.bottom, DeviceLinkQRLayout.scanHintBottomPadding)
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
            .frame(width: DeviceLinkQRLayout.qrSize, height: DeviceLinkQRLayout.qrSize)
            .padding(DeviceLinkQRLayout.qrPadding)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.noise, lineWidth: DeviceLinkQRLayout.qrBorderWidth))
        #else
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: DeviceLinkQRLayout.qrSize, height: DeviceLinkQRLayout.qrSize)
            .padding(DeviceLinkQRLayout.qrPadding)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.noise, lineWidth: DeviceLinkQRLayout.qrBorderWidth))
        #endif
    }

    // MARK: - Expired state

    private var expiredView: some View {
        VStack(spacing: DeviceLinkQRLayout.expiredStateSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTFont.regular(DeviceLinkQRLayout.statusIconSize))
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
                    .padding(.horizontal, DeviceLinkQRLayout.actionButtonHorizontalPadding)
                    .padding(.vertical, DeviceLinkQRLayout.actionButtonVerticalPadding)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: DeviceLinkQRLayout.actionButtonStrokeWidth))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error state

    private func errorView(message: String) -> some View {
        VStack(spacing: DeviceLinkQRLayout.expiredStateSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTFont.regular(DeviceLinkQRLayout.statusIconSize))
                .foregroundColor(.orange)
            Text(message)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DeviceLinkQRLayout.errorMessageHorizontalPadding)
            Button {
                vm.errorMessage = nil
                Task { await vm.generateLinkCode() }
            } label: {
                Text("[\(NSLocalizedString("device_link_refresh", comment: "")) →]")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.accent)
                    .padding(.horizontal, DeviceLinkQRLayout.actionButtonHorizontalPadding)
                    .padding(.vertical, DeviceLinkQRLayout.actionButtonVerticalPadding)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: DeviceLinkQRLayout.actionButtonStrokeWidth))
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
