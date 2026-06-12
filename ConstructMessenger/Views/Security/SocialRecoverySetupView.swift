//
//  SocialRecoverySetupView.swift
//  ConstructMessenger
//
//  SLIP-39 social recovery setup flow:
//  idle → configure → displayShare(0…N) → uploading → done
//

import SwiftUI

struct SocialRecoverySetupView: View {
    @Environment(SocialRecoveryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Group {
                switch service.setupStep {
                case .idle:
                    introView
                case .configure:
                    configureView
                case .displayShare(let index):
                    shareDisplayView(index: index)
                case .uploading:
                    uploadingView
                case .done:
                    doneView
                case .failed(let msg):
                    failedView(message: msg)
                }
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Nav bar

    private var navBar: some View {
        CTNavBar(
            title: NSLocalizedString("social_recovery_title", comment: ""),
            showBack: showsBack,
            trailingSymbol: showsCancel ? NSLocalizedString("cancel", comment: "") : nil,
            trailingColor: Color.CT.textDim,
            backAction: showsBack ? { service.setupStep = .configure } : nil,
            trailingAction: showsCancel ? {
                service.reset()
                dismiss()
            } : nil
        )
    }

    private var showsBack: Bool {
        if case .displayShare(let i) = service.setupStep { return i > 0 }
        return false
    }

    private var showsCancel: Bool {
        switch service.setupStep {
        case .done, .uploading: return false
        default: return true
        }
    }

    // MARK: - Intro

    private var introView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("[share]")
                .font(CTFont.bold(48))
                .foregroundColor(Color.CT.accent)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("social_recovery_intro_title", comment: "").uppercased())
                .font(CTFont.bold(18))
                .foregroundColor(Color.CT.text)
                .multilineTextAlignment(.center)
            Text(NSLocalizedString("social_recovery_intro_body", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            actionButton(
                label: NSLocalizedString("social_recovery_begin", comment: ""),
                enabled: true
            ) {
                service.setupStep = .configure
            }
        }
    }

    // MARK: - Configure (scheme selection)

    private var configureView: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("social_recovery_scheme_title", comment: ""))
                .padding(.top, 8)

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            schemeRow(
                label: NSLocalizedString("social_recovery_2of3", comment: ""),
                hint: NSLocalizedString("social_recovery_2of3_hint", comment: ""),
                selected: service.threshold == 2 && service.shareCount == 3
            ) {
                service.threshold = 2
                service.shareCount = 3
            }

            Rectangle().fill(Color.CT.noise.opacity(0.4)).frame(height: 1).padding(.horizontal, 20)

            schemeRow(
                label: NSLocalizedString("social_recovery_3of5", comment: ""),
                hint: NSLocalizedString("social_recovery_3of5_hint", comment: ""),
                selected: service.threshold == 3 && service.shareCount == 5
            ) {
                service.threshold = 3
                service.shareCount = 5
            }

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            Spacer()

            actionButton(
                label: NSLocalizedString("social_recovery_generate", comment: ""),
                enabled: true
            ) {
                service.generateShares()
            }
        }
    }

    private func schemeRow(label: String, hint: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(selected ? "[●]" : "[○]")
                    .font(CTFont.regular(14))
                    .foregroundColor(selected ? Color.CT.accent : Color.CT.textDim)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(CTFont.regular(14))
                        .foregroundColor(selected ? Color.CT.text : Color.CT.textDim)
                    Text(hint)
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.textDim)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Share display

    @ViewBuilder
    private func shareDisplayView(index: Int) -> some View {
        @Bindable var service = service
        let words = shareWords(at: index)
        let isLast = index == service.shareCount - 1

        VStack(spacing: 0) {
            CTSettingsSectionHeader(
                title: String(format: NSLocalizedString("social_recovery_share_title", comment: ""),
                              index + 1, service.shareCount)
            )
            .padding(.top, 4)

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(words.indices, id: \.self) { i in
                            wordCell(number: i + 1, word: words[i])
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    Text(NSLocalizedString("social_recovery_share_warning", comment: ""))
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(NSLocalizedString("social_recovery_share_label_caption", comment: ""))
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                        TextField(
                            NSLocalizedString("social_recovery_share_label_placeholder", comment: ""),
                            text: Binding(
                                get: { index < service.shareLabels.count ? service.shareLabels[index] : "" },
                                set: { service.setLabel($0, forShare: index) }
                            )
                        )
                        .autocorrectionDisabled()
                        .autocapNever()
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.text)
                        .padding(10)
                        .background(Color.CT.bg)
                        .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }

            actionButton(
                label: isLast
                    ? NSLocalizedString("social_recovery_share_done", comment: "")
                    : NSLocalizedString("social_recovery_share_next", comment: ""),
                enabled: true
            ) {
                service.markShareDistributed(index: index)
            }
        }
    }

    private func wordCell(number: Int, word: String) -> some View {
        HStack(spacing: 4) {
            Text("\(number).")
                .font(CTFont.regular(10))
                .foregroundColor(Color.CT.textDim)
                .frame(width: 24, alignment: .trailing)
            Text(word)
                .font(CTFont.regular(12))
                .foregroundColor(Color.CT.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.CT.bg)
        .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
    }

    private func shareWords(at index: Int) -> [String] {
        guard index < service.shares.count else { return [] }
        return service.shares[index].split(separator: " ").map(String.init)
    }

    // MARK: - Uploading

    private var uploadingView: some View {
        VStack(spacing: 0) {
            Spacer()
            AnimatedLoadingBlock(label: NSLocalizedString("social_recovery_uploading", comment: ""))
            Spacer()
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("[✓]")
                .font(CTFont.bold(48))
                .foregroundColor(Color.CT.accent)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("social_recovery_done_title", comment: ""))
                .font(CTFont.bold(16))
                .foregroundColor(Color.CT.text)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(service.shareLabels.indices, id: \.self) { i in
                    let label = service.shareLabels[i].isEmpty
                        ? String(format: NSLocalizedString("social_recovery_share_unlabeled", comment: ""), i + 1)
                        : service.shareLabels[i]
                    HStack(spacing: 8) {
                        Text("share \(i + 1)")
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                        Image(systemName: "chevron.right")
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.accent)
                        Text(label)
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.text)
                    }
                }
            }
            .padding(12)
            .background(Color.CT.bg)
            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
            .padding(.horizontal, 20)

            Text(NSLocalizedString("social_recovery_done_body", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            actionButton(label: NSLocalizedString("done", comment: ""), enabled: true) {
                service.reset()
                dismiss()
            }
        }
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text("[!]")
                .font(CTFont.bold(48))
                .foregroundColor(.orange)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("recovery_error_title", comment: ""))
                .font(CTFont.bold(16))
                .foregroundColor(Color.CT.text)
            Text(message)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            actionButton(label: NSLocalizedString("try_again", comment: ""), enabled: true) {
                service.reset()
            }
        }
    }

    // MARK: - Shared button

    private func actionButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(CTFont.regular(13))
                .foregroundColor(enabled ? Color.CT.text : Color.CT.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.CT.bg)
                .overlay(
                    Rectangle().stroke(
                        enabled ? Color.CT.accent : Color.CT.noise,
                        lineWidth: 1
                    )
                )
        }
        .disabled(!enabled)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Animated loading block

private struct AnimatedLoadingBlock: View {
    let label: String
    @State private var frame: Int = 0

    private let frames = [
        "[■□□□□□□□□□]",
        "[■■□□□□□□□□]",
        "[■■■□□□□□□□]",
        "[■■■■□□□□□□]",
        "[■■■■■□□□□□]",
        "[■■■■■■□□□□]",
        "[■■■■■■■□□□]",
        "[■■■■■■■■□□]",
        "[■■■■■■■■■□]",
        "[■■■■■■■■■■]",
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text(frames[frame])
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.accent)
            Text(label)
                .font(CTFont.regular(12))
                .foregroundColor(Color.CT.textDim)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { timer in
                frame = (frame + 1) % frames.count
            }
        }
    }
}
