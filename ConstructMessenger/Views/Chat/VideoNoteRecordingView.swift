//
//  VideoNoteRecordingView.swift
//  Construct Messenger
//
//  Recording a video note, over the chat: the conversation stays visible behind a dim, the
//  viewfinder is a 3:4 card in the middle — the shape the note will have — and the controls sit
//  where the composer was. Recording starts as soon as the camera is up; there is no record
//  button to find. `decisions/video-notes-are-uncropped-and-expand.md`.
//

#if os(iOS)
import SwiftUI
import AVFoundation

struct VideoNoteRecordingView: View {
    /// The finished note, ready to send as an attachment.
    let onSend: (MediaAttachment) -> Void
    let onClose: () -> Void

    @State private var recorder = VideoNoteRecorder()
    @State private var failure: VideoNoteRecorder.RecorderError?
    /// While paused: the recording so far, its length, and the stretch to keep.
    @State private var review: (url: URL, duration: Double)?
    @State private var trim: ClosedRange<Double> = 0...0

    var body: some View {
        VStack(spacing: CTLayout.edgePad) {
            Spacer(minLength: 0)
            if let review {
                TrimmedLoopPlayer(url: review.url, range: trim)
                    .modifier(NoteCard())
                VideoTrimBar(url: review.url, duration: review.duration, range: $trim)
                    .frame(maxWidth: ChatUIConstants.VideoNote.viewfinderMaxWidth)
            } else {
                viewfinder
            }
            Spacer(minLength: 0)
            controls
        }
        .onChange(of: recorder.phase) { _, phase in
            if phase == .paused { Task { await loadReview() } } else { review = nil }
        }
        .padding(.horizontal, ChatUIConstants.InputBar.rowOuterPad)
        .padding(.bottom, CTLayout.inlinePad)
        .background(Color.black.opacity(ChatUIConstants.VideoNote.recordingDim).ignoresSafeArea())
        .task { await begin() }
        .alert(
            NSLocalizedString("video_note_camera_unavailable", comment: ""),
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { onClose() } })
        ) {
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) { onClose() }
            if failure == .cameraDenied || failure == .microphoneDenied {
                Button(NSLocalizedString("settings", comment: "")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    onClose()
                }
            }
        }
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        CameraPreviewView(session: recorder.session)
            .modifier(NoteCard())
            .overlay(alignment: .top) {
                if recorder.phase == .paused {
                    Text(LocalizedStringKey("video_note_paused"))
                        .font(CTFont.badge)
                        .foregroundColor(.white)
                        .padding(.horizontal, ChatUIConstants.VideoNote.chipHorizontalPadding)
                        .padding(.vertical, ChatUIConstants.VideoNote.chipVerticalPadding)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(CTLayout.edgePad)
                }
            }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 0) {
            control("xmark", label: "cancel", tint: Color.CT.danger) {
                Task { await recorder.cancel(); onClose() }
            }
            Spacer()
            HStack(spacing: ChatUIConstants.VideoNote.chipSpacing) {
                Circle()
                    .fill(recorder.phase == .recording ? Color.CT.danger : Color.CT.textDim)
                    .frame(width: ChatUIConstants.VideoNote.recordDotSize, height: ChatUIConstants.VideoNote.recordDotSize)
                Text(VoiceUIDurationFormatter.string(review != nil ? trim.upperBound - trim.lowerBound : recorder.elapsed))
                    .font(CTFont.ui(14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.CT.text)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if recorder.phase == .paused {
                control("record.circle", label: "video_note_resume", tint: Color.CT.text) { recorder.resume() }
                    .disabled(recorder.elapsed >= VideoNoteRecorder.maxDuration)
            } else {
                control("pause.fill", label: "video_note_pause", tint: Color.CT.text) {
                    Task { await recorder.pause() }
                }
            }
            control("arrow.triangle.2.circlepath.camera", label: "video_note_switch_camera", tint: Color.CT.text) {
                Task { await recorder.switchCamera() }
            }
            control("arrow.up.circle.fill", label: "video_note_send", tint: Color.CT.accent) {
                Task { await send() }
            }
            .disabled(recorder.elapsed <= 0)
        }
        .disabled(recorder.phase == .finishing || recorder.phase == .idle)
        .frame(height: ChatUIConstants.InputBar.height)
        .padding(.horizontal, CTLayout.inlinePad)
        .background(Color.CT.outMsgBg)
        .clipShape(CTShape.pill())
        .overlay(CTShape.pill().strokeBorder(Color.CT.accent.opacity(0.25), lineWidth: 1))
    }

    private func control(_ symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(CTIcon.font(CTIcon.navLg, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    // MARK: Actions

    private func begin() async {
        do {
            try await recorder.start()
        } catch let error as VideoNoteRecorder.RecorderError {
            failure = error
        } catch {
            failure = .configurationFailed
        }
    }

    private func loadReview() async {
        guard let url = try? await recorder.recording(),
              let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration > 0 else { return }
        // A trim made before is kept only if it still fits — resuming drops it.
        trim = review == nil || trim.upperBound > duration ? 0...duration : trim
        review = (url, duration)
    }

    private func send() async {
        // The stretch to send: the trim when reviewing, all of it when sent straight from recording.
        let kept = review.map { _ in trim }
        do {
            let url = try await recorder.finish()
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            let range = kept.flatMap { k -> CMTimeRange? in
                k.lowerBound <= 0 && k.upperBound >= duration ? nil : CMTimeRange(
                    start: CMTime(seconds: k.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: k.upperBound, preferredTimescale: 600))
            }
            let start = range?.start ?? .zero
            onSend(MediaAttachment(
                videoURL: url,
                poster: await Self.frame(of: url, at: start),
                duration: range?.duration.seconds ?? duration,
                mimeType: "video/mp4",
                presentation: .videoNote,
                timeRange: range
            ))
            onClose()
        } catch {
            Log.error("Video note not sent: \(error)", category: "VideoNoteRecording")
            onClose()
        }
    }
}

private struct NoteCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .aspectRatio(ChatUIConstants.VideoNote.aspectRatio, contentMode: .fit)
            .frame(maxWidth: ChatUIConstants.VideoNote.viewfinderMaxWidth)
            .background(Color.CT.bgMsg)
            .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous))
    }
}

extension VideoNoteRecordingView {
    static func frame(of url: URL, at time: CMTime) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        guard let image = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The capture session's live picture, filling its frame — so a 3:4 frame shows the centre 3:4,
/// which is the part the send keeps.
private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
#endif
