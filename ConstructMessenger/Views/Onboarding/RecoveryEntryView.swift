//
//  RecoveryEntryView.swift
//  ConstructMessenger
//
//  Used from Onboarding when user taps "Restore from recovery key".
//  Lets user enter their 12-word BIP39 phrase and recover their account
//  on a new device.
//

import SwiftUI

struct RecoveryEntryView: View {
    @Environment(AccountRecoveryViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch vm.recoverStep {
                case .idle, .enterPhrase:
                    entryView
                case .recovering:
                    recoveringView
                case .done:
                    doneView
                case .failed(let msg):
                    failedView(message: msg)
                }
            }
            .navigationTitle(NSLocalizedString("onboarding_restore", comment: ""))
            #if os(iOS)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .recovering = vm.recoverStep { EmptyView() }
                    else if case .done = vm.recoverStep { EmptyView() }
                    else {
                        Button(NSLocalizedString("cancel", comment: "")) {
                            vm.resetRecover()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { vm.startRecover() }
        }
    }

    // MARK: - Entry

    @FocusState private var focusedField: Int?

    private var entryView: some View {
        @Bindable var vm = vm
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(NSLocalizedString("recovery_entry_instructions", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                // Identifier
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("recovery_identifier_label", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(NSLocalizedString("recovery_identifier_placeholder", comment: ""),
                              text: $vm.recoverIdentifier)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(10)
                        .background(Color.CT.bgMsg)
                        .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
                }
                .padding(.horizontal)

                // 12-word grid
                Text(NSLocalizedString("recovery_enter_phrase", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(0..<12, id: \.self) { i in
                        wordField(index: i)
                    }
                }
                .padding(.horizontal)

                if !vm.enteredMnemonic.isEmpty && !vm.enteredMnemonicValid {
                    Text(NSLocalizedString("recovery_invalid_phrase", comment: ""))
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Button {
                    Task { await vm.submitRecover() }
                } label: {
                    Text(NSLocalizedString("recovery_restore_account", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.CT.bgMsg)
                        .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 1))
                }
                .disabled(!vm.enteredMnemonicValid || vm.recoverIdentifier.isEmpty)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top)
        }
    }

    private func wordField(index: Int) -> some View {
        @Bindable var vm = vm
        return HStack(spacing: 4) {
            Text("\(index + 1).")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .trailing)
            TextField("", text: $vm.enteredWords[index])
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(index < 11 ? .next : .done)
                #endif
                .font(.system(.body, design: .monospaced))
                .focused($focusedField, equals: index)
                .onSubmit {
                    if index < 11 { focusedField = index + 1 }
                    else { focusedField = nil }
                }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.CT.bgMsg)
        .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
    }

    // MARK: - Recovering

    private var recoveringView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text(NSLocalizedString("recovery_in_progress", comment: ""))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checknmark.circle.fill")
                .font(CTFont.regular(48))
                .foregroundColor(Color.CT.accent)
                .lineLimit(1).fixedSize()
            Text(NSLocalizedString("recovery_restored_title", comment: ""))
                .font(CTFont.bold(18))
                .foregroundColor(Color.CT.text)
            Text(NSLocalizedString("recovery_restored_body", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                vm.resetRecover()
                dismiss()
            } label: {
                Text(NSLocalizedString("done", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bgMsg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
                vm.recoverStep = .enterPhrase
            } label: {
                Text(NSLocalizedString("try_again", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.CT.bgMsg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.CT.accent, lineWidth: 1))
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}
