//
//  SocialRecoveryEntryView.swift
//  ConstructMessenger
//
//  SLIP-39 social recovery — enter shares from trustees to restore identity.
//

import SwiftUI

struct SocialRecoveryEntryView: View {
    @Environment(SocialRecoveryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddSheet = false
    @State private var username: String = ""

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("social_recovery_enter_title", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )

            switch service.recoveryStep {
            case .idle, .enterShares:
                enterSharesView
            case .reconstructing:
                reconstructingView
            case .done:
                recoveryDoneView
            case .failed(let msg):
                recoveryFailedView(message: msg)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .sheet(isPresented: $showingAddSheet) {
            AddShareSheet(service: service)
        }
        .onAppear {
            if service.recoveryStep == .idle {
                service.recoveryStep = .enterShares
            }
        }
    }

    // MARK: - Enter shares

    private var enterSharesView: some View {
        @Bindable var service = service
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(NSLocalizedString("social_recovery_enter_subtitle", comment: ""))
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.textDim)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    CTSettingsSectionHeader(
                        title: NSLocalizedString("social_recovery_identity_header", comment: "")
                    )

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    HStack {
                        Text(NSLocalizedString("social_recovery_username_label", comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        TextField("@handle", text: $username)
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.text)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    CTSettingsSectionHeader(
                        title: String(
                            format: NSLocalizedString("social_recovery_entered_header", comment: ""),
                            service.enteredShares.count,
                            service.threshold
                        )
                    )

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    if service.enteredShares.isEmpty {
                        Text(NSLocalizedString("social_recovery_no_shares_yet", comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(service.enteredShares.indices, id: \.self) { i in
                            enteredShareRow(index: i)
                            Rectangle().fill(Color.CT.noise.opacity(0.4)).frame(height: 1).padding(.horizontal, 20)
                        }
                    }

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    // Add share button
                    Button {
                        showingAddSheet = true
                    } label: {
                        HStack {
                            Text(NSLocalizedString("social_recovery_add_share", comment: ""))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.accent)
                            Spacer()
                            Text("[→]")
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.accent)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    if sharesNeeded > 0 {
                        Text(String(format: NSLocalizedString("social_recovery_shares_needed", comment: ""), sharesNeeded))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                }
            }

            restoreButton
        }
    }

    private var sharesNeeded: Int {
        max(0, service.threshold - service.enteredShares.count)
    }

    private func enteredShareRow(index: Int) -> some View {
        let words = service.enteredShares[index].split(separator: " ").map(String.init)
        let preview = words.prefix(3).joined(separator: " ") + (words.count > 3 ? "..." : "")

        return HStack(alignment: .top, spacing: 12) {
            Text("■")
                .font(CTFont.regular(12))
                .foregroundColor(Color.CT.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: NSLocalizedString("social_recovery_share_n", comment: ""), index + 1))
                    .font(CTFont.bold(12))
                    .foregroundColor(Color.CT.text)
                Text(preview)
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
                Text(String(format: NSLocalizedString("social_recovery_word_count", comment: ""), words.count))
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.accent)
            }
            Spacer()
            Button {
                service.removeEnteredShare(at: index)
            } label: {
                Text("[" + NSLocalizedString("remove", comment: "") + "]")
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.CT.bg)
    }

    private var restoreButton: some View {
        let enabled = service.enteredShares.count >= service.threshold && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            Task { await service.reconstructAndRestore(username: username.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } label: {
            Text(NSLocalizedString("social_recovery_restore", comment: ""))
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

    // MARK: - Reconstructing

    private var reconstructingView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Text("[■■■□□□□□□□]")
                    .font(CTFont.bold(14))
                    .foregroundColor(Color.CT.accent)
                Text(NSLocalizedString("social_recovery_reconstructing", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
            }
            Spacer()
        }
    }

    // MARK: - Done

    private var recoveryDoneView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("[✓]")
                .font(CTFont.bold(48))
                .foregroundColor(Color.CT.accent)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("social_recovery_restored_title", comment: ""))
                .font(CTFont.bold(16))
                .foregroundColor(Color.CT.text)
                .multilineTextAlignment(.center)
            Text(NSLocalizedString("social_recovery_restored_body", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                service.reset()
                dismiss()
            } label: {
                Text(NSLocalizedString("done", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bg)
                    .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Failed

    private func recoveryFailedView(message: String) -> some View {
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
            Button {
                service.recoveryStep = .enterShares
            } label: {
                Text(NSLocalizedString("try_again", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bg)
                    .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Add Share Sheet

private struct AddShareSheet: View {
    var service: SocialRecoveryService
    @Environment(\.dismiss) private var dismiss
    @State private var wordsInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("social_recovery_enter_words_title", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )

            Rectangle().fill(Color.CT.noise).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("social_recovery_enter_words_hint", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                    .padding(.top, 4)

                TextEditor(text: $wordsInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.CT.bg)
                    .frame(minHeight: 140)
                    .padding(10)
                    .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))

                let wordCount = wordsInput.split(separator: " ").count
                Text(String(format: NSLocalizedString("social_recovery_word_count", comment: ""), wordCount))
                    .font(CTFont.regular(11))
                    .foregroundColor(wordCount == 28 ? Color.CT.accent : Color.CT.textDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Spacer()

            Button {
                service.addEnteredShare(wordsInput)
                dismiss()
            } label: {
                Text(NSLocalizedString("social_recovery_add_share_confirm", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(canConfirm ? Color.CT.text : Color.CT.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bg)
                    .overlay(
                        Rectangle().stroke(canConfirm ? Color.CT.accent : Color.CT.noise, lineWidth: 1)
                    )
            }
            .disabled(!canConfirm)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    private var canConfirm: Bool {
        wordsInput.split(separator: " ").count >= 20
    }
}
