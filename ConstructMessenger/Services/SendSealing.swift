//
//  SendSealing.swift
//  Construct Messenger
//
//  How an outgoing envelope answers one question at the transport chokepoint:
//  is it sealed, and if not, under which declared exemption.
//
//  Until 2026-08-30 the question was asked by every sender instead. Fourteen call sites each
//  read `StealthPolicy.shouldUseSealedSender()` and decided for themselves what to do with the
//  answer, and the list of what was excluded lived in a doc comment. Exemptions were added one
//  at a time and neither was noticed until someone read the file: multi-device traffic, and
//  heartbeats — the second still cited a token model removed 2026-07-15.
//
//  Prose does not go red. This type does: `sealing:` has no default, so a new send path cannot
//  be written without answering, and an answer outside the list below does not compile.
//

import Foundation

/// The complete list of reasons an envelope may leave this device unsealed.
///
/// Adding a case is a protocol decision, not a convenience: it must be justified against the
/// invariant that governs A–D in the multi-device plan — **no send names the (sender, recipient)
/// pair to the server** — and it must be added to `SealingExemptionSiteTests`, which pins the set
/// of files allowed to name each one.
enum SealingExemption: String, CaseIterable, Sendable {

    /// Fan-out and SENDER_SYNC to this account's own devices.
    ///
    /// Legitimate under the invariant rather than tolerated by it: the pair here is (me, me),
    /// which the relay knows from the authenticated channel before it reads the envelope, and
    /// `conversation_id` is empty so the person on the other side is not named either. What this
    /// does still expose is the account's device topology, which is §B's subject — sealing to the
    /// target device's identity key. When §B lands this case narrows to own devices only; it does
    /// not disappear, because a sealed envelope to ourselves would hide nothing from a relay that
    /// authenticated us.
    case ownDevices

    /// Stealth switched off globally by the developer override — DEBUG builds only
    /// (`StealthPolicy.isEnabled` is a compile-time `true` in Release).
    ///
    /// Not a property of the send site: any of them may take this branch, and none of them may
    /// take it while stealth is on. The chokepoint enforces exactly that, so a site that lands
    /// here through a wrong branch fails closed instead of shipping an identified envelope.
    case stealthDisabled
}

/// The sealing decision for one outgoing envelope, made by the caller and checked at the send.
enum SendSealing: Sendable {

    /// The `SealedInner` bytes this envelope carries. Empty is not accepted — see `violation`.
    case sealed(Data)

    /// Deliberately unsealed, under a named exemption.
    case identified(SealingExemption)

    /// What `buildEnvelope` needs: the inner bytes, or nil for an identified send.
    var sealedInnerBytes: Data? {
        switch self {
        case .sealed(let inner): return inner
        case .identified: return nil
        }
    }

    /// `nil` when this send may go out; the reason it may not, otherwise.
    ///
    /// Pure and static so the policy is a table a test can enumerate rather than a branch reached
    /// only by a live RPC — the same reason `buildEnvelope` was extracted.
    func violation(stealthEnabled: Bool) -> String? {
        switch self {
        case .sealed(let inner):
            // `buildEnvelope` treats empty sealed bytes as an identified send, on purpose: the
            // alternative is an envelope with no sender AND no seal, which is unroutable. That
            // fallback is correct there and is exactly the hole here — a caller whose seal came
            // back empty would send identified while believing it sealed. Refuse instead.
            return inner.isEmpty
                ? "sealed send carries no SealedInner — an empty seal is an identified send"
                : nil

        case .identified(.ownDevices):
            return nil

        case .identified(.stealthDisabled):
            return stealthEnabled
                ? "identified send claimed the stealth-disabled exemption while stealth is on"
                : nil
        }
    }
}
