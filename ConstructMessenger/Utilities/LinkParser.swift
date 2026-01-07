//
//  LinkParser.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 07.01.2026.
//

import Foundation

enum ContactLinkError: Error, LocalizedError {
    case invalidURL
    case invalidPrefix
    case invalidPath
    case missingUserId
    case missingUsername

    var errorDescription: String? {
        switch self {
        case .invalidURL: return NSLocalizedString("The provided URL is invalid.", comment: "")
        case .invalidPrefix: return NSLocalizedString("The URL does not have the expected prefix for a contact link.", comment: "")
        case .invalidPath: return NSLocalizedString("The URL path is not in the correct format.", comment: "")
        case .missingUserId: return NSLocalizedString("The contact link is missing the user ID.", comment: "")
        case .missingUsername: return NSLocalizedString("The contact link is missing the username.", comment: "")
        }
    }
}

struct ContactInfo: Equatable {
    let userId: String
    let username: String
}

struct LinkParser {
    static let contactLinkPrefixes = [
        "https://konstruct.cc/c/",
        "https://web.konstruct.cc/c/"
    ]

    static func parseContactLink(_ url: URL) throws -> ContactInfo {
        let urlString = url.absoluteString

        // Check if URL matches any of the supported prefixes
        guard contactLinkPrefixes.contains(where: { urlString.hasPrefix($0) }) else {
            throw ContactLinkError.invalidPrefix
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ContactLinkError.invalidURL
        }

        // Extract userId from path: /c/{userId}
        let path = components.path
        let pathComponents = path.split(separator: "/").map(String.init)
        
        guard pathComponents.count == 2, pathComponents[0] == "c", let userId = pathComponents.get(at: 1) else {
            throw ContactLinkError.invalidPath
        }

        // Extract username from query items
        var username: String?
        if let queryItems = components.queryItems {
            for item in queryItems {
                if item.name == "username", let value = item.value {
                    username = value.removingPercentEncoding ?? value
                    break
                }
            }
        }
        
        guard let finalUsername = username, !finalUsername.isEmpty else {
            throw ContactLinkError.missingUsername
        }

        return ContactInfo(userId: userId, username: finalUsername)
    }
}
