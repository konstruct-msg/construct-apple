//
//  PlayerSurface.swift
//  ConstructMessenger
//
//  The one place a video is drawn. On macOS SwiftUI's `VideoPlayer` subclasses `AVPlayerView`, but
//  `_AVKit_SwiftUI` does not link AVKit, and the linker drops an `import AVKit` nothing uses — so
//  the first `VideoPlayer` aborted with "failed to demangle superclass of VideoPlayerView"
//  (TODO 158, Desktop 0.3.7). Naming `AVPlayerView` here is what keeps AVKit loaded.
//  `PlayerSurfaceTests` fails on a `VideoPlayer(` anywhere else.
//

import AVKit
import SwiftUI

struct PlayerSurface: View {
    let player: AVPlayer?

    var body: some View {
        #if os(macOS)
        MacPlayerView(player: player)
        #else
        VideoPlayer(player: player)
        #endif
    }
}

#if os(macOS)
private struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
