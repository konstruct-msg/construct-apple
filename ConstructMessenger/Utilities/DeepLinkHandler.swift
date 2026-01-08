//
//  DeepLinkHandler.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 07.01.2026.
//

import Foundation
import Combine

enum DeepLinkType: Equatable {
    case contact(ContactInfo)
    // Add other deep link types here if needed
}

class DeepLinkHandler: ObservableObject {
    @Published var deepLink: DeepLinkType?

    // Function to handle URL manually, e.g., from AppDelegate or onOpenURL
    func handleURL(_ url: URL) -> Bool {
        Log.debug("DeepLinkHandler: Attempting to handle URL: \(url.absoluteString)", category: "DeepLink")

        do {
            let contactInfo = try LinkParser.parseContactLink(url)
            Log.info("DeepLinkHandler: Successfully parsed contact deep link - userId: \(contactInfo.userId), username: \(contactInfo.username)", category: "DeepLink")
            self.deepLink = .contact(contactInfo)
            Log.debug("DeepLinkHandler: deepLink property set to: \(String(describing: self.deepLink))", category: "DeepLink")
            return true
        } catch {
            Log.error("DeepLinkHandler: Failed to parse deep link \(url.absoluteString): \(error.localizedDescription)", category: "DeepLink")
            self.deepLink = nil
            return false
        }
    }
}
