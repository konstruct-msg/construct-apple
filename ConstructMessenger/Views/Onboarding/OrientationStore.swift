//
//  OrientationStore.swift
//  Construct Messenger
//
//  First-run product orientation (post identity init). Separate from registration.
//

import Foundation

enum OrientationStore {
    /// UserDefaults key — also used with `@AppStorage` for reactive routing.
    static let completedKey = "orientation_completed"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// Call on full local sign-out / wipe so the next identity sees orientation again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: completedKey)
    }
}
