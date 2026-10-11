//
//  UnsealedMemory.swift
//  Construct Messenger
//
//  What the app keeps unsealed in memory only for speed, dropped when it leaves the screen: the
//  store key (`LocalStoreKey`) and decrypted message text (`MessageDisplayCache`). Both come back
//  on demand — the key from the Keychain, the text by decrypting again — so the cost is a little
//  work on return, and the gain is that a suspended app is not holding them. A memory dump of a
//  compromised device reads whatever is resident; this shortens what is.
//
//  iOS only: on macOS "background" is losing focus, which happens with every window switch.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum UnsealedMemory {

    private static var observer: NSObjectProtocol?

    /// Registered once, at launch.
    static func forgetOnBackground() {
        #if os(iOS)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { forget(reason: "background") }
        }
        #endif
    }

    static func forget(reason: String) {
        LocalStoreKey.forgetCached()
        MessageDisplayCache.shared.evictAll()
        Log.info("Unsealed memory dropped (\(reason)): store key and decrypted text", category: "Storage")
    }
}
