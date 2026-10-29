//
//  StudioLink.swift
//  Construct Messenger
//
//  `StudioControlMachine` run over a channel: bytes from `studio-control` in, the machine's
//  messages out through `send`, and the rest of its effects handed to the owner's hooks. No
//  WebRTC here — the call wires `send` to the channel — so two links joined back to back are a
//  whole studio in a test.
//

import Foundation
import SwiftProtobuf

@MainActor
final class StudioLink {
    private(set) var state: StudioControlMachine.State
    private let send: (Data) -> Bool

    /// Guest: an invite arrived; answer it with `.accept` or `.decline`.
    var onInvite: (StudioInvite) -> Void = { _ in }
    /// Host: start the program in this format. Guest: play it.
    var onUseFormat: (StudioProgramFormat) -> Void = { _ in }
    /// Guest: the host's screen was shown or hidden.
    var onScreenShown: (Bool) -> Void = { _ in }
    /// The studio is over on this side; whatever ran for it stops. The call goes on.
    var onEnd: (StudioControlMachine.EndReason) -> Void = { _ in }

    init(role: StudioControlMachine.Role, send: @escaping (Data) -> Bool) {
        state = StudioControlMachine.State(role: role)
        self.send = send
    }

    func handle(_ event: StudioControlMachine.Event) {
        let (next, effects) = StudioControlMachine.reduce(state, event)
        state = next
        for effect in effects { perform(effect) }
    }

    /// A message from the control channel.
    func receive(_ data: Data) {
        guard let control = try? StudioControl(serializedBytes: data) else {
            Log.error("Studio control: malformed message (\(data.count) B)", category: "Calls")
            return
        }
        handle(.received(control))
    }

    private func perform(_ effect: StudioControlMachine.Effect) {
        switch effect {
        case .send(let control):
            // The channel is reliable and ordered; a refusal means it is not open (or WebRTC's
            // queue is full), and the other side never learns this step.
            guard let data = try? control.serializedData(), send(data) else {
                Log.error("Studio control: not sent — \(String(describing: control.body))", category: "Calls")
                return
            }
        case .presentInvite(let invite):
            onInvite(invite)
        case .useFormat(let format):
            onUseFormat(format)
        case .goDirect:
            // Neither side offers direct before the choice screen (step 6), so the machine cannot
            // decide it yet; said here in case that changes first.
            Log.error("Studio: a direct path was decided, and this build only runs relay", category: "Calls")
        case .screenShown(let shown):
            Log.info("Studio: host screen \(shown ? "shown" : "hidden")", category: "Calls")
            onScreenShown(shown)
        case .qualityRequested(let codec):
            Log.info("Studio: guest asks for \(codec)", category: "Calls")
        case .roundTrip:
            break
        case .end(let reason):
            onEnd(reason)
        }
    }
}
