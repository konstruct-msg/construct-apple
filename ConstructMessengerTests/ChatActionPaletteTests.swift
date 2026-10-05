//
//  ChatActionPaletteTests.swift
//  ConstructMessengerTests
//
//  Where a finger lets go on the header's action palette decides what happens — or that nothing
//  does. Search to the left, call on the diagonal, video straight down, the button in the top
//  right. Each test names the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

final class ChatActionPaletteTests: XCTestCase {
    private let all = ChatAction.allCases
    private var radius: CGFloat { ChatActionPaletteGeometry.radius }

    private func pick(_ dx: CGFloat, _ dy: CGFloat, among actions: [ChatAction]? = nil) -> ChatAction? {
        ChatActionPaletteGeometry.action(at: CGSize(width: dx, height: dy), among: actions ?? all)
    }

    func testEachDirectionPicksItsAction() {
        XCTAssertEqual(pick(-radius, 0), .search)
        XCTAssertEqual(pick(-radius * 0.7, radius * 0.7), .call)
        XCTAssertEqual(pick(0, radius), .videoCall)
    }

    /// Mutation: drop the dead zone — a hold that does not move picks whatever is nearest.
    func testAFingerThatHasNotMovedPicksNothing() {
        XCTAssertNil(pick(0, 0))
        XCTAssertNil(pick(-10, 10))
    }

    /// Mutation: drop the outer bound — a finger dragged away to give up still starts a call.
    func testAFingerFarPastTheArcPicksNothing() {
        XCTAssertNil(pick(0, radius + ChatActionPaletteGeometry.cancelBeyond + 1))
    }

    /// Up and to the right is off the screen's edge and toward the status bar; nothing is there.
    /// Mutation: drop the sector bound — every direction picks its nearest action.
    func testAnEmptyDirectionPicksNothing() {
        XCTAssertNil(pick(radius, 0))
        XCTAssertNil(pick(0, -radius))
    }

    /// An action keeps its direction whatever else is offered, so the hand can learn it.
    /// Mutation: lay the present actions out evenly — without video, "down" becomes the call.
    func testWithoutVideoDownIsNotTheCall() {
        let noVideo: [ChatAction] = [.search, .call]
        XCTAssertNil(pick(0, radius, among: noVideo))
        XCTAssertEqual(pick(-radius * 0.7, radius * 0.7, among: noVideo), .call)
    }

    /// The actions sit apart enough that a 44 pt fingertip on one does not touch the next.
    func testNeighboursAreFarApart() {
        let s = ChatActionPaletteGeometry.offset(of: .search)
        let c = ChatActionPaletteGeometry.offset(of: .call)
        XCTAssertGreaterThan(hypot(s.width - c.width, s.height - c.height), ChatActionPaletteGeometry.itemSize + CTLayout.hitTarget / 2)
    }

    func testWhatIsOffered() {
        XCTAssertEqual(ChatAction.available(canCall: false, videoEnabled: true), [.search])
        XCTAssertEqual(ChatAction.available(canCall: true, videoEnabled: false), [.search, .call])
        XCTAssertEqual(ChatAction.available(canCall: true, videoEnabled: true), [.search, .call, .videoCall])
    }
}
