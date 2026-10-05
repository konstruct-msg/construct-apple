//
//  CallModeButton.swift
//  Construct Messenger
//
//  The call button in the chat header, which also offers video — the composer's mic ↔ camera
//  switch (`MicModeButton`), turned the other way: the header is at the top, so the switch opens
//  downwards. A tap is a voice call, as it always was. Held, the button opens two segments —
//  the phone under the finger, the camera below it — and the finger slides down to the camera;
//  releasing on a segment starts that call, releasing away from the switch starts nothing.
//
//  Nothing is remembered between presses: a tap is always a voice call, so the camera never
//  comes on unasked.
//

import SwiftUI

struct CallModeButton: View {
    enum Mode { case voice, video }

    let size: CGFloat
    /// nil: closed. `.some(choice)`: open, with the segment under the finger (nil when it has
    /// left the switch). The header draws the switch from this.
    @Binding var open: Mode??
    /// Without video calls the button is a plain tap: nothing to hold for.
    let offersVideo: Bool
    let onVoice: () -> Void
    let onVideo: () -> Void

    @State private var pressTask: Task<Void, Never>?

    private static let segment = ChatUIConstants.HoldSwitch.segmentLength
    private static let margin = ChatUIConstants.HoldSwitch.cancelMargin

    var body: some View {
        Image(systemName: "phone")
            .font(.system(size: CTLayout.navIconSizeLg, weight: .medium))
            .foregroundColor(Color.CT.accent)
            .opacity(open != nil ? 0 : 1)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { pressChanged(at: $0.location) }
                    .onEnded { pressEnded(at: $0.location) }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: open != nil) { _, isOpen in isOpen }
            .sensoryFeedback(.selection, trigger: open ?? nil) { old, new in old != nil && new != nil }
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey("call_voice")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onVoice() }
            .modifier(VideoCallAction(enabled: offersVideo, action: onVideo))
    }

    /// Which segment is under `point` (the button's own coordinates; the switch grows downwards
    /// from the button's top edge, the phone segment over the button), or nil when the finger
    /// has left it.
    static func mode(at point: CGPoint, buttonSize size: CGFloat) -> Mode? {
        let top: CGFloat = 0, bottom = 2 * segment
        guard point.y > top - margin, point.y < bottom + margin,
              point.x > -margin, point.x < size + margin else { return nil }
        return point.y > top + segment ? .video : .voice
    }

    private func pressChanged(at point: CGPoint) {
        guard offersVideo else { return }
        if open != nil {
            open = .some(Self.mode(at: point, buttonSize: size))
        } else if pressTask == nil {
            pressTask = Task { @MainActor in
                try? await Task.sleep(for: ChatUIConstants.HoldSwitch.pressDelay)
                guard !Task.isCancelled else { return }
                open = .some(.voice)
            }
        }
    }

    private func pressEnded(at point: CGPoint) {
        pressTask?.cancel()
        pressTask = nil
        guard open != nil else {
            // A plain tap — but only one that ended on the button, as a Button's would.
            if CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: -Self.margin, dy: -Self.margin).contains(point) {
                onVoice()
            }
            return
        }
        open = nil
        switch Self.mode(at: point, buttonSize: size) {
        case .voice: onVoice()
        case .video: onVideo()
        case nil: break
        }
    }
}

/// VoiceOver cannot hold and slide; it gets the video call as a named action instead.
private struct VideoCallAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: Text(LocalizedStringKey("call_video")), action)
        } else {
            content
        }
    }
}

/// The open switch: phone over camera, `width` wide, its top on the call button's.
struct CallModeSwitch: View {
    let choice: CallModeButton.Mode?
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            segment(.voice, symbol: "phone.fill", label: "call_voice")
            segment(.video, symbol: "video.fill", label: "call_video")
        }
        .frame(width: width)
        .background(.regularMaterial, in: Capsule())
    }

    private func segment(_ mode: CallModeButton.Mode, symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: CTLayout.navIconSize))
            .foregroundStyle(choice == mode ? Color.CT.bg : Color.CT.textDim)
            .frame(width: width, height: ChatUIConstants.HoldSwitch.segmentLength)
            .background {
                if choice == mode { Capsule().fill(Color.CT.accent).padding(2) }
            }
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }
}
