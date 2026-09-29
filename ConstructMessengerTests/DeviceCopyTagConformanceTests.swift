//
//  DeviceCopyTagConformanceTests.swift
//  ConstructMessengerTests
//
//  The per-device copy tag is computed by the core, with our identity key, which the core no
//  longer gives out. This checks the Swift seam over it.
//

import XCTest
@testable import Construct_Messenger

/// Where the cross-client vectors went.
///
/// `knst_device_copy_tag.json` pins tags for fixed private keys, and until 2026-09-29 this file
/// fed those keys to the core's free `deviceCopyTag`. The key-taking functions left the FFI that
/// day — a platform cannot hand the core a private key any more, only ask it to tag with its own —
/// so the vectors are asserted where the keys can still be set: the core's `pinned_vectors`, which
/// were produced by the CryptoKit implementation this app shipped first. Directionality, the
/// echo rule and per-message tags are asserted on real devices in `DeviceCopyWireIdTests`.
final class DeviceCopyTagConformanceTests: XCTestCase {

    // MARK: - The Swift seam

    /// `SenderSyncDeviceTag.Tagger` holds no cryptography; it must forward to the core unchanged.
    ///
    /// Mutation: have the tagger swap `baseMessageId` and `targetDeviceId` — this reddens while
    /// the core's own tests stay green, which is the whole reason the seam is tested separately.
    func testTheSwiftSeamForwardsWithoutAlteringAnything() throws {
        let sender = try makeTestDevice()
        let target = try makeTestDevice()
        let targetKey = try target.core.getRegistrationBundleFields().identityPublic
        let senderKey = try sender.core.getRegistrationBundleFields().identityPublic

        let viaCore = try sender.core.deviceCopyTag(
            baseMessageId: "m", targetDeviceId: target.deviceId, peerIdentityPublic: targetKey
        )
        let viaSeam = SenderSyncDeviceTag.Tagger(core: sender.core).tag("m", target.deviceId, targetKey)
        XCTAssertEqual(viaSeam, viaCore)
        XCTAssertTrue(SenderSyncDeviceTag.Tagger(core: target.core).matches(viaCore, "m", senderKey))
    }

    /// Unusable key material is "not foreign", never a throw that reaches the routing path.
    ///
    /// Callers ask "is this copy for another of my devices?", and the answer to an undecidable
    /// question there must be no: wrongly opening a copy costs failed decrypts, wrongly discarding
    /// one loses a message from the transcript, silently.
    func testUnusableKeyMaterialDoesNotMatchAndDoesNotThrow() throws {
        let tagger = SenderSyncDeviceTag.Tagger(core: try makeTestDevice().core)
        XCTAssertNil(tagger.tag("m", "d", Data(repeating: 0, count: 31)))
        XCTAssertFalse(tagger.matches("0123456789abcdef", "m", Data(repeating: 0, count: 31)))
    }
}
