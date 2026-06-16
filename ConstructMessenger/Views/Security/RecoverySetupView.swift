//
//  RecoverySetupView.swift
//  ConstructMessenger
//
//  Flow: Show 12 words → Word quiz (3 random words) → Upload to server
//

import SwiftUI

struct RecoverySetupView: View {
    @Environment(AccountRecoveryViewModel.self) private var vm
    @Environment(AuthViewModel.self) private var authVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("account_recovery_seed", comment: ""),
                showBack: false,
                trailingSymbol: showsCancelButton ? NSLocalizedString("cancel", comment: "") : nil,
                trailingColor: Color.CT.textDim,
                backAction: nil,
                trailingAction: showsCancelButton ? {
                    vm.resetSetup()
                    dismiss()
                } : nil
            )
            Group {
                switch vm.setupStep {
                case .idle:
                    introView
                case .displayWords:
                    wordDisplayView
                case .quiz:
                    quizView
                case .uploading:
                    uploadingView
                case .done(let fingerprint):
                    doneView(fingerprint: fingerprint)
                case .failed(let msg):
                    failedView(message: msg)
                }
            }
        }
        .background(Color.CT.bg)
    }

    private var showsCancelButton: Bool {
        switch vm.setupStep {
        case .done, .uploading: return false
        default: return true
        }
    }

    // MARK: - Intro

    private var introView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("[key]")
                .font(CTFont.bold(48))
                .foregroundColor(Color.CT.accent)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("recovery_intro_title", comment: ""))
                .font(CTFont.bold(18))
                .foregroundColor(Color.CT.text)
                .multilineTextAlignment(.center)
            Text(NSLocalizedString("recovery_intro_body", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                vm.startSetup()
            } label: {
                Text(NSLocalizedString("recovery_generate", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bgMsg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    // MARK: - Word Display (12 words grid)

    private var wordDisplayView: some View {
        VStack(spacing: 16) {
            Text(NSLocalizedString("recovery_write_down", comment: ""))
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(vm.mnemonic.indices, id: \.self) { i in
                    wordCell(index: i, word: vm.mnemonic[i])
                }
            }
            .padding(.horizontal)

            Text(NSLocalizedString("recovery_never_share", comment: ""))
                .font(CTFont.regular(11))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button {
                vm.proceedToQuiz()
            } label: {
                Text(NSLocalizedString("recovery_wrote_it_down", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bgMsg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding(.top)
    }

    private func wordCell(index: Int, word: String) -> some View {
        HStack(spacing: 4) {
            Text("\(index + 1).")
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.textDim)
                .frame(width: 22, alignment: .trailing)
            Text(word)
                .font(CTFont.regular(13))
                .minimumScaleFactor(0.7)
                .foregroundColor(Color.CT.text)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.CT.bgMsg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.noise, lineWidth: 1))
    }

    // MARK: - Quiz

    private var quizView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(NSLocalizedString("recovery_quiz_title", comment: ""))
                    .font(CTFont.bold(14))
                    .foregroundColor(Color.CT.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ForEach(vm.quizIndices, id: \.self) { idx in
                    quizWordField(index: idx)
                }

                Spacer(minLength: 20)

                Button {
                    Task { await vm.submitSetup(userId: authVM.currentUserId ?? "") }
                } label: {
                    Text(NSLocalizedString("recovery_confirm", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(vm.quizPassed ? Color.CT.text : Color.CT.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.CT.bgMsg)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(vm.quizPassed ? Color.CT.accent : Color.CT.noise, lineWidth: 1))
                }
                .disabled(!vm.quizPassed)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top)
        }
    }

    private func quizWordField(index idx: Int) -> some View {
        QuizWordField(vm: vm, index: idx)
    }

    // MARK: - Uploading

    private var uploadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text(NSLocalizedString("recovery_uploading", comment: ""))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Done

    private func doneView(fingerprint: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Text("[✓]")
                .font(CTFont.bold(48))
                .foregroundColor(Color.CT.accent)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("recovery_done_title", comment: ""))
                .font(CTFont.bold(18))
                .foregroundColor(Color.CT.text)
            Text(NSLocalizedString("recovery_done_body", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if !fingerprint.isEmpty {
                VStack(spacing: 4) {
                    Text(NSLocalizedString("recovery_fingerprint", comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.textDim)
                    Text(fingerprint)
                        .font(CTFont.regular(12))
                        .foregroundColor(Color.CT.text)
                        .padding(8)
                        .background(Color.CT.bgMsg)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.noise, lineWidth: 1))
                }
            }
            Spacer()
            Button {
                vm.resetSetup()
                dismiss()
            } label: {
                Text(NSLocalizedString("done", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bgMsg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTFont.regular(48))
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
                vm.resetSetup()
            } label: {
                Text(NSLocalizedString("try_again", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bgMsg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

// MARK: - Quiz Word Field

private struct QuizWordField: View {
    @Bindable var vm: AccountRecoveryViewModel
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: NSLocalizedString("recovery_quiz_word_n", comment: ""), index + 1))
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.textDim)
            TextField(
                NSLocalizedString("recovery_quiz_placeholder", comment: ""),
                text: Binding(
                    get: { vm.quizAnswers[index] ?? "" },
                    set: { vm.quizAnswers[index] = $0 }
                )
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(CTFont.regular(13))
            .foregroundColor(Color.CT.text)
            .padding(10)
            .background(Color.CT.bgMsg)
            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
        }
        .padding(.horizontal)
    }
}

// MARK: - Previews

@MainActor
private func makePreviewVM(step: AccountRecoveryViewModel.SetupStep) -> AccountRecoveryViewModel {
    let vm = AccountRecoveryViewModel()
    let words = ["abandon", "ability", "able", "about", "above", "absent",
                 "absorb", "abstract", "absurd", "abuse", "access", "accident"]
    vm.mnemonic = words
    vm.quizIndices = [0, 5, 11]
    vm.setupStep = step
    return vm
}

#if DEBUG
#Preview("Intro") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    return RecoverySetupView()
        .environment(makePreviewVM(step: .idle))
        .environment(authVM)
}

#Preview("Word display") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    return RecoverySetupView()
        .environment(makePreviewVM(step: .displayWords))
        .environment(authVM)
}

#Preview("Quiz") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    return RecoverySetupView()
        .environment(makePreviewVM(step: .quiz))
        .environment(authVM)
}

#Preview("Done") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    return RecoverySetupView()
        .environment(makePreviewVM(step: .done(fingerprint: "A1B2:C3D4:E5F6:7890")))
        .environment(authVM)
}

#Preview("Failed") {
    let container = PreviewHelpers.createPreviewContainer()
    let authVM = AuthViewModel(context: container.viewContext)
    authVM.configureMockAuth()
    return RecoverySetupView()
        .environment(makePreviewVM(step: .failed("Server unavailable. Please try again later.")))
        .environment(authVM)
}

#endif
