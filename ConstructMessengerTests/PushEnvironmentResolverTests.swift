//
//  PushEnvironmentResolverTests.swift
//  Construct MessengerTests
//
//  The pair of values that stopped every push on 2026-08-18.
//

import XCTest
@testable import Construct_Messenger

final class PushEnvironmentResolverTests: XCTestCase {

    // MARK: - parse

    func testParsesApplesTwoSpellings() {
        XCTAssertEqual(PushEnvironmentResolver.parse("development"), .sandbox)
        XCTAssertEqual(PushEnvironmentResolver.parse("production"), .production)
    }

    func testTolerantOfSurroundingWhitespace() {
        XCTAssertEqual(PushEnvironmentResolver.parse("  production\n"), .production)
    }

    /// An unexpanded `$(APS_ENVIRONMENT)` leaves the empty string, and a target nobody configured
    /// leaves nil. Neither is evidence for an environment.
    func testEmptyAndMissingAreUndecidable() {
        XCTAssertEqual(PushEnvironmentResolver.parse(""), .unknown)
        XCTAssertEqual(PushEnvironmentResolver.parse(nil), .unknown)
        XCTAssertEqual(PushEnvironmentResolver.parse("$(APS_ENVIRONMENT)"), .unknown)
        XCTAssertEqual(PushEnvironmentResolver.parse("sandbox"), .unknown)
    }

    // MARK: - resolve

    /// The case that broke: a Beta build installed straight from Xcode declares production at
    /// build time and is signed for development. APNs mints the token from the signature, so the
    /// signature is what has to win.
    func testSignedEntitlementBeatsInfoPlist() {
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(signedEntitlement: "development",
                                            infoPlist: "production"),
            .sandbox
        )
    }

    /// A real TestFlight build: both agree, and nothing changes.
    func testAgreementResolvesToTheSharedValue() {
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(signedEntitlement: "production",
                                            infoPlist: "production"),
            .production
        )
    }

    /// Simulator: no embedded profile, so the build-time declaration is all there is — and there
    /// it is also correct, because nothing re-signed it.
    func testFallsBackToInfoPlistWhenThereIsNoProfile() {
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(signedEntitlement: nil, infoPlist: "development"),
            .sandbox
        )
    }

    /// Never guess. `.unknown` becomes UNSPECIFIED on the wire, and the server probes both
    /// endpoints instead of deleting a token it merely sent to the wrong one.
    func testNeitherSourceUsableIsUnknownRatherThanADefault() {
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(signedEntitlement: nil, infoPlist: nil),
            .unknown
        )
        XCTAssertEqual(
            PushEnvironmentResolver.resolve(signedEntitlement: "", infoPlist: "$(APS_ENVIRONMENT)"),
            .unknown
        )
    }

    // MARK: - disagree

    func testDisagreementIsReportedOnlyWhenBothResolved() {
        XCTAssertTrue(PushEnvironmentResolver.disagree(signedEntitlement: "development",
                                                       infoPlist: "production"))
        XCTAssertTrue(PushEnvironmentResolver.disagree(signedEntitlement: "production",
                                                       infoPlist: "development"))
        XCTAssertFalse(PushEnvironmentResolver.disagree(signedEntitlement: "production",
                                                        infoPlist: "production"))
        // Absent is not a contradiction — the simulator hits this on every launch and it is
        // normal, so it must not log an error.
        XCTAssertFalse(PushEnvironmentResolver.disagree(signedEntitlement: nil,
                                                        infoPlist: "production"))
        XCTAssertFalse(PushEnvironmentResolver.disagree(signedEntitlement: "production",
                                                        infoPlist: nil))
    }

    // MARK: - reading the profile

    /// A provisioning profile is a CMS blob with a plain XML plist inside. This is that shape:
    /// binary noise, the plist, then a signature trailer.
    func testExtractsApsEnvironmentFromAProfileShapedBlob() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>iOS Team Provisioning Profile</string>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key><string>development</string>
                <key>get-task-allow</key><true/>
            </dict>
        </dict>
        </plist>
        """
        var blob = Data([0x30, 0x82, 0x0B, 0xAD, 0xC0, 0xFF, 0xEE])
        blob.append(Data(plist.utf8))
        blob.append(Data([0x00, 0x01, 0x02, 0xDE, 0xAD]))

        XCTAssertEqual(PushEnvironmentResolver.apsEnvironment(inProfileData: blob), "development")
    }

    func testProfileWithoutTheEntitlementYieldsNil() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>Entitlements</key><dict><key>get-task-allow</key><true/></dict></dict>
        </plist>
        """
        XCTAssertNil(PushEnvironmentResolver.apsEnvironment(inProfileData: Data(plist.utf8)))
    }

    func testNonProfileBytesYieldNilRatherThanThrowing() {
        XCTAssertNil(PushEnvironmentResolver.apsEnvironment(inProfileData: Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertNil(PushEnvironmentResolver.apsEnvironment(inProfileData: Data()))
    }
}
