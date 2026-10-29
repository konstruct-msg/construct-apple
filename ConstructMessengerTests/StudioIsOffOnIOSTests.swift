//
//  StudioIsOffOnIOSTests.swift
//  ConstructMessengerTests
//
//  The owner, 2026-10-29: iOS has no Studio, and its calls stay as they were. Studio's code is in
//  the shared folder, so the line that keeps an iPhone out is `StudioFeature.isEnabled`: off on
//  iOS whatever the user defaults say. With it off, an iPhone neither starts a studio nor makes
//  channels for one a Mac offers; the Mac's invite goes unanswered and its studio ends as no
//  answer, while the call goes on.
//

import XCTest
@testable import Construct_Messenger

final class StudioIsOffOnIOSTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: StudioFeature.defaultsKey)
        super.tearDown()
    }

    /// Mutation: `#else true` in `StudioFeature.isEnabled` — this reddens.
    func testStudioIsOffOnIOSEvenWhenTheDefaultSaysOn() throws {
        #if os(iOS)
        UserDefaults.standard.set(true, forKey: StudioFeature.defaultsKey)
        XCTAssertFalse(StudioFeature.isEnabled)
        #else
        throw XCTSkip("iOS only")
        #endif
    }
}
