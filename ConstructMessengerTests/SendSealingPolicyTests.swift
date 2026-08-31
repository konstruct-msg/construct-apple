//
//  SendSealingPolicyTests.swift
//  ConstructMessengerTests
//
//  Two questions about the sealing chokepoint, asked separately because they fail separately:
//  does the policy table say the right thing, and is the list of sites allowed to invoke it
//  still the list someone justified.
//

import XCTest
@testable import Construct_Messenger

/// The policy itself. A table, enumerated — `violation` is pure precisely so this can be a table
/// and not a branch reached only by a live RPC.
final class SendSealingPolicyTests: XCTestCase {

    func testASealedSendGoesOut() {
        XCTAssertNil(SendSealing.sealed(Data([0x09])).violation(stealthEnabled: true))
        XCTAssertNil(SendSealing.sealed(Data([0x09])).violation(stealthEnabled: false))
    }

    /// The hole this whole type exists to close, and the one a caller cannot see.
    /// `buildEnvelope` treats empty sealed bytes as an identified send — correctly, since the
    /// alternative is an envelope with neither sender nor seal, which nothing can route. So a
    /// caller whose seal came back empty would have sent identified while believing it sealed,
    /// and the log line would have said `[STEALTH]`.
    ///
    /// Mutation: drop the `isEmpty` check — this reddens.
    func testAnEmptySealIsRefused() {
        XCTAssertNotNil(SendSealing.sealed(Data()).violation(stealthEnabled: true),
                        "an empty seal is an identified send wearing a seal's name")
        XCTAssertNotNil(SendSealing.sealed(Data()).violation(stealthEnabled: false),
                        "still refused with stealth off — the envelope is undeliverable either way")
    }

    /// Own-device traffic is legitimate under the invariant rather than tolerated by it, so it
    /// passes with stealth on. If this ever needs to become conditional, the condition belongs
    /// here, where one test can read it.
    func testOwnDeviceTrafficIsExemptWithStealthOn() {
        XCTAssertNil(SendSealing.identified(.ownDevices).violation(stealthEnabled: true))
    }

    /// The exemption that is not a property of the site. Any send path may take the
    /// stealth-off branch, and none may take it while stealth is on — a site that lands here
    /// through a wrong branch must fail closed rather than ship an identified envelope.
    ///
    /// Mutation: return nil unconditionally for this case — this reddens.
    func testTheStealthDisabledExemptionIsRefusedWhileStealthIsOn() {
        XCTAssertNotNil(SendSealing.identified(.stealthDisabled).violation(stealthEnabled: true))
        XCTAssertNil(SendSealing.identified(.stealthDisabled).violation(stealthEnabled: false))
    }

    func testTheInnerBytesReachTheEnvelopeOnlyWhenSealed() {
        XCTAssertEqual(SendSealing.sealed(Data([0x01, 0x02])).sealedInnerBytes, Data([0x01, 0x02]))
        XCTAssertNil(SendSealing.identified(.ownDevices).sealedInnerBytes)
        XCTAssertNil(SendSealing.identified(.stealthDisabled).sealedInnerBytes)
    }

    /// Every case must be answerable. A new exemption added without a rule here would otherwise
    /// inherit whatever the switch's last branch happens to do.
    func testEveryExemptionHasAnAnswerUnderBothStealthStates() {
        for exemption in SealingExemption.allCases {
            _ = SendSealing.identified(exemption).violation(stealthEnabled: true)
            _ = SendSealing.identified(exemption).violation(stealthEnabled: false)
        }
        XCTAssertEqual(SealingExemption.allCases.count, 2,
                       "an exemption was added or removed — justify it against the invariant and update SealingExemptionSiteTests")
    }
}

/// The table is only worth as much as the wiring to it. These two call the real send functions
/// and assert they refuse *before* any RPC — the guard runs first, so no network is involved and
/// no message leaves the device.
final class SealingChokepointTests: XCTestCase {

    private var previousOverride: Any?

    override func setUp() {
        super.setUp()
        previousOverride = UserDefaults.standard.object(forKey: "stealth_mode_enabled")
        UserDefaults.standard.set(true, forKey: "stealth_mode_enabled")
    }

    override func tearDown() {
        if let previousOverride {
            UserDefaults.standard.set(previousOverride, forKey: "stealth_mode_enabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "stealth_mode_enabled")
        }
        super.tearDown()
    }

    /// Mutation: delete the guard from `sendMessage` — this reddens. Without it the policy table
    /// would still pass every one of its own tests while nothing consulted it.
    func testSendMessageRefusesAnIdentifiedSendWhileStealthIsOn() async {
        do {
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: "m1",
                recipientId: "14f28d31-0000-0000-0000-000000000000",
                senderId: "s",
                conversationId: "c",
                encryptedPayload: Data([0x01]),
                timestamp: 1,
                sealing: .identified(.stealthDisabled)
            )
            XCTFail("an identified send went out with stealth on")
        } catch is StealthDowngradeBlocked {
            // Refused at the chokepoint, before the RPC.
        } catch {
            XCTFail("expected StealthDowngradeBlocked, got \(error)")
        }
    }

    /// The dedicated sealed RPC has no outer envelope, so an empty inner is not a downgrade —
    /// it is an envelope the relay accepts and no one can route.
    ///
    /// Mutation: delete the guard from `sendSealedMessage` — this reddens.
    func testSendSealedMessageRefusesAnEmptyInner() async {
        do {
            _ = try await MessagingServiceClient.shared.sendSealedMessage(sealedInner: Data())
            XCTFail("an empty seal went out")
        } catch is StealthDowngradeBlocked {
            // Refused before the RPC.
        } catch {
            XCTFail("expected StealthDowngradeBlocked, got \(error)")
        }
    }
}

/// Which files may name an exemption.
///
/// ## Why a source scan
///
/// The compiler already forces every send site to answer, because `sealing:` has no default.
/// What it cannot ask is whether the answer was justified: `.identified(.ownDevices)` typed into
/// a new file compiles and ships. That is the shape both existing exclusions had — each was added
/// in one line by someone with a local reason, and neither was noticed again until the file was
/// read four months later.
///
/// So the exemption list is data, and this is the test that reads it. A new site reddens here at
/// the moment it is written, with the file named.
final class SealingExemptionSiteTests: XCTestCase {

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
    }

    /// The declared list. A file appears here because someone justified it against the invariant
    /// **no send names the (sender, recipient) pair to the server** — not because it happened to
    /// need an unsealed branch.
    private static let allowed: [SealingExemption: Set<String>] = [

        // SENDER_SYNC to our own devices. One file, and §B shrank it as this comment predicted:
        // the peer's devices now seal to the target device's identity key, so what remains under
        // this exemption is only traffic where both ends are us.
        .ownDevices: ["MultiDeviceSendCoordinator.swift"],

        // The stealth-off branches. These exist only because DEBUG can turn stealth off; in
        // Release `StealthPolicy.isEnabled` is a compile-time `true` and the chokepoint refuses
        // every one of them. Their number is the number of send paths, so it shrinks when paths
        // are merged and not otherwise.
        .stealthDisabled: [
            "MessagingServiceClient.swift",     // END_SESSION, which has its own RPC
            "CallManager.swift",                // WebRTC signalling
            "MessageRetryManager.swift",        // queued-chunk retry
            "ChunkedMessageDelivery.swift",     // message bodies
            "OutboundSessionService.swift",     // heartbeat and delivery receipt
            "SessionCoordinator.swift",         // session control
            "ChatSessionManager.swift",         // init ping
            "MultiDeviceSendCoordinator.swift", // fan-out to a peer's devices, once §B sealed it
        ],
    ]

    /// The file that declares the cases is not a site.
    private static let declarationFile = "SendSealing.swift"

    private func files(naming exemption: SealingExemption) throws -> Set<String> {
        let needle = ".identified(.\(exemption.rawValue))"
        var found: Set<String> = []
        let walker = FileManager.default.enumerator(at: sourceRoot,
                                                    includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            guard name != Self.declarationFile else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains(needle) { found.insert(name) }
        }
        return found
    }

    func testOnlyDeclaredFilesClaimAnExemption() throws {
        for exemption in SealingExemption.allCases {
            let declared = Self.allowed[exemption] ?? []
            let actual = try files(naming: exemption)

            let undeclared = actual.subtracting(declared)
            XCTAssertTrue(
                undeclared.isEmpty,
                """
                \(undeclared.sorted().joined(separator: ", ")) send unsealed under \
                .\(exemption.rawValue) without being on the list.
                An exemption is a protocol decision: justify it against "no send names the \
                (sender, recipient) pair to the server", then add the file here.
                """
            )

            let gone = declared.subtracting(actual)
            XCTAssertTrue(
                gone.isEmpty,
                """
                \(gone.sorted().joined(separator: ", ")) no longer claim .\(exemption.rawValue). \
                That is progress — drop them from the list so it keeps naming only what is real.
                """
            )
        }
    }

    /// The chokepoint works by having no default. A `sealing: SendSealing = .identified(…)` would
    /// restore exactly the state this replaced: a send path that ships unsealed by saying nothing.
    ///
    /// Mutation: give the parameter a default — this reddens.
    func testTheSealingArgumentHasNoDefault() throws {
        let client = sourceRoot
            .appendingPathComponent("Networking/gRPC/Services/MessagingServiceClient.swift")
        let text = try String(contentsOf: client, encoding: .utf8)
        XCTAssertTrue(text.contains("sealing: SendSealing\n"),
                      "MessagingServiceClient.sendMessage must declare `sealing: SendSealing`")
        XCTAssertFalse(text.contains("sealing: SendSealing ="),
                       "a default on `sealing:` lets a new send path ship unsealed by saying nothing")
    }
}
