//
//  SealedControlChannelTests.swift
//  ConstructMessengerTests
//
//  Composition tests for sealed session-control delivery. The orthogonal suites
//  (SessionConvergenceHarness / SessionInitFlow vs StealthSenderService) never
//  co-exercised "seal control → unseal → route", so f39e03b4 shipped green while
//  END_SESSION and SESSION_RESET_INIT were dropped on the recipient.
//
//  See client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md.
//

import XCTest
@testable import Construct_Messenger

final class SealedControlChannelTests: XCTestCase {

    // MARK: - ContentTypeRouting table (compile-time exhaustive over WireMessageKind)

    func testContentTypeRouting_AllWireMessageKinds_HaveCanonicalContentType() {
        for kind in WireMessageKind.allCases {
            let ct = kind.canonicalContentType
            if kind == .direct {
                XCTAssertEqual(ContentTypeRouting.kind(for: ct), .direct)
            } else {
                XCTAssertEqual(ContentTypeRouting.kind(for: ct), kind,
                               "kind \(kind) canonical ct=\(ct) must round-trip")
            }
        }
    }

    func testContentTypeRouting_ControlBytes_MapToExpectedKinds() {
        let cases: [(UInt8, WireMessageKind)] = [
            (21, .endSession),
            (23, .senderSync),
            (24, .sessionResetInit),
            (1,  .direct),
            (12, .direct), // call — late route, not early-exit kind
            (25, .direct), // ping — late route via SessionControlCodec
            (26, .direct), // ready
            (0,  .direct),
        ]
        for (ct, expected) in cases {
            XCTAssertEqual(ContentTypeRouting.kind(for: ct), expected, "ct=\(ct)")
        }
    }

    // MARK: - Round-trip invariant: sealed rebuild routes like identified

    /// For every early-exit control content type: an identified ChatMessage and a
    /// post-unseal rebuild (outer stamped DIRECT + remapped from resolved.contentType)
    /// must agree on the routing predicates. Adding a WireMessageKind without coverage
    /// fails the allCases loop below.
    func testSealedUnsealRemap_MatchesIdentifiedRouting_ForEveryControlKind() {
        let controlKinds = WireMessageKind.allCases.filter { $0 != .direct }

        for kind in controlKinds {
            let ct = kind.canonicalContentType
            let identified = makeMessage(
                contentType: ct,
                rawPayload: Data(repeating: 0xAB, count: 16)
            )
            // Sealed outer before unseal: generic stamp, real type only after resolve.
            let preUnseal = makeMessage(
                contentType: 1, // outer forced generic
                from: "",
                rawPayload: Data(repeating: 0xAB, count: 16),
                sealedInnerData: Data(repeating: 0x01, count: 8)
            )
            // MessageRouter unseal boundary — the named remap under test.
            let postUnseal = makeMessage(
                contentType: ct,
                from: "peer-user",
                rawPayload: preUnseal.rawPayload
            )

            XCTAssertEqual(identified.isEndSession, postUnseal.isEndSession, "\(kind) isEndSession")
            XCTAssertEqual(identified.isSessionResetInit, postUnseal.isSessionResetInit, "\(kind) isSRI")
            XCTAssertEqual(identified.isSenderSync, postUnseal.isSenderSync, "\(kind) isSenderSync")
            XCTAssertEqual(
                ContentTypeRouting.kind(for: identified.contentType),
                ContentTypeRouting.kind(for: postUnseal.contentType),
                "\(kind) kind agreement"
            )

            // Without the remap, pre-unseal would mis-route — pin the regression class.
            switch kind {
            case .endSession:
                XCTAssertTrue(postUnseal.isEndSession)
                XCTAssertFalse(preUnseal.isEndSession,
                               "pre-unseal outer must NOT look like END_SESSION — f39e03b4 class")
            case .sessionResetInit:
                XCTAssertTrue(postUnseal.isSessionResetInit)
                XCTAssertFalse(preUnseal.isSessionResetInit,
                               "pre-unseal outer must NOT look like SRI — f39e03b4 class")
            case .senderSync:
                XCTAssertTrue(postUnseal.isSenderSync)
                XCTAssertFalse(preUnseal.isSenderSync)
            case .direct:
                break
            }
        }
    }

    /// Negative: a known control contentType must be classified as requiring a routing
    /// decision (so MessageRouter promotes fallthrough to ERROR + metric).
    func testKnownControlContentTypes_NeverSilentFallthrough() {
        for ct in ContentTypeRouting.sealedControlContentTypes where ct != 1 {
            XCTAssertTrue(
                ContentTypeRouting.isKnownControlContentType(ct),
                "ct=\(ct) must be watched for no-routing-decision fallthrough"
            )
        }
        XCTAssertFalse(ContentTypeRouting.isKnownControlContentType(1),
                        "plain e2EeSignal is not a control fallthrough watch")
        XCTAssertFalse(ContentTypeRouting.isKnownControlContentType(0))
    }

    // MARK: - contentType is the only type

    // These two used to pass a `messageType` that disagreed with `contentType`, and asserted the
    // predicates preferred the latter. `ChatMessage.messageType` was removed on 2026-08-02, so
    // that disagreement is no longer expressible — which is a stronger guarantee than the test
    // was making. What remains worth pinning is that the predicates key off the byte, and that
    // an unset byte routes as nothing.

    func testPredicates_RouteOffContentType() {
        let endSession = makeMessage(contentType: 21)
        XCTAssertTrue(endSession.isEndSession)
        XCTAssertFalse(endSession.isSessionResetInit)
        XCTAssertFalse(endSession.isRegularMessage)

        let sri = makeMessage(contentType: 24)
        XCTAssertTrue(sri.isSessionResetInit)
        XCTAssertFalse(sri.isEndSession)
    }

    func testPredicates_UnsetContentType_RoutesAsNoControlKind() {
        let unset = makeMessage(contentType: 0)
        XCTAssertFalse(unset.isEndSession,
                       "contentType=0 must not route as END_SESSION — there is no second field to fall back on")
        XCTAssertFalse(unset.isSessionResetInit)
        XCTAssertFalse(unset.isSenderSync)
    }

    // MARK: - Sealed fallback preserves rawPayload

    func testSealedFallbackShape_PreservesRawPayload_ForShortControlInner() {
        // Models MessageStreamParser sealed fallback: short non-WirePayload inner
        // (END_SESSION sentinel) must keep rawPayload so SessionControl.reason is readable.
        let sentinel = Data(count: 16)
        let msg = makeMessage(
            contentType: 0,
            from: "",
            rawPayload: sentinel,
            sealedInnerData: Data(repeating: 0xEE, count: 32)
        )
        XCTAssertEqual(msg.rawPayload.count, 16)
        XCTAssertFalse(msg.sealedInnerData.isEmpty)

        // After unseal remap to END_SESSION the reason payload is still there.
        let after = makeMessage(
            contentType: 21,
            from: "peer",
            rawPayload: msg.rawPayload
        )
        XCTAssertTrue(after.isEndSession)
        XCTAssertEqual(after.rawPayload, sentinel)
    }

    // MARK: - Helpers

    private func makeMessage(
        contentType: UInt8,
        from: String = "peer-user",
        rawPayload: Data = Data(),
        sealedInnerData: Data = Data()
    ) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            from: from,
            to: "me-user",
            ephemeralPublicKey: Data(),
            messageNumber: 0,
            content: Data(),
            suiteId: 1,
            timestamp: 1_000_000,
            contentType: contentType,
            rawPayload: rawPayload,
            sealedInnerData: sealedInnerData
        )
    }
}
