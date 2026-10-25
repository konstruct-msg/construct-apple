#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Construct_Messenger

/// The transcript's rows are SwiftUI in one `UIHostingController` inside our `UIScrollView`
/// (`ChatTranscriptScrollView`). Until 2026-10-15 that controller was never made a child of the
/// screen's controller, so everything a row presents — a document's preview, a video, the emoji
/// sheet — was presented from a detached controller, which UIKit warns "will become a hard
/// exception in a future release" (TODO 150).
@MainActor
final class TranscriptHostParentTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    /// The transcript on screen, inside a screen controller the way SwiftUI puts it there.
    private func showTranscript() throws -> (screen: UIViewController, host: UIViewController) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "tests run hosted in the app, which has a scene"
        )
        let screen = UIHostingController(rootView: ChatTranscriptScrollView(
            bottomInset: 0, mode: .following, layoutPrimed: false, anchor: nil, scrollTarget: nil,
            landRequest: 0, onLanded: {}, onReachedScrollTarget: {}, onGeometry: { _ in },
            onUserInteraction: {}
        ) {
            Self.rows
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        self.window = window
        screen.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(Self.find(TranscriptScrollView.self, in: screen.view))
        return (screen, try XCTUnwrap(scrollView.rows))
    }

    private static var rows: some View {
        VStack { ForEach(0..<20, id: \.self) { Text("row \($0)").frame(height: 44) } }
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// Mutation: skip the `addChild` — this reddens.
    func testTheRowsControllerIsAChildOfTheScreen() throws {
        let (screen, host) = try showTranscript()
        XCTAssertNotNil(host.parent, "a row would present from a detached controller")
        var ancestor = host.parent
        while let current = ancestor, current !== screen { ancestor = current.parent }
        XCTAssertTrue(ancestor === screen, "the parent is the screen's own hierarchy")
    }

    /// Becoming a child must not hand the rows a safe area: the scroll view owns every inset
    /// (`contentInsetAdjustmentBehavior = .never`), and the window's (62 top, 34 bottom on the
    /// test phone) inside the rows would pad the first and last message. Mutation: drop
    /// `safeAreaRegions = []` — this reddens.
    func testTheRowsAreAsTallAsTheirContent() throws {
        let (_, host) = try showTranscript()
        XCTAssertGreaterThan(host.view.window?.safeAreaInsets.top ?? 0, 0, "the window must have a safe area, or this proves nothing")
        let alone = UIHostingController(rootView: Self.rows).sizeThatFits(in: CGSize(width: host.view.bounds.width, height: .greatestFiniteMagnitude))
        XCTAssertEqual(host.view.bounds.height, alone.height, accuracy: 0.5)
    }

    /// Leaving the window gives the child back, so a closed chat does not stay in the screen.
    /// Mutation: skip the `removeFromParent` — this reddens.
    func testTheRowsControllerLeavesWithTheWindow() throws {
        let (screen, host) = try showTranscript()
        window?.rootViewController = UIViewController()
        window?.layoutIfNeeded()
        // The screen kept alive: `parent` is weak, and a freed screen would pass this vacuously.
        withExtendedLifetime(screen) { XCTAssertNil(host.parent) }
    }
}
#endif
