import Foundation

enum ConfigurationManager {

    enum Error: Swift.Error {
        case missingKey(String)
        case invalidValue
    }

    static func value<T>(for key: String) throws -> T where T: LosslessStringConvertible {
        guard let object = Bundle.main.object(forInfoDictionaryKey: key) else {
            throw Error.missingKey("Key '\(key)' not found in Info.plist. Ensure it is set in the target's Info tab and linked via .xcconfig.")
        }

        switch object {
        case let value as T:
            return value

        case let string as String:
            guard let value = T(string) else { fallthrough }
            return value

        default:
            throw Error.invalidValue
        }
    }
}
