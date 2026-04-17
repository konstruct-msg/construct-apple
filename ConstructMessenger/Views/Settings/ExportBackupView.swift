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
            CTNavBar(
                title: NSLocalizedString("backup_export_title", comment: ""),
                showBack: step > 0,
                trailingSymbol: CTSymbol.close,
                backAction: { step -= 1 },
                trailingAction: { dismiss() }
            )

            switch step {
            case 0:  warningStep
            case 1:  mnemonicStep
            default: exportStep
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Step 0: Warning

    private var warningStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CTSettingsSectionHeader(title: NSLocalizedString("backup_warning_header", comment: ""))

                Text(NSLocalizedString("backup_export_warning", comment: ""))
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.text)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                Rectangle().fill(Color.CT.noise).frame(height: 1)

                Text(NSLocalizedString("backup_mnemonic_warning", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                Rectangle().fill(Color.CT.noise).frame(height: 1)
                    .padding(.bottom, 24)

                if let err = errorMessage {
                    Text(err)
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                Button { generateAndAdvance() } label: {
                    HStack {
                        if isWorking { ProgressView().tint(Color.CT.bg).padding(.trailing, 6) }
                        Text(NSLocalizedString("backup_generate_button", comment: ""))
                            .font(CTFont.bold(14))
                            .foregroundStyle(Color.CT.bg)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isWorking ? Color.CT.accent.opacity(0.5) : Color.CT.accent)
                }
                .disabled(isWorking)
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
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)

                // 4×3 word grid
                VStack(spacing: 2) {
                    ForEach(0 ..< 4, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0 ..< 3, id: \.self) { col in
                                let idx = row * 3 + col
                                if idx < mnemonicWords.count {
                                    HStack(spacing: 4) {
                                        Text("\(idx + 1).")
                                            .font(CTFont.regular(11))
                                            .foregroundStyle(Color.CT.textDim)
                                            .frame(width: 20, alignment: .trailing)
                                        Text(mnemonicWords[idx])
                                            .font(CTFont.bold(13))
                                            .foregroundStyle(Color.CT.text)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 10)
                                    .background(Color.CT.noise.opacity(0.15))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                Button {
                    PlatformClipboard.copy(mnemonic)
                } label: {
                    Text(NSLocalizedString("backup_copy_words", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.5), lineWidth: 1))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                Rectangle().fill(Color.CT.noise).frame(height: 1)

                Text(NSLocalizedString("backup_mnemonic_warning", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                Rectangle().fill(Color.CT.noise).frame(height: 1)
                    .padding(.bottom, 20)

                Button { confirmedSaved.toggle() } label: {
                    HStack(spacing: 10) {
                        Text(confirmedSaved ? "[✓]" : "[ ]")
                            .font(CTFont.bold(14))
                            .foregroundStyle(confirmedSaved ? Color.CT.accent : Color.CT.textDim)
                        Text(NSLocalizedString("backup_confirm_saved", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)

                Button { step = 2 } label: {
                    Text(NSLocalizedString("backup_next_button", comment: ""))
                        .font(CTFont.bold(14))
                        .foregroundStyle(Color.CT.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(confirmedSaved ? Color.CT.accent : Color.CT.accent.opacity(0.3))
                }
                .disabled(!confirmedSaved)
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
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)

                if let err = errorMessage {
                    Text(err)
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }

                if let url = backupURL {
                    ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                        Text(NSLocalizedString("backup_share_file", comment: ""))
                            .font(CTFont.bold(14))
                            .foregroundStyle(Color.CT.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.CT.accent)
                    }
                    .padding(.horizontal, 20)

                    Text(url.lastPathComponent)
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                } else {
                    Button { generateBackupFile() } label: {
                        HStack {
                            if isWorking { ProgressView().tint(Color.CT.bg).padding(.trailing, 6) }
                            Text(isWorking
                                 ? NSLocalizedString("backup_export_generating", comment: "")
                                 : NSLocalizedString("backup_create_file", comment: ""))
                                .font(CTFont.bold(14))
                                .foregroundStyle(Color.CT.bg)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isWorking ? Color.CT.accent.opacity(0.5) : Color.CT.accent)
                    }
                    .disabled(isWorking)
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
}
