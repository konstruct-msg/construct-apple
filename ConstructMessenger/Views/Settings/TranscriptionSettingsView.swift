//
//  TranscriptionSettingsView.swift
//  Construct Messenger
//
//  Dedicated screen for on-device voice transcription settings.
//  Moved out of Data & Storage because engine/model choice is not storage-related.
//

import SwiftUI

struct TranscriptionSettingsView: View {
    var showNavBar: Bool = true

    init(showNavBar: Bool = true) {
        self.showNavBar = showNavBar
    }

    @Environment(\.dismiss) private var dismiss
    
    @AppStorage(ChatViewModel.continuousVoicePlaybackKey)
    private var continuousVoicePlayback: Bool = false
    
    var body: some View {
        if showNavBar {
            CTNavBar(
                title: NSLocalizedString("trasncription", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
        }
        ScrollView {
            VStack(spacing: 0) {
                // MARK: Voice messages (playback behaviour)
                CTSettingsSectionHeader(title: NSLocalizedString("voice_section_title", comment: ""))
                CTSectionGroup {
                    HStack {
                        Text(NSLocalizedString("voice_continuous_playback", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        Toggle("", isOn: $continuousVoicePlayback)
                            .labelsHidden()
                            .tint(Color.CT.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                sectionFooter("voice_continuous_playback_footer")

                // Transcription (engine + models) moved to its own top-level section
                // (see TranscriptionSettingsView) because it's not purely storage-related.
                STTSettingsSection()
            }
            .padding(.bottom, DataStorageSettingsLayout.screenBottomPadding)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

@ViewBuilder
private func sectionFooter(_ key: String) -> some View {
    Text(LocalizedStringKey(key))
        .font(CTFont.regular(11))
        .foregroundStyle(Color.CT.textDim)
        .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
        .padding(.top, DataStorageSettingsLayout.footerTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
}

#if DEBUG
#Preview {
    NavigationStack {
        TranscriptionSettingsView()
    }
    .preferredColorScheme(.dark)
}
#endif
