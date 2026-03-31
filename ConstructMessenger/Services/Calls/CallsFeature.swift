import Foundation

enum CallsFeature {
    static let enabledKey = "callsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

