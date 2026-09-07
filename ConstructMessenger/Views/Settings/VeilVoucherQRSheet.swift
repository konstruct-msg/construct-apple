//
//  VeilVoucherQRSheet.swift
//  Construct Messenger
//
//  Show a bootstrap voucher as a QR for someone who has no way in yet.
//
//  The one rule this screen enforces: it renders the voucher **only** as a QR. There is
//  no code path here that puts the deep link, the relay host, the SNI or the pin on
//  screen — not in a label, not in a share sheet, not in an error message. A private
//  front that reaches a screenshot is a published front, and the QR itself is short-
//  lived (45 minutes) while a screenshot is not.
//

import SwiftUI

struct VeilVoucherQRSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var vm = VeilVoucherViewModel()
    @State private var countdown: String = ""
    @State private var countdownTimer: Timer?

    var body: some View {
        VStack(spacing: VeilVoucherLayout.rootSpacing) {
            CTNavBar(
                title: NSLocalizedString("veil_voucher_title", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
            Rectangle().fill(Color.CT.noise).frame(height: 1)

            switch vm.state {
            case .idle:
                intro
            case .minting:
                loadingState
            case .ready(let configURI, _):
                qrContent(configURI: configURI)
            case .expired:
                message(
                    icon: "clock.badge.xmark",
                    text: NSLocalizedString("veil_voucher_expired", comment: ""),
                    retry: true
                )
            case .quota(let retryAfter):
                message(icon: "hourglass", text: quotaText(retryAfter), retry: false)
            case .unavailable:
                message(
                    icon: "nosign",
                    text: NSLocalizedString("veil_voucher_unavailable", comment: ""),
                    retry: false
                )
            case .failed(let text):
                message(icon: "exclamationmark.triangle", text: text, retry: true)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .onDisappear { stopCountdown() }
    }

    // MARK: - States

    /// Deliberately not auto-minting. Three per 24h is scarce enough that an accidental
    /// open must not cost one.
    private var intro: some View {
        VStack(spacing: VeilVoucherLayout.messageSpacing) {
            Image(systemName: "qrcode")
                .font(.system(size: VeilVoucherLayout.statusIconSize))
                .foregroundColor(Color.CT.textDim)
            Text(NSLocalizedString("veil_voucher_intro", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VeilVoucherLayout.textHorizontalPadding)
            Button(NSLocalizedString("veil_voucher_create", comment: "")) {
                Task { await vm.mint() }
            }
            .font(CTFont.regular(13))
            .foregroundColor(Color.CT.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: VeilVoucherLayout.loadingSpacing) {
            ProgressView()
                .tint(Color.CT.textDim)
                .scaleEffect(VeilVoucherLayout.loadingIndicatorScale)
            Text(NSLocalizedString("generating", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func qrContent(configURI: String) -> some View {
        ScrollView {
            VStack(spacing: VeilVoucherLayout.contentSpacing) {
                Text(NSLocalizedString("veil_voucher_instructions", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VeilVoucherLayout.textHorizontalPadding)
                    .padding(.top, VeilVoucherLayout.contentTopPadding)

                // The only place the voucher is used. Encoded, never displayed.
                if let image = QRCodeGenerator.generate(from: configURI) {
                    qrImageView(image)
                }

                if !countdown.isEmpty {
                    Text(countdown)
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.textDim)
                }

                Text(NSLocalizedString("veil_voucher_privacy_hint", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VeilVoucherLayout.textHorizontalPadding)
                    .padding(.bottom, VeilVoucherLayout.contentBottomPadding)
            }
        }
        .onAppear { startCountdown() }
    }

    @ViewBuilder
    private func qrImageView(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: VeilVoucherLayout.qrSize, height: VeilVoucherLayout.qrSize)
            .padding(VeilVoucherLayout.qrPadding)
            .background(Color.white)
            .clipShape(CTShape.card())
        #else
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: VeilVoucherLayout.qrSize, height: VeilVoucherLayout.qrSize)
            .padding(VeilVoucherLayout.qrPadding)
            .background(Color.white)
            .clipShape(CTShape.card())
        #endif
    }

    private func message(icon: String, text: String, retry: Bool) -> some View {
        VStack(spacing: VeilVoucherLayout.messageSpacing) {
            Image(systemName: icon)
                .font(.system(size: VeilVoucherLayout.statusIconSize))
                .foregroundColor(Color.CT.textDim)
            Text(text)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VeilVoucherLayout.textHorizontalPadding)
            if retry {
                Button(NSLocalizedString("veil_voucher_new", comment: "")) {
                    stopCountdown()
                    Task { await vm.mint() }
                }
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func quotaText(_ retryAfter: TimeInterval) -> String {
        guard retryAfter > 0 else {
            return NSLocalizedString("veil_voucher_quota", comment: "")
        }
        let hours = max(1, Int((retryAfter / 3600).rounded(.up)))
        return String(format: NSLocalizedString("veil_voucher_quota_retry", comment: ""), hours)
    }

    // MARK: - Countdown

    private func startCountdown() {
        stopCountdown()
        updateCountdown()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in updateCountdown() }
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func updateCountdown() {
        guard case .ready(_, let expiresAt) = vm.state else {
            countdown = ""
            stopCountdown()
            return
        }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else {
            countdown = ""
            stopCountdown()
            vm.markExpired()
            return
        }
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        countdown = String(
            format: NSLocalizedString("veil_voucher_expires_in", comment: ""),
            "\(mins):\(String(format: "%02d", secs))"
        )
    }
}
