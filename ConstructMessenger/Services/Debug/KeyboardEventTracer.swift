//
//  KeyboardEventTracer.swift
//  Construct Messenger
//
//  Says when the keyboard went away and what the app was doing at that moment.
//
//  Exists because a plausible cause was fixed and the symptom stayed. The composer used to be
//  swapped out for the voice bar, taking the `TextField` out of the view tree — which loses focus
//  by definition, so it looked like the answer. Keeping the field mounted (`dfff1e86`) did not
//  help: build `dfff1e86` shipped to both test devices on 2026-08-03 and the keyboard still
//  collapsed when recording started.
//
//  Rather than name a second cause and hope, this records the ordering. The two remaining
//  candidates leave different traces:
//
//    * `AVAudioSession.setCategory(.playAndRecord) + setActive(true)` runs synchronously inside
//      `AudioRecorderService.startRecording()`, *before* the recorder state flips. If it is the
//      cause, the hide arrives with `phase=audioSessionActivating`.
//    * A view/layout effect would hide the keyboard after the state change, i.e.
//      `phase=recording`.
//
//  If neither matches, the hide is coming from somewhere we have not considered — which is itself
//  the useful answer, and better than a third guess.
//
//  DEBUG only: it exists to settle a question, not to ship.
//

import Foundation
#if os(iOS)
import UIKit
#endif

enum KeyboardTracePhase: String {
    case idle
    /// Between `configureAudioSession()` starting and the recorder state flipping to `.recording`.
    case audioSessionActivating
    case recording
    case stoppingRecording
}

final class KeyboardEventTracer {

    static let shared = KeyboardEventTracer()

    /// What the app believes it is doing. Written by `AudioRecorderService` around the steps that
    /// could plausibly be responsible.
    private(set) var phase: KeyboardTracePhase = .idle
    private var phaseEnteredAt = Date()

    private init() {}

    func enter(_ phase: KeyboardTracePhase) {
        #if DEBUG
        self.phase = phase
        self.phaseEnteredAt = Date()
        Log.debug("KEYBOARD_TRACE: phase → \(phase.rawValue)", category: "KeyboardTrace")
        #endif
    }

    func start() {
        #if DEBUG && os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let sincePhase = Int(Date().timeIntervalSince(self.phaseEnteredAt) * 1000)
            Log.info(
                "KEYBOARD_TRACE: will HIDE — phase=\(self.phase.rawValue) (+\(sincePhase)ms into that phase)",
                category: "KeyboardTrace"
            )
        }
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.info("KEYBOARD_TRACE: will SHOW — phase=\(self.phase.rawValue)", category: "KeyboardTrace")
        }
        Log.info("KEYBOARD_TRACE: armed", category: "KeyboardTrace")
        #endif
    }
}
