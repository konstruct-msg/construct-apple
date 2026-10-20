//
//  UploadingFilesView.swift
//  Construct Messenger
//
//  The in-flight file-upload rows of a media bubble, split out of MediaMessageView.swift.
//

import SwiftUI

/// The files of a send still uploading, drawn as the file bubble will draw them — symbol, name,
/// size — with the upload's progress under them. Until 2026-10-06 a set of files was one empty
/// photo cell captioned with the first file's name (TODO 10).
struct UploadingFilesView: View {
    let files: [(name: String, size: Int?)]
    let caption: String
    let messageId: String
    let isUploading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CTRadius.badge) {
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: CTLayout.chromeGap) {
                    Image(systemName: FileAttachmentBubbleView.symbolName(for: file.name))
                        .font(CTIcon.font(CTIcon.navLg, weight: .regular))
                        .foregroundStyle(Color.CT.outMsgText)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(CTFont.ui(13, weight: .medium))
                            .foregroundColor(Color.CT.outMsgText)
                            .lineLimit(1)
                        if let size = file.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(CTFont.mono(ChatUIConstants.Typography.systemSize))
                                .foregroundColor(Color.CT.outMsgText.opacity(0.7))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if isUploading {
                progress
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(CTFont.message(ChatUIConstants.Typography.messageTextSize))
                    .foregroundColor(Color.CT.outMsgText)
                    .padding(.top, 2)
            }
        }
        .padding(ChatUIConstants.Bubble.horizontalPadding)
        .background(CTMessageBubbleTheme.background(isSentByMe: true))
        .clipShape(CTShape.control())
        .overlay(CTShape.control().stroke(Color.CT.noise, lineWidth: ChatUIConstants.Bubble.strokeWidth))
    }

    @ViewBuilder
    private var progress: some View {
        let value = MediaUploadProgressTracker.shared.value(for: messageId)
        HStack(spacing: CTLayout.inlinePad) {
            if let value, value > 0 {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .tint(Color.CT.outMsgText)
                Text("\(Int(value * 100))%")
                    .font(CTFont.mono(ChatUIConstants.Typography.systemSize))
                    .foregroundColor(Color.CT.outMsgText.opacity(0.7))
                    .monospacedDigit()
            } else {
                ProgressView().scaleEffect(0.75).tint(Color.CT.outMsgText)
                Text(LocalizedStringKey("uploading"))
                    .font(CTFont.mono(ChatUIConstants.Typography.systemSize))
                    .foregroundColor(Color.CT.outMsgText.opacity(0.7))
            }
        }
        .animation(.easeOut(duration: 0.2), value: value)
    }
}
