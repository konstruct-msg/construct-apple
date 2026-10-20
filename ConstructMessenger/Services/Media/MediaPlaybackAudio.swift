//
//  MediaPlaybackAudio.swift
//  Construct Messenger
//
//  The audio session a video plays in. Left alone, AVPlayer plays in the app's default
//  `.soloAmbient` category, which the ring/silent switch mutes — so a video in the gallery or a
//  video file played with no sound on a phone in silent mode, while voice messages and video notes,
//  which set `.playback` themselves, were heard (reported 2026-10-20). A video the person opened is
//  sound they asked for, as in the Photos app.
//

#if os(iOS)
import AVFoundation

enum MediaPlaybackAudio {
    /// Before a video the person opened starts.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    /// When it is gone: other apps' audio may resume.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
