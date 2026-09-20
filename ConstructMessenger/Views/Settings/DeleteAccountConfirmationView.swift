//
//  DeleteAccountConfirmationView.swift
//  ConstructMessenger
//
//  Shared iOS + Desktop confirmation for identity deletion. The wipe is the
//  same operation on both platforms, so the commit/abort sequence is too:
//  tap starts a 10s abort window; the same button becomes abort; elapsed
//  without abort fires the delete RPC. Local-only fallback after a server
//  failure. Do not reintroduce a pre-enable countdown (the old Desktop sheet).
//

import SwiftUI

struct DeleteAccountConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    let onDelete: () -> Void
    let onCancel: () -> Void

    /// Undo-send pattern: nil = idle (delete button is the primary action and
    /// fires immediately on tap); non-nil = countdown is running, the same
    /// button is now an abort, and on reaching 0 the actual delete RPC fires.
    /// Gives the user a window to change their mind AFTER committing.
    @State private var pendingSecondsLeft: Int? = nil
    @State private var pendingTask: Task<Void, Never>? = nil
    @State private var showLocalDeleteConfirm = false

    var body: some View {
        VStack(spacing: DeleteAccountSheetLayout.rootSpacing) {
            #if os(iOS)
            Capsule()
                .fill(Color.CT.noise)
                .frame(
                    width: DeleteAccountSheetLayout.dragIndicatorWidth,
                    height: DeleteAccountSheetLayout.dragIndicatorHeight
                )
                .padding(.top, DeleteAccountSheetLayout.dragIndicatorTopPadding)
                .padding(.bottom, DeleteAccountSheetLayout.dragIndicatorBottomPadding)
            #else
            HStack {
                Spacer()
                Button(action: dismissWithoutDeleting) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.CT.textDim)
                }
                .buttonStyle(.plain)
                .disabled(authViewModel.isLoading)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.top, CTLayout.edgePad)
            #endif

            Spacer()

            Text(LocalizedStringKey("delete_my_account"))
                .font(CTFont.bold(20))
                .foregroundStyle(Color.CT.text)
                .padding(.bottom, DeleteAccountSheetLayout.titleBottomPadding)

            Text(LocalizedStringKey("delete_account_confirmation_message"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DeleteAccountSheetLayout.messageHorizontalPadding)
                .padding(.bottom, DeleteAccountSheetLayout.messageBottomPadding)

            if authViewModel.deleteAccountFailed {
                Button {
                    showLocalDeleteConfirm = true
                } label: {
                    Text(LocalizedStringKey("delete_account_local_only"))
                        .font(CTFont.regular(12))
                        .underline()
                        .foregroundStyle(Color.CT.danger.opacity(DeleteAccountSheetLayout.localDeleteWarningOpacity))
                }
                .buttonStyle(.plain)
                .padding(.bottom, DeleteAccountSheetLayout.localDeleteActionBottomPadding)
            }

            Spacer()

            VStack(spacing: DeleteAccountSheetLayout.actionsSpacing) {
                if authViewModel.isLoading {
                    ProgressView()
                        .tint(Color.CT.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: DeleteAccountSheetLayout.actionButtonHeight)
                } else if let secondsLeft = pendingSecondsLeft {
                    abortButton(secondsLeft: secondsLeft)
                } else {
                    Button {
                        startPendingDelete()
                    } label: {
                        Text(LocalizedStringKey("delete_account"))
                            .font(CTFont.bold(16))
                            .frame(maxWidth: .infinity)
                            .frame(height: DeleteAccountSheetLayout.actionButtonHeight)
                            .background(
                                CTShape.card()
                                    .fill(Color.CT.danger.opacity(DeleteAccountSheetLayout.deleteButtonActiveFillOpacity))
                                    .overlay(
                                        CTShape.card()
                                            .strokeBorder(
                                                Color.CT.danger.opacity(DeleteAccountSheetLayout.deleteButtonActiveStrokeOpacity),
                                                lineWidth: DeleteAccountSheetLayout.deleteButtonStrokeWidth
                                            )
                                    )
                            )
                            .foregroundStyle(Color.CT.danger)
                    }
                    .buttonStyle(.plain)
                }

                // Cancel hidden during the abort window — the big button IS the abort
                // (a separate "Cancel" beside it would let the user cancel-abort,
                // i.e., proceed with deletion. Confusing. Keep one path.)
                if pendingSecondsLeft == nil {
                    Button(action: dismissWithoutDeleting) {
                        Text(LocalizedStringKey("cancel"))
                            .font(CTFont.regular(15))
                            .foregroundStyle(Color.CT.textDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(authViewModel.isLoading)
                }
            }
            .padding(.horizontal, DeleteAccountSheetLayout.actionsHorizontalPadding)
            .padding(.bottom, DeleteAccountSheetLayout.actionsBottomPadding)
        }
        .background(Color.CT.bg)
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        #else
        .frame(
            width: DeleteAccountSheetLayout.macOSSheetWidth,
            height: DeleteAccountSheetLayout.macOSSheetHeight
        )
        .toolbar(removing: .title)
        #endif
        .alert("delete_account_local_only_title", isPresented: $showLocalDeleteConfirm) {
            Button("delete_account_local_only_confirm", role: .destructive) {
                authViewModel.deleteAccountLocally()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("delete_account_local_only_warning")
        }
        .onChange(of: authViewModel.isLoading) { _, loading in
            if loading { authViewModel.deleteAccountFailed = false }
        }
        .onDisappear {
            pendingTask?.cancel()
            pendingTask = nil
            pendingSecondsLeft = nil
        }
        .onChange(of: authViewModel.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated { dismiss() }
        }
        .interactiveDismissDisabled(authViewModel.isLoading)
    }

    /// Pending-state button: the same red rectangle as the idle delete, but
    /// the tap now aborts. Below it a thin progress bar grows left-to-right
    /// as the abort window elapses.
    private func abortButton(secondsLeft: Int) -> some View {
        let total = DeleteAccountSheetLayout.abortWindowSeconds
        let elapsedFraction = CGFloat(max(0, total - secondsLeft)) / CGFloat(total)
        return VStack(spacing: 6) {
            Button {
                abortPendingDelete()
            } label: {
                Text(String(format: NSLocalizedString("delete_account_abort_hint", comment: ""), secondsLeft))
                    .font(CTFont.bold(15))
                    .frame(maxWidth: .infinity)
                    .frame(height: DeleteAccountSheetLayout.actionButtonHeight)
                    .background(
                        CTShape.card()
                            .fill(Color.CT.danger.opacity(DeleteAccountSheetLayout.deleteButtonIdleFillOpacity))
                            .overlay(
                                CTShape.card()
                                    .strokeBorder(
                                        Color.CT.danger,
                                        lineWidth: DeleteAccountSheetLayout.deleteButtonStrokeWidth
                                    )
                            )
                    )
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.CT.danger.opacity(0.2))
                    Rectangle()
                        .fill(Color.CT.danger)
                        .frame(width: geo.size.width * elapsedFraction)
                        .animation(.linear(duration: DeleteAccountSheetLayout.countdownStepSeconds), value: elapsedFraction)
                }
            }
            .frame(height: 3)
        }
    }

    private func startPendingDelete() {
        let total = DeleteAccountSheetLayout.abortWindowSeconds
        pendingSecondsLeft = total
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            for n in (0..<total).reversed() {
                try? await Task.sleep(for: .seconds(DeleteAccountSheetLayout.countdownStepSeconds))
                if Task.isCancelled { return }
                pendingSecondsLeft = n
            }
            if Task.isCancelled { return }
            pendingSecondsLeft = nil
            pendingTask = nil
            onDelete()
        }
    }

    private func abortPendingDelete() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingSecondsLeft = nil
    }

    private func dismissWithoutDeleting() {
        abortPendingDelete()
        onCancel()
        dismiss()
    }
}
