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
                .font(CTFont.regular(ChatUIConstants.Typography.systemSize))
                .foregroundColor(Color.CT.textDim)
                .padding(.horizontal, ChatUIConstants.Bubble.horizontalPadding)
                .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding + 1)
                .background(CTMessageBubbleTheme.incomingBackground)
                .clipShape(CTShape.control())
                .overlay(
                    CTShape.control().stroke(
                        Color.CT.noise,
                        lineWidth: ChatUIConstants.Bubble.strokeWidth
                    )
                )
            Spacer()
        }
        .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
    }
}
