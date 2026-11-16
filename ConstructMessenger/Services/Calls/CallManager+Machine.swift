//
//  CallManager+Machine.swift
//  Construct Messenger
//
//  Part of CallManager: the call's state is the core's call machine (construct-rules
//  `call_machine`, construct-core 0.75.0, todo 295 step 5), shared with Android and
//  construct-client. Its phase, devices, held or awaited offer, media, stream and ICE-restart
//  budgets, ended ids and deadlines live there; `ActiveCall` keeps only this platform's resources
//  (WebRTC, the stream, CallKit, ICE buffers, TURN).
//
//  Every change goes through `withMachine`, which then brings `state` and `machineCall` in line
//  and re-arms the one timer at the machine's next deadline.
//

import Foundation

extension CallManager {
    /// Run `change` on the machine, then bring this app in line with it.
    @discardableResult
    func withMachine<T>(_ change: (CallMachine) -> T) -> T {
        let result = change(machine)
        machineChanged()
        return result
    }

    /// The machine changed: refresh the snapshot views read, the phase they show, and the timer.
    func machineChanged() {
        machineCall = machine.active()
        if let call = machineCall, let active, active.session.id == call.callId {
            let next = CallRuleWire.state(call.phase, session: active.session)
            if next != state { state = next }
        }
        rearmDeadline()
    }

    /// One timer, at the machine's next deadline (the unanswered call, the offer wait, the
    /// ICE-restart grace). It replaces three timers that each kept their own copy of the call.
    private func rearmDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let at = machine.nextDeadline() else { return }
        let delayMs = max(0, at - Self.nowMs())
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self else { return }
            self.deadlinePassed()
        }
    }

    private func deadlinePassed() {
        guard let due = withMachine({ $0.tick(nowMs: Self.nowMs()) }) else { return }
        switch due {
        case .unanswered(let hangup):
            // Nothing else ends it: the callee opens its stream only on answer, so the server's
            // reaper never reaches it, and a caller that crashed sends no hangup.
            Log.info("Incoming call unanswered for \(Int(callTimings().unansweredMs / 1000))s — ending (call_id=\(hangup.ended.callId.prefix(8))…)", category: "Calls")
            sendHangup(hangup)
            endActiveCall(reason: .hangup(CallRuleWire.proto(hangup.reason)), ended: hangup.ended, reportToCallKit: true)
        case .noOffer(let failure):
            Log.error("Answered call never received its SDP offer in \(Int(callTimings().offerWaitMs / 1000))s — ending (call_id=\(failure.ended.callId.prefix(8))…)", category: "Calls")
            PerformanceMetrics.shared.record(.answerBeforeOffer, label: "timeout")
            endActiveCall(failure: failure, what: "No offer received")
        case .restartIce:
            guard let active else { return }
            Task { @MainActor [weak self] in await self?.performIceRestart(for: active) }
        }
    }
}
