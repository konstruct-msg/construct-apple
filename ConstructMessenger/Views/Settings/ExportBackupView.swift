//
//  ExportBackupView.swift
//  Construct Messenger
//
//  Three-step local backup export wizard:
//    Step 0 — Warning: explain what a backup is and its risks
//    Step 1 — Mnemonic: display 12-word phrase, require confirmation
//    Step 2 — Export: generate encrypted .ctbackup file and share it
//

import SwiftUI
import CoreData

struct ExportBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    private let service = LocalBackupService.shared

    @State private var step = 0
    @State private var mnemonic = ""
    @State private var mnemonicWords: [String] = []
    @State private var confirmedSaved = false
    @State private var isWorking = false
    @State private var backupURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case 0:  warningStep
            case 1:  mnemonicStep
            default: exportStep
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .screenTitle(NSLocalizedString("backup_export_title", comment: ""))
        // Steps go back inside the sheet; close leaves it from any step.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { dismiss() }
            }
            if step > 0 {
                ToolbarItem(placement: .navigation) {
                    Button { step -= 1 } label: {
                        Label(NSLocalizedString("back", comment: ""), systemImage: "chevron.backward")
                    }
                    .barItem()
                }
            }
        }
    }

    // MARK: - Step 0: Warning

    private var warningStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CTSettingsSectionHeader(title: NSLocalizedString("backup_warning_header", comment: ""))

                Text(NSLocalizedString("backup_export_warning", comment: ""))
                    .font(CTFont.ui(14))
                    .foregroundStyle(Color.CT.text)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                Rectangle().fill(Color.CT.noise).frame(height: 1)

                Text(NSLocalizedString("backup_mnemonic_warning", comment: ""))
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                Rectangle().fill(Color.CT.noise).frame(height: 1)
                    .padding(.bottom, 24)

                if let err = errorMessage {
                    Text(err)
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.danger)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                CTButton(
                    label: NSLocalizedString("backup_generate_button", comment: ""),
                    isLoading: isWorking
                ) { generateAndAdvance() }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step 1: Mnemonic

    private var mnemonicStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CTSettingsSectionHeader(title: NSLocalizedString("backup_mnemonic_title", comment: ""))

                Text(NSLocalizedString("backup_mnemonic_subtitle", comment: ""))
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)

                // Safe 12-word grid using snapshot + private indexed helper
                let words = mnemonicWords
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    forEachIndexed(words) { idx, word in
                        HStack(spacing: 4) {
                            Text("\(idx + 1).")
                                .font(CTFont.caption)
                                .foregroundStyle(Color.CT.textDim)
                                .frame(width: 20, alignment: .trailing)
                            Text(word)
                                .font(CTFont.bodyEmphasis)
                                .foregroundStyle(Color.CT.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .background(Color.CT.noise.opacity(0.15))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                CTButton(label: NSLocalizedString("backup_copy_words", comment: ""), role: .secondary) {
                    PlatformClipboard.copy(mnemonic)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                Rectangle().fill(Color.CT.noise).frame(height: 1)

                Text(NSLocalizedString("backup_mnemonic_warning", comment: ""))
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                Rectangle().fill(Color.CT.noise).frame(height: 1)
                    .padding(.bottom, 20)

                // A state the next step waits on, so a switch — not a drawn checkbox.
                Toggle(isOn: $confirmedSaved) {
                    Text(NSLocalizedString("backup_confirm_saved", comment: ""))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.text)
                }
                .tint(Color.CT.accent)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                CTButton(label: NSLocalizedString("backup_next_button", comment: ""), isEnabled: confirmedSaved) {
                    step = 2
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step 2: Export

    private var exportStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CTSettingsSectionHeader(title: NSLocalizedString("backup_export_step_header", comment: ""))

                Text(NSLocalizedString("backup_export_step_subtitle", comment: ""))
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)

                if let err = errorMessage {
                    Text(err)
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.danger)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }

                if let url = backupURL {
                    ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                        Text(NSLocalizedString("backup_share_file", comment: ""))
                    }
                    .buttonStyle(CTButtonStyle(role: .primary))
                    .padding(.horizontal, 20)

                    Text(url.lastPathComponent)
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                } else {
                    CTButton(
                        label: NSLocalizedString(isWorking ? "backup_export_generating" : "backup_create_file", comment: ""),
                        isLoading: isWorking
                    ) { generateBackupFile() }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Actions

    private func generateAndAdvance() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let m = try service.newMnemonic()
                mnemonic = m
                mnemonicWords = m.split(separator: " ").map(String.init)
                step = 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func generateBackupFile() {
        isWorking = true
        errorMessage = nil
        backupURL = nil
        Task {
            do {
                backupURL = try await service.exportBackup(mnemonic: mnemonic, context: viewContext)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    // Small private helper for safe ForEach over arrays that may be @State / @Observable.
    // Captures a snapshot to protect against length changes during view updates.
    @ViewBuilder
    private func forEachIndexed<T, Content: View>(
        _ items: [T],
        @ViewBuilder content: @escaping (Int, T) -> Content
    ) -> some View {
        let snapshot = items
        ForEach(Array(snapshot.enumerated()), id: \.offset) { pair in
            content(pair.offset, pair.element)
        }
    }
}
