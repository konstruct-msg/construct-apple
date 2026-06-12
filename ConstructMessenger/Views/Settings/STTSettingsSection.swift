//
//  STTSettingsSection.swift
//  Construct Messenger
//
//  On-device transcription model management section for DataStorageSettingsView.
//

import SwiftUI

// Languages Whisper supports well (ISO 639-1 codes).
private let sttSupportedLanguages: [(code: String, name: String)] = {
    let codes = ["en", "ru", "de", "fr", "es", "pt", "it", "nl", "pl", "uk",
                 "tr", "ar", "ja", "zh", "ko", "sv", "da", "fi", "no", "cs",
                 "sk", "ro", "hu", "bg", "hr", "sr", "vi", "id", "ms", "th"]
    let display = Locale.current
    return codes.compactMap { code in
        guard let name = display.localizedString(forLanguageCode: code) else { return nil }
        return (code: code, name: name)
    }.sorted { $0.name < $1.name }
}()

struct STTSettingsSection: View {

    @StateObject private var modelManager = WhisperModelManager.shared

    @AppStorage("stt_auto_transcribe") private var autoTranscribe: Bool = false
    @AppStorage("stt_preferred_model") private var preferredModelRaw: String = WhisperModel.tiny.rawValue
    @AppStorage("stt_translate")       private var translateEnabled: Bool = false
    @AppStorage("stt_language")        private var transcriptionLanguage: String = "auto"

    @State private var isDownloading: WhisperModel? = nil
    @State private var showDeleteConfirm: WhisperModel? = nil
    @State private var showLanguagePicker: Bool = false

    private var preferredModel: WhisperModel {
        WhisperModel(rawValue: preferredModelRaw) ?? .tiny
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSettingsSectionHeader(title: NSLocalizedString("stt_section_title", comment: ""))

            CTSectionGroup {
                // Auto-transcribe toggle
                HStack {
                    Text(NSLocalizedString("stt_auto_transcribe", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                    Spacer()
                    Toggle("", isOn: $autoTranscribe)
                        .labelsHidden()
                        .tint(Color.CT.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                CTSep(style: .thin)

                // Translation toggle
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("stt_translate_toggle", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Text(NSLocalizedString("stt_translate_footer", comment: ""))
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim.opacity(0.6))
                    }
                    Spacer()
                    Toggle("", isOn: $translateEnabled)
                        .labelsHidden()
                        .tint(Color.CT.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                CTSep(style: .thin)

                // Language picker row
                languageRow

                CTSep(style: .thick)

                // Total size on disk
                let totalSize = modelManager.totalSizeOnDisk()
                CTSettingsRow(
                    label: NSLocalizedString("stt_models_on_disk", comment: ""),
                    value: totalSize > 0 ? formatBytes(totalSize) : NSLocalizedString("stt_no_models", comment: "")
                )

                // Per-model rows
                ForEach(WhisperModel.allCases) { model in
                    CTSep(style: .thin)
                    modelRow(model)
                }
            }

            Text(NSLocalizedString("stt_footer", comment: ""))
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var languageRow: some View {
        let currentName: String = {
            if transcriptionLanguage == "auto" || transcriptionLanguage.isEmpty {
                return NSLocalizedString("stt_language_auto", comment: "")
            }
            return Locale.current.localizedString(forLanguageCode: transcriptionLanguage) ?? transcriptionLanguage.uppercased()
        }()

        #if os(iOS)
        NavigationLink {
            sttLanguagePickerList
        } label: {
            CTSettingsRow(
                label: NSLocalizedString("stt_language_label", comment: ""),
                value: currentName,
                isAction: true,
                disclosure: true
            )
        }
        #else
        HStack {
            Text(NSLocalizedString("stt_language_label", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
            Spacer()
            Menu(currentName) {
                Button(NSLocalizedString("stt_language_auto", comment: "")) {
                    transcriptionLanguage = "auto"
                }
                Divider()
                ForEach(sttSupportedLanguages, id: \.code) { lang in
                    Button(lang.name) { transcriptionLanguage = lang.code }
                }
            }
            .font(CTFont.regular(13))
            .foregroundColor(Color.CT.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        #endif
    }

    @ViewBuilder
    private var sttLanguagePickerList: some View {
        List {
            Button {
                transcriptionLanguage = "auto"
            } label: {
                HStack {
                    Text(NSLocalizedString("stt_language_auto", comment: ""))
                    Spacer()
                    if transcriptionLanguage == "auto" || transcriptionLanguage.isEmpty {
                        Image(systemName: "checkmark").foregroundColor(Color.CT.accent)
                    }
                }
            }
            .foregroundColor(Color.CT.text)
            ForEach(sttSupportedLanguages, id: \.code) { lang in
                Button {
                    transcriptionLanguage = lang.code
                } label: {
                    HStack {
                        Text(lang.name)
                        Spacer()
                        if transcriptionLanguage == lang.code {
                            Image(systemName: "checkmark").foregroundColor(Color.CT.accent)
                        }
                    }
                }
                .foregroundColor(Color.CT.text)
            }
        }
        .navigationTitle(NSLocalizedString("stt_language_label", comment: ""))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let state = modelManager.modelStates[model] ?? .notDownloaded
        HStack(spacing: 0) {
            Text(model.displayName)
                .font(CTFont.regular(13))
                .foregroundColor(preferredModel == model ? Color.CT.accent : Color.CT.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

            Spacer()

            stateView(model: model, state: state)
                .padding(.trailing, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .downloaded = state {
                preferredModelRaw = model.rawValue
            } else if case .ready = state {
                preferredModelRaw = model.rawValue
            }
        }
        .confirmationDialog(
            NSLocalizedString("stt_delete_confirm_title", comment: ""),
            isPresented: Binding(
                get: { showDeleteConfirm == model },
                set: { if !$0 { showDeleteConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("stt_delete_model", comment: ""), role: .destructive) {
                modelManager.deleteModel(model)
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func stateView(model: WhisperModel, state: WhisperModelState) -> some View {
        switch state {
        case .notDownloaded:
            Button {
                Task { await modelManager.downloadModel(model) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                    Text(NSLocalizedString("stt_download", comment: ""))
                        .font(CTFont.regular(12))
                }
                .foregroundColor(Color.CT.accent)
            }
            .buttonStyle(.plain)

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .scaleEffect(0.65)
                    .tint(Color.CT.accent)
                Text(String(format: "%.0f%%", progress * 100))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
            }

        case .downloaded, .ready:
            HStack(spacing: 8) {
                if preferredModel == model {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.CT.accent)
                        .font(.system(size: 14))
                }
                Button {
                    showDeleteConfirm = model
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(Color.CT.textDim)
                }
                .buttonStyle(.plain)
            }

        case .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.65)
                .tint(Color.CT.accent)

        case .failed(let reason):
            // Tap-to-retry replaces a dead-end static error. Reason still
            // surfaces via VoiceOver / `Log.error` in WhisperModelManager.
            Button {
                Task { await modelManager.downloadModel(model) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 13))
                    Text(NSLocalizedString("stt_retry_download", comment: ""))
                        .font(CTFont.regular(12))
                }
                .foregroundColor(Color.CT.danger)
            }
            .buttonStyle(.plain)
            .accessibilityHint(reason)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
