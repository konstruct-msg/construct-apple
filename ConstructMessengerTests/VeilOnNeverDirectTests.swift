//
//  VeilOnNeverDirectTests.swift
//  ConstructMessengerTests
//
//  VEIL `on` means nothing of ours on the network outside the tunnel (owner, 2026-10-13,
//  vault decisions/veil-on-never-goes-direct.md). The route rule is in the shared vectors
//  (TransportRouteConformanceTests); these are the channels that would dial the server directly.
//

import XCTest
@testable import Construct_Messenger

final class VeilOnNeverDirectTests: XCTestCase {

    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: VeilProxyStore.modeKey)
    }

    override func tearDown() {
        if let savedMode {
            UserDefaults.standard.set(savedMode, forKey: VeilProxyStore.modeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: VeilProxyStore.modeKey)
        }
        super.tearDown()
    }

    func testOnlyOnForbidsTheDirectPath() {
        XCTAssertFalse(VeilMode.on.allowsDirectPath)
        XCTAssertTrue(VeilMode.auto.allowsDirectPath)
        XCTAssertTrue(VeilMode.off.allowsDirectPath)
    }

    /// `on` is a choice the person makes. As a silent default (macOS until 2026-10-13) it would
    /// leave a Mac with no front offline without anyone having chosen to hide.
    func testNoPlatformDefaultsToOn() {
        XCTAssertEqual(VeilMode.platformDefault, .auto)
    }

    func testWithOnAndNoTunnelNoChannelDialsTheServer() throws {
        UserDefaults.standard.set(VeilMode.on.rawValue, forKey: VeilProxyStore.modeKey)
        let manager = GRPCChannelManager.shared
        try XCTSkipIf(manager.veilProxyPort() != nil, "a tunnel is up in this host; the case needs none")

        XCTAssertThrowsError(try manager.makeClient()) { XCTAssertTrue($0 is VeilTunnelNotUp) }
        XCTAssertThrowsError(try manager.makeSealedClient()) { XCTAssertTrue($0 is VeilTunnelNotUp) }
        #if os(iOS)
        XCTAssertNil(manager.acquireEngineQuicChannel(), "QUIC is a direct path too")
        #endif
    }

    func testWithAutoAndNoTunnelTheDirectPathStillOpens() throws {
        UserDefaults.standard.set(VeilMode.auto.rawValue, forKey: VeilProxyStore.modeKey)
        let manager = GRPCChannelManager.shared
        try XCTSkipIf(manager.veilProxyPort() != nil, "a tunnel is up in this host; the case needs none")
        XCTAssertNoThrow(try manager.makeClient(), "auto is direct-first; only on refuses")
    }

    // MARK: - The well-known is plain HTTPS, outside the tunnel

    func testWithOnNeitherWellKnownFetchHasASource() {
        XCTAssertTrue(VeilCertFetcher.manifestSources(mode: .on).isEmpty)
        XCTAssertNil(ServerKeyManager.wellKnownURL(host: "example.invalid", mode: .on))
    }

    func testOffTheManifestStillComesFromOneSource() {
        for mode in [VeilMode.auto, .off] {
            XCTAssertEqual(VeilCertFetcher.manifestSources(mode: mode).count, 1)
            XCTAssertNotNil(ServerKeyManager.wellKnownURL(host: "example.invalid", mode: mode))
        }
    }

    /// A request to the project's repository says by itself whose app is asking (owner, 2026-10-13).
    func testNoManifestSourceIsTheRepositoryMirror() {
        for mode in [VeilMode.auto, .off, .on] {
            for url in VeilCertFetcher.manifestSources(mode: mode) {
                XCTAssertFalse(url.host?.contains("github") ?? true, "\(url)")
            }
        }
    }
}
