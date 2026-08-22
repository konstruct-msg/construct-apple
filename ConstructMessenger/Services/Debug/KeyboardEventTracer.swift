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
//  2026-08-11 — that rule turned out to be too confident, and it sent the last fix the wrong way.
//  The device answered `phase=recording` (+25ms, +16ms), which the rule reads as "view layer", so
//  `.mixWithOthers` was added to the audio session and changed nothing. The flaw: the rule assumed
//  the audio session's effect on the keyboard would be *synchronous* with `setActive(true)`. It
//  need not be — a system-side teardown arriving 20ms later lands in `phase=recording` too. So the
//  phase distinguishes far less than it claimed, and both candidates were still alive.
//
//  What actually separates them is who holds first responder when the keyboard goes:
//
//    * still the `UITextField` → nobody resigned anything; the keyboard was suppressed by the
//      system, and the audio session is the only thing we ask the system for at that moment.
//    * nil / something else → the view layer dropped focus, despite `inputRow` staying mounted.
//
//  The log already hints at the first: the keyboard comes back **on its own** when recording stops
//  (`will SHOW — phase=recording`, 11:48:57 and 11:49:05) and nothing in the app re-focuses. But
//  that is an inference about SwiftUI's focus bookkeeping, not an observation — hence this.
//
//  DEBUG only: it exists to settle a question, not to ship.
//

import Foundation
#if os(iOS)
import UIKit
#endif

enum KeyboardTracePhase: String {
    case idle
    /// `setCategory(.playAndRecord …)` is in flight. Split from the activation below on 2026-08-22,
    /// because by then the question had narrowed to one step and the phase could not name it: the
    /// device answered the responder test three times (09:38:32, 09:41:29, 11:38:41 — all
    /// `firstResponder=VerticalTextView`), so nothing in the app resigns focus and the keyboard is
    /// being taken by the system. The audio session is the only thing we ask the system for there,
    /// and it is two calls. Which of the two the hide follows decides whether pre-arming the
    /// category at composer focus can help at all, or whether only the activation can be moved.
    case audioSessionCategory
    /// `setActive(true)` is in flight, up to the recorder state flipping to `.recording`.
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

    /// SwiftUI's view of focus, reported by the composer's `@FocusState`. Cheap, but it can lag the
    /// responder chain, which is why it is logged alongside `firstResponder` rather than instead.
    func noteFocus(_ isFocused: Bool) {
        #if DEBUG
        Log.info(
            "KEYBOARD_TRACE: composer focus → \(isFocused) (phase=\(phase.rawValue))",
            category: "KeyboardTrace"
        )
        #endif
    }

    func start() {
        #if DEBUG && os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let sincePhase = Int(Date().timeIntervalSince(self.phaseEnteredAt) * 1000)
            let responder = MainActor.assumeIsolated { Self.firstResponderDescription() }
            Log.info(
                "KEYBOARD_TRACE: will HIDE — phase=\(self.phase.rawValue) (+\(sincePhase)ms into that phase) firstResponder=\(responder)",
                category: "KeyboardTrace"
            )
        }
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let responder = MainActor.assumeIsolated { Self.firstResponderDescription() }
            Log.info(
                "KEYBOARD_TRACE: will SHOW — phase=\(self.phase.rawValue) firstResponder=\(responder)",
                category: "KeyboardTrace"
            )
        }
        Log.info("KEYBOARD_TRACE: armed", category: "KeyboardTrace")
        #endif
    }

    #if DEBUG && os(iOS)
    /// The class name of whatever currently holds first responder, or `none`.
    ///
    /// `assumeIsolated` is honest here rather than convenient: both call sites are notification
    /// observers registered with `queue: .main`, so this only ever runs on the main actor.
    @MainActor
    private static func firstResponderDescription() -> String {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.keyWindow else { return "no-key-window" }
        guard let responder = firstResponder(in: window) else { return "none" }
        return String(describing: type(of: responder))
    }

    @MainActor
    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }
    #endif
}
