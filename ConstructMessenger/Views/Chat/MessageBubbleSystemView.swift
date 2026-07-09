//
//  MessageBubbleSystemView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import Combine

struct MessageBubbleSystemView: View {
    let content: String

    var body: some View {
        HStack {
            Spacer()
            Text(content)
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(CTMessageBubbleTheme.incomingBackground)
                .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 0.5))
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
