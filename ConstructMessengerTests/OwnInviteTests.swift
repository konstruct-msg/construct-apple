//
//  OwnInviteTests.swift
//  ConstructMessengerTests
//
//  Our own invite, opened on our own account, is refused before it is redeemed: until 2026-11-24
//  the server burned it first and the screens then dropped it without a word.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class OwnInviteTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Fields: Decodable { let uuid: String }
        struct Valid: Decodable {
            let fields: Fields
            let binary: String
        }
        let valid: [Valid]
    }

    override func tearDown() async throws {
        SessionAddressing.ownAccountOverrideForTesting = nil
        try await super.tearDown()
    }

    /// The conformance invite as the link a person opens; its time is long past.
    private func link() throws -> (url: URL, inviter: String) {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_invite.json")
        let vector = try XCTUnwrap(JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file)).valid.first)
        let payload = try XCTUnwrap(InviteBinaryCodec.data(hex: vector.binary)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (try XCTUnwrap(URL(string: "konstruct://add?invite=\(payload)")), vector.fields.uuid)
    }

    private func refusal(_ url: URL) async -> ContactLinkError? {
        do {
            _ = try await LinkParser.parseDynamicInvite(url)
            return nil
        } catch {
            return error as? ContactLinkError
        }
    }

    /// Named as ours, though it has expired too: the check comes before everything the redeem does.
    /// Mutation: drop the guard, or move it below `verify` — it reads as expired.
    func testOurOwnInviteIsRefusedAsOurs() async throws {
        let (url, inviter) = try link()
        SessionAddressing.ownAccountOverrideForTesting = inviter

        guard case .ownInvite = await refusal(url) else {
            return XCTFail("our own invite must be refused as ours")
        }
    }

    /// Mutation: invert the guard — everyone's invite reads as our own.
    func testAnothersInviteIsJudgedOnItsOwn() async throws {
        let (url, _) = try link()
        SessionAddressing.ownAccountOverrideForTesting = "7574fdec-2c1a-4a0f-9d3e-1b0b6f2c9a41"

        guard case .inviteExpired = await refusal(url) else {
            return XCTFail("another account's invite goes on to verification")
        }
    }
}
