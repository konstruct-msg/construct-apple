//
//  StreamResumeChannelsTests.swift
//  ConstructMessengerTests
//
//  A channel opened while the stream was paused — a silent push's fetch, in the background — is
//  not the one the app comes back on: iOS may have suspended it, and its socket dies without a
//  word (todo 315; 2026-11-25: a fetch at 10:10:28, the app opened at 10:10:54, the first call
//  answered at 10:11:10).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class StreamResumeChannelsTests: XCTestCase {

    private var savedMode: String?

    override func setUp() async throws {
        savedMode = UserDefaults.standard.string(forKey: VeilProxyStore.modeKey)
        UserDefaults.standard.set(VeilMode.auto.rawValue, forKey: VeilProxyStore.modeKey)
    }

    override func tearDown() async throws {
        MessageStreamManager.shared.disconnect()
        if let savedMode {
            UserDefaults.standard.set(savedMode, forKey: VeilProxyStore.modeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: VeilProxyStore.modeKey)
        }
    }

    func testResumingDoesNotReuseAChannelOpenedWhilePaused() throws {
        let channels = GRPCChannelManager.shared
        try XCTSkipIf(channels.veilProxyPort() != nil, "a tunnel is up in this host; the case needs none")
        MessageStreamManager.shared.pause()
        let background = try channels.acquirePersistentClient()
        let backgroundSealed = try channels.acquireSealedPersistentClient()
        XCTAssertTrue(try channels.acquirePersistentClient() === background, "held until the stream resumes")

        MessageStreamManager.shared.resume { _ in }

        XCTAssertFalse(try channels.acquirePersistentClient() === background)
        XCTAssertFalse(try channels.acquireSealedPersistentClient() === backgroundSealed)
    }

    /// The sealed channel alone: dropping the other one takes it along only when the other is held.
    func testResumingDropsASealedChannelHeldAlone() throws {
        let channels = GRPCChannelManager.shared
        try XCTSkipIf(channels.veilProxyPort() != nil, "a tunnel is up in this host; the case needs none")
        MessageStreamManager.shared.pause()
        channels.invalidatePersistentClient()
        let sealed = try channels.acquireSealedPersistentClient()
        MessageStreamManager.shared.resume { _ in }
        XCTAssertFalse(try channels.acquireSealedPersistentClient() === sealed)
    }

    /// Not paused: nothing is dropped.
    func testResumingAStreamThatWasNotPausedLeavesTheChannels() throws {
        let channels = GRPCChannelManager.shared
        try XCTSkipIf(channels.veilProxyPort() != nil, "a tunnel is up in this host; the case needs none")
        XCTAssertFalse(MessageStreamManager.shared.isPaused)
        let live = try channels.acquirePersistentClient()
        MessageStreamManager.shared.resume { _ in }
        XCTAssertTrue(try channels.acquirePersistentClient() === live)
    }
}
