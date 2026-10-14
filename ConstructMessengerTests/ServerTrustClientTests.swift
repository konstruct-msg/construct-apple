//
//  ServerTrustClientTests.swift
//  ConstructMessengerTests
//
//  What a `ServerTrustService` answer changes in the cache. The RPC is the VEIL-`on` carrier of
//  what `/.well-known` serves (vault decisions/veil-on-never-goes-direct.md), so it must store by
//  the same rules and trust nothing for having arrived over it.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class ServerTrustClientTests: XCTestCase {

    private let delegationsKey = "construct.server.trust_delegations"
    private let bundleKey = VeilCertFetcher.cachedBundleSigningKeyKey
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [delegationsKey, bundleKey, VeilCertFetcher.cachedSignedAtKey] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() {
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        for key in [delegationsKey, bundleKey, VeilCertFetcher.cachedSignedAtKey] where saved[key] == nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func response(manifest: Data = Data(), delegations: [Data] = []) -> Shared_Proto_Services_V1_GetServerTrustResponse {
        var r = Shared_Proto_Services_V1_GetServerTrustResponse()
        r.signedManifest = manifest
        r.delegations = delegations
        return r
    }

    func testServedDelegationsReplaceTheCache() {
        UserDefaults.standard.set([Data([1])], forKey: delegationsKey)
        ServerTrustClient.apply(response(delegations: [Data([2]), Data([3])]))
        XCTAssertEqual(ServerKeyManager.cachedServerDelegations(), [Data([2]), Data([3])])
    }

    /// Nothing served is "nothing to say", not "forget what you have".
    func testAnEmptyAnswerKeepsTheCache() {
        UserDefaults.standard.set([Data([1])], forKey: delegationsKey)
        UserDefaults.standard.set(Data(repeating: 7, count: 32), forKey: bundleKey)
        XCTAssertNil(ServerTrustClient.apply(response()))
        XCTAssertEqual(ServerKeyManager.cachedServerDelegations(), [Data([1])])
        XCTAssertEqual(UserDefaults.standard.data(forKey: bundleKey), Data(repeating: 7, count: 32))
    }

    /// The tunnel is not a reason to believe a manifest: one the build's key did not sign
    /// installs nothing, however it is shaped.
    func testAnUnsignedManifestInstallsNothing() throws {
        let original = Data(repeating: 7, count: 32)
        UserDefaults.standard.set(original, forKey: bundleKey)
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedSignedAtKey)
        let forged = try JSONSerialization.data(withJSONObject: [
            "signed_at": "2099-01-01T00:00:00Z",
            "bundle_signing_key": Data(repeating: 9, count: 32).base64EncodedString(),
            "signature": "ed25519:" + String(repeating: "A", count: 86),
        ])
        XCTAssertNil(ServerTrustClient.apply(response(manifest: forged)))
        XCTAssertEqual(UserDefaults.standard.data(forKey: bundleKey), original)
        XCTAssertNil(UserDefaults.standard.string(forKey: VeilCertFetcher.cachedSignedAtKey))
    }

    /// Asked before there is a session, so the interceptor must not demand one.
    func testTheRPCNeedsNoSession() {
        XCTAssertEqual(
            Shared_Proto_Services_V1_ServerTrustService.Method.GetServerTrust.descriptor.method,
            "GetServerTrust"
        )
        XCTAssertTrue(AuthInterceptor.isUnauthenticated(method: "GetServerTrust"))
    }
}
