//
//  LinkDetectingText.swift
//  Construct Messenger
//
//  Created by Copilot on 30.01.2026.
//

import SwiftUI

/// Text view that automatically detects and makes URLs tappable
///
/// Features:
/// - Detects konstruct:// deep links
/// - Detects https://konstruct.cc links  
/// - Detects regular URLs
/// - Opens in-app for konstruct links
/// - Opens in Safari for external links
struct LinkDetectingText: View {
    let text: String
    let color: Color
    let deepLinkHandler: DeepLinkHandler?
    
    @Environment(\.openURL) private var openURL
    @State private var tappedURL: URL?
    
    init(_ text: String, color: Color = .primary, deepLinkHandler: DeepLinkHandler? = nil) {
        self.text = text
        self.color = color
        self.deepLinkHandler = deepLinkHandler
    }
    
    var body: some View {
        let attributedString = makeAttributedString()
        
        Text(attributedString)
            .environment(\.openURL, OpenURLAction { url in
                handleLink(url)
                return .handled
            })
    }
    
    private func handleLink(_ url: URL) {
        let urlString = url.absoluteString
        
        // Check if it's a konstruct link (deep link or invite)
        if urlString.hasPrefix("konstruct://") ||
           urlString.contains("konstruct.cc/add") ||
           urlString.contains("konstruct.cc/c/") {
            
            Log.info("🔗 Opening konstruct link in-app: \(urlString)", category: "LinkDetectingText")
            
            // Try to handle as deep link
            if let handler = deepLinkHandler {
                _ = handler.handleURL(url)
            } else {
                // Will be handled by system deep link handler
                #if canImport(UIKit)
                UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
        } else {
            // External link - open in Safari
            Log.info("🌐 Opening external link: \(urlString)", category: "LinkDetectingText")
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
    }
    
    // MARK: - AttributedString Generation

    private func makeAttributedString() -> AttributedString {
        // Try to parse as Markdown (inline only: **bold**, _italic_, `code`, [link](url))
        // Falls back to plain text if parsing fails.
        var result: AttributedString
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        result = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)

        // Regex patterns for different link types (detect raw URLs not wrapped in Markdown syntax)
        let patterns = [
            ("konstruct://[a-zA-Z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", true),  // konstruct:// links
            ("https://(?:www\\.)?konstruct\\.cc/[a-zA-Z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", true),  // konstruct.cc links
            ("https?://[a-zA-Z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", false)  // Generic URLs
        ]

        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

            for match in matches.reversed() {  // Process in reverse to maintain indices
                guard let range = Range(match.range, in: text) else { continue }
                let urlString = String(text[range])

                if let url = URL(string: urlString),
                   let attributedRange = Range(match.range, in: result) {
                    // Only apply if no link is already set (markdown may have set one)
                    if result[attributedRange].link == nil {
                        result[attributedRange].foregroundColor = .blue
                        result[attributedRange].underlineStyle = .single
                        result[attributedRange].link = url
                    }
                }
            }
        }

        // Set base color for non-link text (preserve markdown-parsed link colors)
        for run in result.runs where run.link == nil {
            let rangeInResult = run.range
            result[rangeInResult].foregroundColor = color
        }

        return result
    }
}

// MARK: - Preview

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        LinkDetectingText(
            "Check out https://konstruct.cc/add?invite=abc123",
            color: .primary
        )
        
        LinkDetectingText(
            "Scan this: konstruct://add?invite=xyz789",
            color: .white
        )
        .padding()
        .background(Color.blue)
        .cornerRadius(12)
        
        LinkDetectingText(
            "Mixed: some text https://example.com and https://konstruct.cc/c/user123?username=alice more text",
            color: .primary
        )
    }
    .padding()
}
