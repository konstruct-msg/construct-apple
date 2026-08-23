//
//  MessageInputView+iOS.swift
//  Construct Messenger
//
//  iOS chat composer implementation: action-sheet attachments, camera capture,
//  photo picker, file picker, and voice recording/preview states.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct IOSMessageInputView: View {
    private static let attachmentPreviewSpacing: CGFloat = ChatUIConstants.InputBar.attachFieldGap

    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]
    let replyingTo: Message?
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([MediaAttachment], [URL]) -> Void
    var onSendVoice: ((URL, TimeInterval, [Float]) -> Void)? = nil
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    @State private var showMediaPicker = false
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @StateObject private var attachments = MessageInputAttachmentStore()
    @State private var showMicPermissionAlert = false
    /// Which queued attachment was tapped, and what it opened. Nil means closed — one piece of
    /// state rather than a bool plus an index that can disagree about which item is showing.
    @State private var attachmentTap: AttachmentTapTarget?

    var body: some View {
        VStack(spacing: 0) {
            replyOrEditBars
            // Explicit gap — aux bar and field used to sit flush (screenshot #2).
            if hasAuxBar {
                Color.clear
                    .frame(height: ChatUIConstants.InputBar.auxBarGap)
            }
            attachmentPreviews
            voiceOrInputRow
                .padding(.top, hasAttachmentPreviews ? Self.attachmentPreviewSpacing : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !attachments.selectedAttachments.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: audioRecorder.state)
        .fullScreenCover(item: $attachmentTap) { target in
            attachmentDestination(target)
        }
        .alert("Microphone Access Denied", isPresented: $showMicPermissionAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Please allow microphone access in Settings to send voice messages.")
        }
        .onChange(of: droppedImages) { _, newImages in
            attachments.appendDroppedImages(newImages)
            droppedImages.removeAll()
        }
        .sheet(isPresented: $showMediaPicker) {
            MediaPickerSheet(
                maxSelection: 99,
                onConfirm: { media in
                    // Confirm → composer strip (caption / send from input bar).
                    attachments.appendAttachments(media)
                },
                onPickFiles: { urls in
                    attachments.handlePickedFiles(urls)
                }
            )
        }
    }

    /// Where a tap on the queued attachment at `index` goes.
    ///
    /// An image is opened in the editor directly; the review pager is for video, which has no
    /// editor. An index the strip and the store disagree about (the strip drops attachments with no
    /// poster frame) falls back to the review rather than opening an editor on the wrong photo.
    private func tapTarget(at index: Int) -> AttachmentTapTarget {
        guard attachments.selectedAttachments.indices.contains(index),
              attachments.selectedAttachments[index].kind == .image else {
            return .review(index: index)
        }
        return .edit(index: index)
    }

    @ViewBuilder
    private func attachmentDestination(_ target: AttachmentTapTarget) -> some View {
        switch target {
        case .edit(let index):
            if attachments.selectedAttachments.indices.contains(index),
               let image = attachments.selectedAttachments[index].displayImage {
                MediaEditorView(
                    image: image,
                    onConfirm: { edited in
                        attachments.replaceImage(at: index, with: edited)
                        attachmentTap = nil
                    },
                    onCancel: { attachmentTap = nil }
                )
            }
        case .review(let index):
            AttachmentReviewView(
                attachments: attachments.selectedAttachments,
                initialIndex: index,
                onEdit: { attachments.replaceImage(at: $0, with: $1) },
                onDelete: { attachments.removeAttachment(at: $0) }
            )
        }
    }

    @ViewBuilder
    private var replyOrEditBars: some View {
        if let msg = replyingTo {
            MessageReplyBar(
                content: quoteOverride ?? (msg.displayText.isEmpty ? nil : msg.displayText),
                messageId: msg.id,
                onCancel: onCancelReply
            )
        }
        if let msg = editingMessage {
            MessageEditBar(content: msg.displayText, onCancel: onCancelEdit)
        }
    }

    @ViewBuilder
    private var attachmentPreviews: some View {
        // Quality lives in the media picker (HD / video menu). Composer only shows thumbs.
        if !attachments.selectedAttachments.isEmpty {
            MessagePhotoPreviewBar(
                attachments: attachments.selectedAttachments,
                onRemove: removePhoto,
                onMove: attachments.moveAttachment,
                onOpen: { attachmentTap = tapTarget(at: $0) }
            )
        }
        if !attachments.selectedFileURLs.isEmpty {
            MessageFilePreviewBar(
                fileURLs: attachments.selectedFileURLs,
                onRemove: attachments.removeFile
            )
        }
    }

    /// The composer never unmounts, even while a voice bar is on screen.
    ///
    /// It used to be a `switch` that replaced `inputRow` with the voice bar. That takes the
    /// `TextField` out of the view tree, and a `TextField` that leaves the tree loses focus by
    /// definition — so the keyboard collapsed the moment recording started and came back when it
    /// ended, moving the whole chat twice per voice message. Nothing asked for the keyboard to go;
    /// it was a side effect of how the swap was written.
    ///
    /// Keeping `inputRow` mounted and hidden underneath preserves focus, so the keyboard stays
    /// exactly as the user left it. Hidden means invisible *and* inert: no hit testing (taps belong
    /// to the voice bar above it) and hidden from accessibility, or VoiceOver would read a text
    /// field that is not there.
    ///
    /// Height note: the ZStack takes the taller of the two, so the composer can still shift by the
    /// difference between the input row and a voice bar. That is a few points against ~300 for the
    /// keyboard, and the two are designed to the same composer height.
    @ViewBuilder
    private var voiceOrInputRow: some View {
        let isIdle = audioRecorder.state == .idle

        ZStack {
            inputRow
                .opacity(isIdle ? 1 : 0)
                .allowsHitTesting(isIdle)
                .accessibilityHidden(!isIdle)

            switch audioRecorder.state {
            case .recording(let duration, let waveform):
                VoiceRecordingBar(duration: duration, waveform: waveform) {
                    audioRecorder.stopRecording()
                } onCancel: {
                    audioRecorder.cancel()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(.vertical, CTLayout.inlinePad)

            case .recorded(let url, let duration, let waveform):
                VoicePreviewBar(duration: duration, waveform: waveform) {
                    onSendVoice?(url, duration, waveform)
                    audioRecorder.resetAfterSend()
                } onDiscard: {
                    audioRecorder.cancel()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(.vertical, CTLayout.inlinePad)

            case .idle:
                EmptyView()
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .center, spacing: ChatUIConstants.InputBar.attachFieldGap) {
            attachmentButton
            MessageInputTextBar(
                text: $text,
                canSend: canSend,
                onSend: sendMessage,
                onStartVoice: startVoiceRecording
            )
        }
        // No collective capsule — separate floating glass elements (same pill radius).
        .padding(.horizontal, ChatUIConstants.InputBar.rowOuterPad)
    }

    private var attachmentButton: some View {
        Button { showMediaPicker = true } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: CTLayout.navIconSize))
                .foregroundColor(Color.CT.textDim)
                .frame(width: CTLayout.controlHeight, height: CTLayout.controlHeight)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey("attach")))
    }

    private var canSend: Bool {
        attachments.canSend(text: text)
    }

    private var hasAttachmentPreviews: Bool {
        !attachments.selectedAttachments.isEmpty || !attachments.selectedFileURLs.isEmpty
    }

    private var hasAuxBar: Bool {
        replyingTo != nil || editingMessage != nil
    }

    private func startVoiceRecording() {
        Task {
            do {
                try await audioRecorder.startRecording()
            } catch AudioRecorderService.RecorderError.permissionDenied {
                showMicPermissionAlert = true
            } catch {
                Log.error("Recording failed: \(error)", category: "MessageInput")
            }
        }
    }

    private func sendMessage() {
        // Quality is stamped by the media picker (or camera/drop helpers below).
        // Do not batch-overwrite here — that used to fight the picker's HD / video menu.
        onSend(attachments.selectedAttachments, attachments.selectedFileURLs)
        attachments.clear()
    }

    private func removePhoto(at index: Int) {
        attachments.removeAttachment(at: index)
    }
}

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            picker.dismiss(animated: true)
            if let img = image { onCapture(img) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

#Preview("Input") {
    @Previewable @State var text = ""
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        IOSMessageInputView(
            text: $text,
            droppedImages: $dropped,
            replyingTo: nil,
            quoteOverride: nil,
            editingMessage: nil,
            onSend: { _, _ in },
            onCancelReply: {},
            onCancelEdit: {}
        )
    }
    .background(Color.platformBackground)
}
