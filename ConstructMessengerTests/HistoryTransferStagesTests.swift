//
//  HistoryTransferStagesTests.swift
//  ConstructMessengerTests
//
//  What the transfer screens say for each phase: the picture, the title, the step under way.
//

import Network
import XCTest
@testable import Construct_Messenger

final class HistoryTransferStagesTests: XCTestCase {

    private typealias Screen = HistoryTransferScreen

    private static let phases: [HistoryTransferPhase] = [
        .idle, .transcript, .chatsTransferred, .media, .complete, .mediaIncomplete, .skipped, .saveFileInstead,
    ]

    /// Every phase, written out: a new phase must be placed here by hand.
    func testEveryPhaseHasItsPictureAndTitle() {
        let expected: [(HistoryTransferPhase, Screen.Picture, String, String)] = [
            (.idle, .looking, "history_sync_looking", "history_sync_title_waiting"),
            (.transcript, .moving, "history_sync_title_sending_chats", "history_sync_title_receiving_chats"),
            (.chatsTransferred, .moving, "history_sync_title_sending_media", "history_sync_title_receiving_media"),
            (.media, .moving, "history_sync_title_sending_media", "history_sync_title_receiving_media"),
            (.complete, .done, "history_sync_done", "history_sync_done"),
            (.mediaIncomplete, .incomplete, "history_sync_title_media_incomplete", "history_sync_title_media_incomplete"),
            (.saveFileInstead, .stopped, "history_sync_title_stopped", "history_sync_title_stopped"),
            (.skipped, .done, "history_sync_skip_sending", "history_sync_skip_sending"),
        ]
        for (phase, picture, sending, receiving) in expected {
            let send = Screen.of(phase: phase, side: .sending)
            let receive = Screen.of(phase: phase, side: .receiving)
            XCTAssertEqual(send.picture, picture, "sending picture in \(phase)")
            XCTAssertEqual(receive.picture, picture, "receiving picture in \(phase)")
            XCTAssertEqual(send.titleKey, sending, "sending title in \(phase)")
            XCTAssertEqual(receive.titleKey, receiving, "receiving title in \(phase)")
        }
    }

    /// The whole transfer is two steps: chats are step 1 and name what follows; once media is
    /// under way the chats are said to be done above it.
    func testTheStepUnderWayAndWhatSurroundsIt() {
        let chats = Screen.of(phase: .transcript, side: .sending)
        XCTAssertEqual(chats.step, Screen.Step(stage: .chats, number: 1, count: 2, nextKey: "history_sync_next_media"))
        XCTAssertNil(chats.doneKey)

        let media = Screen.of(phase: .media, side: .receiving)
        XCTAssertEqual(media.step, Screen.Step(stage: .media, number: 2, count: 2, nextKey: nil))
        XCTAssertEqual(media.doneKey, "history_sync_chats_done")

        let partial = Screen.of(phase: .mediaIncomplete, side: .sending)
        XCTAssertNil(partial.step)
        XCTAssertEqual(partial.doneKey, "history_sync_chats_done")
    }

    /// A Settings retry sends one stage: it is the only step, nothing follows it, and a media
    /// retry does not claim chats it never sent.
    func testARetryOfOneStageIsTheOnlyStep() {
        let chatsOnly = Screen.of(phase: .transcript, side: .sending, stages: [.chats])
        XCTAssertEqual(chatsOnly.step, Screen.Step(stage: .chats, number: 1, count: 1, nextKey: nil))

        let mediaOnly = Screen.of(phase: .media, side: .sending, stages: [.media])
        XCTAssertEqual(mediaOnly.step, Screen.Step(stage: .media, number: 1, count: 1, nextKey: nil))
        XCTAssertNil(mediaOnly.doneKey)
        XCTAssertNil(Screen.of(phase: .mediaIncomplete, side: .sending, stages: [.media]).doneKey)

        XCTAssertNil(Screen.of(phase: .idle, side: .sending, stages: [.media]).footerKey,
                     "one stage has no order to announce")
    }

    /// Only the device that looks can fail to see the other, and only before anything moved;
    /// that is when the file is offered at the foot.
    func testNotSeenIsTheSendersAndOnlyWhileIdle() {
        let notSeen = Screen.of(phase: .idle, side: .sending, peerNotSeen: true)
        XCTAssertEqual(notSeen.picture, .notSeen)
        XCTAssertEqual(notSeen.footerKey, "history_sync_footer_file")
        XCTAssertEqual(Screen.of(phase: .idle, side: .receiving, peerNotSeen: true).picture, .looking)
        XCTAssertEqual(Screen.of(phase: .transcript, side: .sending, peerNotSeen: true).picture, .moving)
    }

    /// The media retry is on the device that has the history, so only that one is sent there.
    func testTheMediaRetryIsNamedOnTheSendingDevice() {
        XCTAssertEqual(Screen.of(phase: .mediaIncomplete, side: .sending).bodyKey, "history_sync_body_media_retry_here")
        XCTAssertEqual(Screen.of(phase: .mediaIncomplete, side: .receiving).bodyKey, "history_sync_body_media_retry_other")
    }

    /// Refused the local network, either side says so while it waits — and only while it
    /// waits: once something moves, the network was there.
    ///
    /// Mutation: drop the `.idle where localNetworkDenied` case — the screen says "looking" and
    /// the person never learns why; this reddens.
    /// Mutation: put the case on every phase — a transfer under way shows the denial; this
    /// reddens.
    func testARefusedLocalNetworkIsSaidWhileWaiting() {
        for side in [HistoryTransferSide.sending, .receiving] {
            let waiting = Screen.of(phase: .idle, side: side, localNetworkDenied: true)
            XCTAssertEqual(waiting.titleKey, "history_sync_title_local_network", "\(side)")
            XCTAssertEqual(waiting.bodyKey, "history_sync_body_local_network", "\(side)")
            XCTAssertEqual(waiting.picture, .notSeen)
            XCTAssertEqual(Screen.of(phase: .transcript, side: side, localNetworkDenied: true).picture, .moving)
        }
    }

    /// The system's refusal is told apart from the network's other troubles.
    ///
    /// Mutation: `isLocalNetworkDenied` answers true for any DNS error — this reddens.
    func testOnlyThePolicyRefusalIsALocalNetworkDenial() {
        XCTAssertTrue(NearbyWait.isLocalNetworkDenied(.dns(-65_570)))
        XCTAssertFalse(NearbyWait.isLocalNetworkDenied(.dns(-65_537)), "an unknown DNS-SD error")
        XCTAssertFalse(NearbyWait.isLocalNetworkDenied(.posix(.ENETDOWN)))
    }

    /// Every line resolves in English, and none names the kind of device at the other end:
    /// the transfer runs phone to phone as well as phone to computer.
    func testEveryLineResolvesAndNoneNamesTheOtherDevicesKind() throws {
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        var keys: Set<String> = [
            "history_sync_device_this", "history_sync_device_other", "history_sync_step_of",
            "history_sync_open_settings", "history_sync_body_local_network_mac",
        ]
        for side in [HistoryTransferSide.sending, .receiving] {
            for phase in Self.phases {
                for notSeen in [false, true] {
                    for denied in [false, true] {
                        keys.formUnion(Screen.of(phase: phase, side: side, peerNotSeen: notSeen, localNetworkDenied: denied).keys)
                    }
                }
            }
        }
        for key in keys {
            let text = english.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(text, key, "\(key) has no English entry")
            for word in ["computer", "phone"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(key) says \(word): \(text)")
            }
        }
    }
}
