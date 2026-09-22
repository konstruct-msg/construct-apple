//
//  DeviceDeliveryPlan.swift
//  Construct Messenger
//
//  Which devices a message becomes a copy for, and what each copy travels as.
//

import Foundation

/// A device of the person we are writing to, as the plan is built from it.
///
/// Two sources, one shape. The local set (`PeerDevice`: device id and identity key, on disk)
/// names every device we have been told about and needs no network; a bundle fetch names the
/// account's devices with the material to open a session. A send to a peer we already hold
/// sessions with is built from the first, so it does not depend on the key server — which is
/// rate-limited, destructive and sometimes unreachable — and a bundle is fetched only for a
/// device that turns out to need one.
///
/// The local set is what we were **told**, though, and only an inbound message tells us. See
/// `merge(local:directory:)` for the device that never writes.
struct PlannedRecipientDevice {
    let deviceId: String
    /// The device's X25519 identity key — what the copy is sealed to and the tag is keyed on.
    let identityPublic: Data
    /// Present when a fetch supplied it; `nil` for a device from the local set.
    let bundle: PublicKeyBundleData?

    init(deviceId: String, identityPublic: Data, bundle: PublicKeyBundleData? = nil) {
        self.deviceId = deviceId
        self.identityPublic = identityPublic
        self.bundle = bundle
    }

    init(_ device: DeviceBundleData) {
        self.init(deviceId: device.deviceId, identityPublic: device.bundle.identityPublic, bundle: device.bundle)
    }

    /// The devices a send plans for, from the rows we hold and what the key server last said.
    ///
    /// **Neither source is authoritative alone, and neither may overwrite the other.**
    ///
    /// A device in `directory` and not in `local` is the whole point: a peer who linked a device
    /// after we pinned their set has one nothing has told us about, and nothing will — a device
    /// that has not written to us is silent by construction. Until 2026-09-22 such a device was
    /// reached only once it wrote first.
    ///
    /// A device in `local` and not in `directory` is **kept**. The directory answer is narrowed
    /// twice before it arrives here — by the request, and by this client dropping any device whose
    /// hybrid-PQ bundle failed verification — so its absence means "no usable bundle in this
    /// answer", not "gone". Removal is `SessionAddressing.reconcileDevices`'s job, from
    /// `active_devices`, which is the server stating its own set rather than us inferring one.
    /// Reading absence here as removal would drop a device we hold a live session with because one
    /// bundle was unreadable.
    ///
    /// Where both name a device the directory entry wins: it carries the bundle, which the caller
    /// needs to open a session without a second fetch. The two keys agree by construction — a
    /// device id is `SHA256(identity_public)[0..16]` and both sources check that before storing.
    static func merge(local: [PlannedRecipientDevice], directory: [DeviceBundleData]) -> [PlannedRecipientDevice] {
        guard !directory.isEmpty else { return local }
        var byId: [String: DeviceBundleData] = [:]
        for device in directory { byId[device.deviceId] = device }

        var merged = local.map { row in
            byId[row.deviceId].map(PlannedRecipientDevice.init) ?? row
        }
        let known = Set(local.map(\.deviceId))
        merged.append(contentsOf: directory.filter { !known.contains($0.deviceId) }.map(PlannedRecipientDevice.init))
        return merged
    }
}

/// One device that must receive its own ciphertext of an outgoing message.
///
/// Not `Equatable`: `PublicKeyBundleData` is not, and synthesising it by hand over a bundle whose
/// fields grow with each suite would be a comparison that quietly stops covering the new ones.
/// Tests assert on `deviceId` and `audience`, which is what the plan actually decides.
struct DeviceDeliveryTarget {

    /// Whose device this is. The two differ in content type and in which account the envelope is
    /// addressed to, and in nothing else — both are per-device copies of one message.
    enum Audience: Equatable {
        /// A device of the person we are writing to.
        case recipient
        /// Another of our own devices, so the message appears in its transcript too.
        case ownReplica
    }

    let deviceId: String
    /// The device's X25519 identity key — the other half of the pair secret the tag is keyed on,
    /// and the key a copy for this device is sealed to.
    let identityPublic: Data
    /// What the session layer needs to *open* a session with this device, when the caller had it.
    ///
    /// The whole bundle rather than just the identity key: the caller needs both, and handing it
    /// one and making it find the other by index in the array the plan was built from is a second
    /// carrier of the same pairing — one that stays correct only while nothing filters. `nil` for
    /// a recipient device from the local set; the sender fetches one if no session exists.
    let bundle: PublicKeyBundleData?
    let audience: Audience
}

/// Who gets a copy of an outgoing message, and under which wire id.
///
/// ## Why this is a named decision and not a loop in the sender
///
/// It answers three questions that were previously answered in two places each, differently:
/// which devices are targets, whether our own sending device is one, and what the copy's wire id
/// says out loud. `fanOutToRecipientDevices` and `sendSenderSync` each had their own answer, and
/// the answers had already drifted — see the tag below.
///
/// ## The wire id
///
/// Delivery is per **account**: `messaging-service/src/core.rs` writes the same envelope to every
/// one of the recipient's per-device streams. So a message split into N per-device ciphertexts
/// arrives at each of those N devices N times, and every device must recognise its own copy
/// cheaply — the alternative is not a few failed decrypts but, for `messageNumber == 0`, the
/// recovery path with a key-bundle fetch over the network, once per foreign copy.
///
/// The suffix carries a tag for that: a per-message MAC under a secret only the two devices share
/// (`construct-core :: crypto::device_copy_tag`). The relay serves both public keys and still
/// cannot compute it.
///
/// **Until 2026-08-25 only the own-replica path had one.** The recipient-device path wrote
/// `-fd-<deviceId.prefix(8)>` — the target's device id in plain hex, which the relay reads on every
/// copy it routes — and nothing anywhere read that suffix back. So it had the exact leak that was
/// closed for the other path on 2026-08-17, plus a producer with no consumer, plus the session
/// churn the tag exists to prevent. One fix landed on one of two paths carrying the same fact,
/// which is the defect class this repository keeps paying for.
enum DeviceDeliveryPlan {

    /// Marker separating the base message id from the device tag.
    ///
    /// Still two markers, not one, and deliberately so for exactly one change: the reader that
    /// would act on a unified marker for recipient copies does not exist yet (it lives on the
    /// SENDER_SYNC branch of `MessageRouter`). Unifying before the reader would leave a producer
    /// nothing consumes, which is the thing this file's own doc comment complains about.
    enum Marker {
        static let ownReplica = "-ss-"
        static let recipient = "-fd-"

        static func of(_ audience: DeviceDeliveryTarget.Audience) -> String {
            switch audience {
            case .ownReplica: return ownReplica
            case .recipient: return recipient
            }
        }
    }

    /// Every device that must receive a copy.
    ///
    /// **There is no primary send.** Until 2026-09-22 the ordinary send reached the device the
    /// recipient's pinned key named and this plan subtracted it (`primarySendCovered`), so one of
    /// the recipient's devices was reached by a path with delivery status, a retry store and
    /// privacy-pass recovery, and the rest by a path with none of those. Every recipient device
    /// is a target now, and one sender handles them all
    /// (`OutboundMessagePipeline.sendToRecipientDevices`). The core's `plan_send` still takes the
    /// parameter and is handed the empty string; removing it there is a core change.
    ///
    /// - Parameters:
    ///   - recipientDevices: the devices of the person we are writing to. Empty when writing to
    ///     ourselves — see `recipientIsSelf`.
    ///   - ownDevices: bundles for our own account, **including this device**; it is filtered here
    ///     rather than by each caller, because forgetting to is invisible: delivery hands us our
    ///     own copy back anyway, so the symptom is a device trying to open a message it wrote.
    ///   - ourDeviceId: this device. When absent no own-replica copies are planned — we cannot
    ///     tell ourselves apart from our replicas, and sending to all of them would include a copy
    ///     addressed to this device.
    ///   - recipientIsSelf: a note to self. Then the recipient's devices *are* our devices, and
    ///     planning both audiences would send every replica two copies of one message.
    static func targets(
        recipientDevices: [PlannedRecipientDevice],
        ownDevices: [DeviceBundleData],
        ourDeviceId: String?,
        recipientIsSelf: Bool
    ) -> [DeviceDeliveryTarget] {
        // **The decision lives in the core** (`orchestration::send_plan`). This is the translation
        // around it: the core is handed device id sets and the account-space facts it cannot
        // derive, and hands back who to send to and as what. See AGENTS.md, "The core decides,
        // this app executes".
        let plan = planSend(
            recipientDeviceIds: recipientDevices.map(\.deviceId),
            ownDeviceIds: ownDevices.map(\.deviceId),
            // Empty means "unknown" to the core, which is why the optional collapses here rather
            // than being answered with a guess: without our own device id no replica copy is
            // planned at all, and that refusal is the core's, not ours.
            ourDeviceId: ourDeviceId ?? "",
            recipientIsSelf: recipientIsSelf,
            primarySendCovered: ""
        )

        // Re-associated **by device id, never by position**. The material the caller needs is in
        // two arrays that the plan filters, so an index into either stops meaning what it meant
        // the moment anything is dropped — and dropping is this function's entire content. A
        // device id is `SHA256(identity_public)[0..16]`, so it is unique by construction and this
        // lookup is exact rather than merely convenient.
        var byId: [String: (identityPublic: Data, bundle: PublicKeyBundleData?)] = [:]
        for device in recipientDevices {
            byId[device.deviceId] = (device.identityPublic, device.bundle)
        }
        for device in ownDevices {
            byId[device.deviceId] = (device.bundle.identityPublic, device.bundle)
        }

        return plan.compactMap { target in
            guard let material = byId[target.deviceId] else {
                // Unreachable while the caller passes the arrays it derived the ids from. Logged
                // rather than force-unwrapped because the alternative to a missing key is a crash
                // on the send path, and a skipped copy is recoverable.
                Log.error(
                    "DeviceDeliveryPlan: no key for planned device \(target.deviceId.prefix(8))… — skipping its copy",
                    category: "MultiDevice"
                )
                return nil
            }
            return DeviceDeliveryTarget(
                deviceId: target.deviceId,
                identityPublic: material.identityPublic,
                bundle: material.bundle,
                audience: target.audience == .ownReplica ? .ownReplica : .recipient
            )
        }
    }

    /// The wire id one chunk of a copy travels under.
    ///
    /// `tag` is opaque to everyone but the two devices. `chunkIndex` is appended only for a
    /// multi-chunk message, because the receiver reads the tag from whichever chunk arrives first
    /// and the tag is computed over the base id — so every chunk of one copy shares it.
    static func wireId(
        baseMessageId: String,
        tag: String,
        audience: DeviceDeliveryTarget.Audience,
        chunkIndex: Int,
        chunkCount: Int
    ) -> String {
        let head = "\(baseMessageId)\(Marker.of(audience))\(tag)"
        return chunkCount <= 1 ? head : "\(head)-c\(chunkIndex)"
    }
}
