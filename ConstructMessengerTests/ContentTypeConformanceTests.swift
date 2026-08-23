//
//  ContentTypeConformanceTests.swift
//  ConstructMessengerTests
//
//  This client must classify a content type the way every client classifies it.
//
//  Until 2026-08-23 there was no "every client". iOS held the classification as literals spread
//  through MessageRouter's frame dispatch and three helpers; the TUI held its own list built from
//  a different question, and the two had already drifted on 13 (HEARTBEAT) and 23 (SENDER_SYNC).
//  Neither could observe the other, and divergence here does not raise anything: the payload
//  becomes a bubble on one client and nothing on the other, and it is found weeks later as "the
//  phone shows something the terminal does not".
//
//  `construct-protos/conformance/knst_content_types.json` is the authority. It is vendored into
//  Generated/ by ./generate_grpc_swift.sh, so regenerating after a proto change is what brings a
//  new content type here — and a type this client has not learned reddens the first test below
//  rather than arriving as a payload nobody classifies.
//
//  See decisions/wire-format-one-authority.md.
//

import XCTest
@testable import Construct_Messenger

final class ContentTypeConformanceTests: XCTestCase {

    private struct Row: Decodable {
        let value: Int
        let name: String
        let knstByte5: Bool
        let disposition: String
        let routingKind: String
        let sessionControlOp: String?
        let framedSideChannel: String?
        let sealedInnerContentType: Bool

        enum CodingKeys: String, CodingKey {
            case value, name, disposition
            case knstByte5 = "knst_byte5"
            case routingKind = "routing_kind"
            case sessionControlOp = "session_control_op"
            case framedSideChannel = "framed_side_channel"
            case sealedInnerContentType = "sealed_inner_content_type"
        }
    }

    private struct Vectors: Decodable {
        let types: [Row]
    }

    /// The vendored copy, located from this file rather than a bundle resource — adding a
    /// resource to the test target is a project-file change, and the fixture is in the repo.
    private func loadVectors() throws -> [Row] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConstructMessengerTests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance")
            .appendingPathComponent("knst_content_types.json")
        let data = try Data(contentsOf: url)
        let rows = try JSONDecoder().decode(Vectors.self, from: data).types
        // An empty file would make every loop below vacuous, which is the failure mode this
        // whole exercise exists to avoid.
        XCTAssertGreaterThan(rows.count, 10, "vectors look truncated — every assertion would pass")
        return rows
    }

    // MARK: - Disposition

    /// The one classification both clients own: what happens to the payload behind byte 5.
    ///
    /// Mutation: fold 13 into `.transcriptIncoming` — heartbeats become bubbles, this reddens.
    func testDispositionMatchesTheCrossClientVectors() throws {
        for row in try loadVectors() {
            let expected = try XCTUnwrap(
                FrameDisposition(rawValue: row.disposition),
                "\(row.name): vectors carry disposition '\(row.disposition)' which this client has no case for"
            )
            XCTAssertEqual(
                ContentTypeRouting.disposition(forFrameContentType: UInt8(row.value)),
                expected,
                "\(row.name) = \(row.value): this client and the vectors disagree about what it means"
            )
        }
    }

    // MARK: - Routing kind

    /// `kind(for:)` is the sole classifier at the unseal boundary. Its answers are part of the
    /// protocol, not an iOS detail — a peer that routes 23 as an ordinary incoming message shows
    /// your own sent text as if it arrived from the other side.
    func testRoutingKindMatchesTheVectors() throws {
        for row in try loadVectors() {
            XCTAssertEqual(
                ContentTypeRouting.kind(for: UInt8(row.value)).rawValue,
                row.routingKind,
                "\(row.name) = \(row.value): routing kind"
            )
        }
    }

    // MARK: - Session control ops

    /// Which values denote a `SessionControl` op. A client that forgets one leaves the peer's
    /// handshake unanswered and the session half-open.
    ///
    /// Mutation: drop `case 21` from `op(forContentType:)` — END_SESSION stops being control.
    func testSessionControlOpsMatchTheVectors() throws {
        let names: [Shared_Proto_Messaging_V1_SessionOp: String] = [
            .ping: "PING",
            .ready: "READY",
            .resetInit: "RESET_INIT",
            .end: "END"
        ]
        for row in try loadVectors() {
            let actual = SessionControlCodec.op(forContentType: row.value).flatMap { names[$0] }
            XCTAssertEqual(
                actual,
                row.sessionControlOp,
                "\(row.name) = \(row.value): session control op"
            )
        }
    }

    // MARK: - Framed side channels

    /// Which framed payloads have a handler. `nil` here and a handler in `MessageRouter` would be
    /// a payload that is acknowledged and dropped.
    func testFramedSideChannelsMatchTheVectors() throws {
        for row in try loadVectors() {
            XCTAssertEqual(
                ContentTypeRouting.framedSideChannel(for: UInt8(row.value))?.rawValue,
                row.framedSideChannel,
                "\(row.name) = \(row.value): framed side channel"
            )
        }
    }

    // MARK: - What a sealed envelope may declare

    /// The narrowest of the five and the one with a privacy consequence: `SealedInner` is a
    /// plaintext proto the relay parses, so a value that appears here is a value the server can
    /// read off every sealed send. Only 0 (absence), 21 and 24 may.
    ///
    /// Mutation: return `.e2EeSignal` from `SealedEnvelopeType.generic` — the server can again
    /// tell conversation from control, which is what 2026-08-17 found.
    func testSealedEnvelopeDeclarableSetMatchesTheVectors() throws {
        for row in try loadVectors() {
            let proto = Shared_Proto_Core_V1_ContentType(rawValue: row.value) ?? .unspecified
            let declared = SealedEnvelopeType(declaring: proto).proto.rawValue
            let mayDeclare = declared == row.value
            XCTAssertEqual(
                mayDeclare,
                row.sealedInnerContentType,
                "\(row.name) = \(row.value): a sealed envelope \(row.sealedInnerContentType ? "must" : "must not") be able to declare this"
            )
        }
    }

    /// Cross-check of the two spellings iOS keeps of the same set. `sealedControlContentTypes`
    /// is the list producers read; `SealedEnvelopeType` is the type that narrows a value on the
    /// way out. They must name the same values apart from 0, which is absence rather than a
    /// declared type and therefore has no entry in the list.
    func testTheTwoSealedSpellingsAgree() throws {
        let fromVectors = try loadVectors()
            .filter { $0.sealedInnerContentType && $0.value != 0 }
            .map { UInt8($0.value) }
        XCTAssertEqual(
            Set(ContentTypeRouting.sealedControlContentTypes),
            Set(fromVectors),
            "sealedControlContentTypes and the vectors name different sets"
        )
    }
}
