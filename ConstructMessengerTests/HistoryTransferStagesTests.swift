//
//  HistoryTransferStagesTests.swift
//  ConstructMessengerTests
//
//  What the transfer screens show for each phase: the two stage rows and the status line.
//

import XCTest
@testable import Construct_Messenger

final class HistoryTransferStagesTests: XCTestCase {

    private typealias Status = HistoryTransferStage.Status

    /// Every phase, both stages, written out: a new phase must be placed here by hand.
    func testEveryPhaseShowsBothStages() {
        let expected: [(HistoryTransferPhase, Status, Status)] = [
            (.idle, .waiting, .waiting),
            (.transcript, .active, .waiting),
            (.chatsTransferred, .done, .active),
            (.media, .done, .active),
            (.complete, .done, .done),
            (.mediaIncomplete, .done, .stopped),
            (.saveFileInstead, .stopped, .waiting),
            (.skipped, .waiting, .waiting),
        ]
        for (phase, chats, media) in expected {
            XCTAssertEqual(HistoryTransferStage.chats.status(in: phase), chats, "chats in \(phase)")
            XCTAssertEqual(HistoryTransferStage.media.status(in: phase), media, "media in \(phase)")
        }
    }

    /// Before anything connects the two sides say different things: the sender looks, the
    /// receiver waits for the sender to start.
    func testIdleSaysWhoStarts() {
        XCTAssertEqual(HistoryTransferSide.sending.statusKey(in: .idle), "history_sync_looking")
        XCTAssertEqual(HistoryTransferSide.receiving.statusKey(in: .idle), "history_sync_waiting_for_other_device")
    }

    /// The transfer runs phone to phone as well as phone to computer: no status line names
    /// the kind of device at the other end. Read from the English table, which the others follow.
    func testNoStatusLineNamesTheOtherDevicesKind() throws {
        let phases: [HistoryTransferPhase] = [
            .idle, .transcript, .chatsTransferred, .media, .complete, .mediaIncomplete, .skipped, .saveFileInstead,
        ]
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        for side in [HistoryTransferSide.sending, .receiving] {
            for phase in phases {
                let key = side.statusKey(in: phase)
                let text = english.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(text, key, "\(key) has no English entry")
                for word in ["computer", "phone"] {
                    XCTAssertFalse(text.lowercased().contains(word), "\(key) says \(word): \(text)")
                }
            }
        }
    }
}
