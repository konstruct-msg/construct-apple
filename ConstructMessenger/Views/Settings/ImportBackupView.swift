//
//  ImportBackupView.swift
//  Construct Messenger
//
//  Restore from an encrypted .ctbackup file using a 12-word BIP39 mnemonic.
//  Decrypts and stages the backup files; the restore is applied on next app launch
//  by PersistenceController before Core Data opens the store.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportBackupView: View {
    @Environment(\.dismiss) private var dismiss

    private let service = LocalBackupService.shared

    @State private var mnemonicText = ""
    @State private var selectedFileURL: URL?
    @State private var showingFilePicker = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showingRestartAlert = false

    private var wordCount: Int { mnemonicText.split(separator: " ").count }
    private var canRestore: Bool { selectedFileURL != nil && wordCount == 12 }

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("backup_import_title", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    CTSettingsSectionHeader(
                        title: NSLocalizedString("backup_import_words_header", comment: "")
                    )

                    Text(NSLocalizedString("backup_import_words_subtitle", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 12)

                    TextEditor(text: $mnemonicText)
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                        .scrollContentBackground(.hidden)
                        .background(Color.CT.noise.opacity(0.1))
                        .frame(height: 96)
                        .padding(10)
                        .overlay(
                            Rectangle()
                                .stroke(Color.CT.noise.opacity(0.4), lineWidth: 1)
                                .padding(10)
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 20)

                    HStack {
                        Text("\(wordCount)/12")
                            .font(CTFont.regular(11))
                            .foregroundStyle(wordCount == 12 ? Color.CT.accent : Color.CT.textDim)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 16)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    CTSettingsSectionHeader(
                        title: NSLocalizedString("backup_import_file_header", comment: "")
                    )

                    Button { showingFilePicker = true } label: {
                        HStack {
                            if let url = selectedFileURL {
                                Text(url.lastPathComponent)
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(NSLocalizedString("backup_import_select_file", comment: ""))
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.accent)
                            }
                            Spacer()
                            Text("[→]")
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.accent)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)
                        .padding(.bottom, 20)

                    Text(NSLocalizedString("backup_restore_warning", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                    Rectangle().fill(Color.CT.noise).frame(height: 1)
                        .padding(.bottom, 20)

                    if let err = errorMessage {
                        Text(err)
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.danger)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }

                    Button { startRestore() } label: {
                        HStack {
                            if isImporting { ProgressView().tint(Color.CT.bg).padding(.trailing, 6) }
                            Text(NSLocalizedString("backup_restore_button", comment: ""))
                                .font(CTFont.bold(14))
                                .foregroundStyle(Color.CT.bg)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            canRestore && !isImporting
                                ? Color.CT.danger
                                : Color.CT.danger.opacity(0.3)
                        )
                    }
                    .disabled(!canRestore || isImporting)
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.ctbackup],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                if (try? FileManager.default.copyItem(at: url, to: tempURL)) != nil {
                    selectedFileURL = tempURL
                } else {
                    selectedFileURL = url
                }
                if accessed { url.stopAccessingSecurityScopedResource() }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert(LocalizedStringKey("backup_restore_success_title"), isPresented: $showingRestartAlert) {
            Button(LocalizedStringKey("ok"), role: .cancel) { dismiss() }
        } message: {
            Text(LocalizedStringKey("backup_restore_success_message"))
        }
    }

    // MARK: - Action

    private func startRestore() {
        guard let fileURL = selectedFileURL else { return }
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let trimmed = mnemonicText.trimmingCharacters(in: .whitespacesAndNewlines)
                try await service.importBackup(from: fileURL, mnemonic: trimmed)
                showingRestartAlert = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

// MARK: - UTType

extension UTType {
    static let ctbackup = UTType(filenameExtension: "ctbackup") ?? .data
}
