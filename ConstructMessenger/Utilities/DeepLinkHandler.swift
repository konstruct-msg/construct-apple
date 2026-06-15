//
//  DeepLinkHandler.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 07.01.2026.
//

import Foundation

enum DeepLinkType: Equatable {
    case contact(ContactInfo)
    case openChat(chatId: String)
}

@Observable
class DeepLinkHandler {
    var deepLink: DeepLinkType?

    /// Result of the most recent `konstruct://veil-config` import, for UI feedback.
    /// `nil` until an import is attempted; the relay address on success.
    var veilConfigImported: String?
    var veilConfigImportError: String?

    // Function to handle URL manually, e.g., from AppDelegate or onOpenURL
    func handleURL(_ url: URL) -> Bool {
        Log.debug("DeepLinkHandler: Attempting to handle URL: \(url.absoluteString)", category: "DeepLink")

        // veil-front access config: konstruct://veil-config?d=<signed base64url blob>.
        // Verified + stored by VeilConfigImporter; never reaches the contact parser.
        if let blob = Self.veilConfigBlob(from: url) {
            let result = VeilConfigImporter.importBlob(blob)
            Task { @MainActor in
                switch result {
                case .success(let relay):
                    self.veilConfigImported = relay
                    self.veilConfigImportError = nil
                    // Re-snapshot the relay list so the freshly imported ticket is used.
                    let vm = VeilProxyManager.shared
                    if vm.mode != .off { vm.stop(); await vm.startIfEnabled() }
                case .failure(let error):
                    self.veilConfigImported = nil
                    self.veilConfigImportError = error.localizedDescription
                }
            }
            return true
        }

        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                Log.info("DeepLinkHandler: Successfully parsed contact deep link - userId: \(contactInfo.userId), username: \(contactInfo.username)", category: "DeepLink")
                await MainActor.run {
                    self.deepLink = .contact(contactInfo)
                    Log.debug("DeepLinkHandler: deepLink property set to: \(String(describing: self.deepLink))", category: "DeepLink")
                }
            } catch {
                Log.error("DeepLinkHandler: Failed to parse deep link \(url.absoluteString): \(error.localizedDescription)", category: "DeepLink")
                await MainActor.run {
                    self.deepLink = nil
                }
            }
        }
        
        // Return true optimistically - parsing happens async
        return true
    }

    /// Extract the signed config blob from a `konstruct://veil-config?d=<blob>` URL,
    /// or nil if the URL is not a veil-config link.
    private static func veilConfigBlob(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "konstruct" else { return nil }
        // Accept the marker as host (konstruct://veil-config?d=…) or first path
        // component (konstruct:///veil-config?d=…), to tolerate URL formatting.
        let isVeilConfig = url.host?.lowercased() == "veil-config"
            || url.pathComponents.contains { $0.lowercased() == "veil-config" }
        guard isVeilConfig else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "d" })?
            .value
    }
}
