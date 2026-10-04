//
//  VideoNoteReviewView.swift
//  Construct Messenger
//
//  What a paused video note shows in place of the viewfinder: the recording so far, playing
//  with sound on a loop over the kept stretch, and a strip of frames with two handles to trim
//  the start and the end. The send keeps that stretch — exactly, since the send re-encodes
//  (`MediaManager.transcodeVideo(timeRange:)`). Resuming the recording drops the trim.
//

#if os(iOS)
import SwiftUI
import AVFoundation

/// Plays `range` of `url` on a loop, with sound.
struct TrimmedLoopPlayer: View {
    let url: URL
    let range: ClosedRange<Double>

    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        PlayerLayerView(player: player)
            .task(id: TaskKey(url: url, range: range)) {
                let item = AVPlayerItem(asset: AVURLAsset(url: url))
                looper = AVPlayerLooper(
                    player: player,
                    templateItem: item,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                        end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
                    )
                )
                player.play()
            }
            .onDisappear {
                player.pause()
                looper = nil
                player.removeAllItems()
            }
    }

    private struct TaskKey: Equatable {
        let url: URL
        let range: ClosedRange<Double>
    }
}

/// Frames of the recording with a handle at each end of the kept stretch.
struct VideoTrimBar: View {
    let url: URL
    let duration: Double
    /// Committed when a handle is let go, not on every point of the drag — the player restarts
    /// on each commit.
    @Binding var range: ClosedRange<Double>

    @State private var frames: [UIImage] = []
    @State private var draft: ClosedRange<Double>?

    private static let shortest = ChatUIConstants.VideoNote.trimMinimumDuration
    private static let handle = ChatUIConstants.VideoNote.trimHandleWidth

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shown = draft ?? range
            let x = { (t: Double) in CGFloat(t / max(duration, 0.001)) * width }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(uiImage: frames[i]).resizable().scaledToFill()
                            .frame(width: width / CGFloat(max(frames.count, 1)), height: geo.size.height)
                            .clipped()
                    }
                }
                // What is cut away, dimmed.
                Color.black.opacity(ChatUIConstants.VideoNote.trimCutDim).frame(width: x(shown.lowerBound))
                Color.black.opacity(ChatUIConstants.VideoNote.trimCutDim).frame(width: width - x(shown.upperBound)).offset(x: x(shown.upperBound))
                // The kept stretch.
                RoundedRectangle(cornerRadius: CTRadius.badge)
                    .strokeBorder(Color.CT.accent, lineWidth: 2)
                    .frame(width: max(Self.handle * 2, x(shown.upperBound) - x(shown.lowerBound)))
                    .offset(x: x(shown.lowerBound))
                handleView(at: x(shown.lowerBound), label: "video_note_trim_start", edge: .start, width: width)
                handleView(at: x(shown.upperBound) - Self.handle, label: "video_note_trim_end", edge: .end, width: width)
            }
        }
        .frame(height: ChatUIConstants.VideoNote.trimBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: CTRadius.badge))
        .task(id: url) { frames = await Self.frames(of: url, count: ChatUIConstants.VideoNote.trimFrameCount) }
    }

    private enum Edge { case start, end }

    private func handleView(at x: CGFloat, label: String, edge: Edge, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CTRadius.badge)
            .fill(Color.CT.accent)
            .frame(width: Self.handle)
            .overlay(Capsule().fill(Color.CT.bg).frame(width: 2).padding(.vertical, ChatUIConstants.VideoNote.trimGripInset))
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = Double(value.location.x / width) * duration
                        draft = moved(edge, to: t, from: draft ?? range)
                    }
                    .onEnded { _ in
                        if let draft { range = draft }
                        draft = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey(label)))
            .accessibilityValue(Text(formatMediaDuration(edge == .start ? range.lowerBound : range.upperBound)))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                let t = (edge == .start ? range.lowerBound : range.upperBound) + step
                range = moved(edge, to: t, from: range)
            }
    }

    /// `edge` moved to `t`, kept inside the recording and at least `shortest` from the other end.
    private func moved(_ edge: Edge, to t: Double, from r: ClosedRange<Double>) -> ClosedRange<Double> {
        Self.moved(start: edge == .start, to: t, from: r, duration: duration)
    }

    static func moved(start: Bool, to t: Double, from r: ClosedRange<Double>, duration: Double) -> ClosedRange<Double> {
        let shortest = min(Self.shortest, duration)
        if start {
            let lower = min(max(0, t), r.upperBound - shortest)
            return max(0, lower)...r.upperBound
        } else {
            let upper = max(min(duration, t), r.lowerBound + shortest)
            return r.lowerBound...min(duration, upper)
        }
    }

    private static func frames(of url: URL, count: Int) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = ChatUIConstants.VideoNote.trimFrameSize
        var images: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: t).image { images.append(UIImage(cgImage: image)) }
        }
        return images
    }
}
#endif
