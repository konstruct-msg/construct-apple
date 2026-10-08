//
//  SynapsCloudLayoutTests.swift
//  ConstructMessengerTests
//
//  The Synaps cloud is a hexagonal spiral from the centre (TODO 74): the most active contact in
//  the middle, rings of 6, 12, 18 around it, nothing overlapping, and a cloud that grows as √n
//  rather than as a column four wide.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

final class SynapsCloudLayoutTests: XCTestCase {

    private let pitch = SynapsCloudLayout.pitch

    /// Mutation: walk a ring one step short per side — cells repeat and two contacts share a place.
    func testNoTwoContactsOverlap() {
        let points = SynapsCloudLayout.spiral(count: 127)
        for i in points.indices {
            for j in points.indices where j > i {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                XCTAssertGreaterThanOrEqual(d, pitch - 0.001, "cells \(i) and \(j) overlap")
            }
        }
    }

    /// Mutation: start the first ring at the centre — the second contact lands on the first.
    func testRingsHoldOneThenSixThenTwelve() {
        let points = SynapsCloudLayout.spiral(count: 19)
        XCTAssertEqual(points[0], .zero)
        func ringRadius(_ p: CGPoint) -> CGFloat { hypot(p.x, p.y) }
        // Ring 1: the six neighbours of the centre, each one step away.
        for p in points[1...6] {
            XCTAssertLessThanOrEqual(ringRadius(p), pitch * SynapsCloudLayout.rowStretch + 0.001)
        }
        // Ring 2 is entirely further out than ring 1.
        let ring1Max = points[1...6].map(ringRadius).max() ?? 0
        let ring2Min = points[7...18].map(ringRadius).min() ?? 0
        XCTAssertGreaterThan(ring2Min, ring1Max)
    }

    /// The cloud is round: its radius grows as √n. Mutation: lay cells out in a row — 100 cells
    /// reach 99 pitches instead of about 6.
    func testRadiusGrowsAsSquareRootOfCount() {
        func radius(_ n: Int) -> CGFloat {
            SynapsCloudLayout.spiral(count: n).map { hypot($0.x, $0.y) }.max() ?? 0
        }
        let r25 = radius(25), r100 = radius(100)
        // Six rings hold 127; rows are spread by `rowStretch`, so that is the unit vertically.
        XCTAssertLessThan(r100, pitch * Swift.max(1, SynapsCloudLayout.rowStretch) * 7)
        // Four times the contacts, about twice the radius.
        XCTAssertEqual(r100 / r25, 2, accuracy: 0.5)
    }

    /// Mutation: sort ascending — the least active takes the centre.
    func testMostActiveContactTakesTheCentre() {
        let quiet = record("a"), busy = record("b"), middling = record("c")
        let layout = SynapsCloudLayout(
            contacts: [quiet, busy, middling],
            metrics: [
                "a": ContactMetrics(frequencyScore: 0.1, recency: .none, unreadCount: 0),
                "b": ContactMetrics(frequencyScore: 1.0, recency: .fresh, unreadCount: 0),
                "c": ContactMetrics(frequencyScore: 0.5, recency: .recent, unreadCount: 0),
            ]
        )
        XCTAssertEqual(layout.items.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(layout.items.first?.position, .zero)
    }

    /// Ties fall back to the id, so the same contacts keep the same places. Mutation: drop the
    /// tie-break — the order follows the input and changes with it.
    func testEqualActivityKeepsAStableOrder() {
        let ids = ["d", "a", "c", "b"]
        let forward = SynapsCloudLayout.order(ids.map(record), metrics: [:]).map(\.id)
        let reversed = SynapsCloudLayout.order(ids.reversed().map(record), metrics: [:]).map(\.id)
        XCTAssertEqual(forward, ["a", "b", "c", "d"])
        XCTAssertEqual(forward, reversed)
    }

    /// "Fit everyone" fits: at the returned scale the cloud's extent is inside the visible size.
    /// Mutation: fit by width only — a tall, narrow visible area overflows vertically.
    func testFitScaleFitsTheVisibleArea() {
        let layout = SynapsCloudLayout(contacts: (0..<40).map { record("c\($0)") }, metrics: [:])
        let visible = CGSize(width: 390, height: 300)
        let scale = layout.fitScale(in: visible)
        let half = layout.halfExtent
        XCTAssertLessThanOrEqual(2 * half.width * scale, visible.width)
        XCTAssertLessThanOrEqual(2 * half.height * scale, visible.height)
        XCTAssertEqual(SynapsCloudLayout(contacts: [record("x")], metrics: [:]).fitScale(in: visible), 1,
                       "one contact is never blown up past 1:1")
    }

    private func record(_ id: String) -> ContactRecord {
        ContactRecord(
            id: id, username: id, displayName: id, localAlias: nil, avatar: nil,
            knownIdentityKey: nil, accountAddress: nil, isContact: true, isBlocked: false,
            isSharingWithMe: false, amISharingWith: false, sharedWithMeAt: nil,
            addedAt: nil, ktStatus: .unverified, securityNotice: .none,
            profileEditedAtMs: 0, pendingAvatarRef: nil, pendingAvatarSince: nil
        )
    }
}
