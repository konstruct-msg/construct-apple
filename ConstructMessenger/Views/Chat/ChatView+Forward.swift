//
//  ChatView+Forward.swift
//  Construct Messenger
//
//  The forward flow, split out of ChatView.swift.
//

// iOS only: the Desktop target excludes ChatView.swift / AccountSettingsView.swift.
#if os(iOS)
import SwiftUI
import CoreData
import UniformTypeIdentifiers

extension ChatView {
    // MARK: - Forward

    func startForward(_ rows: [TranscriptRow]) {
        forwarding = rows
        showingForwardPicker = true
    }

    func forwardSelectedMessages() {
        startForward(viewModel.entries.map(\.row).filter { selectedMessages.contains($0.id) })
    }

    /// The picked chat sends it: this one at once, any other when it opens.
    func finishForward(to chat: ChatRecord) {
        ForwardDrafts.shared.hand(ForwardItem.content(of: forwarding), to: chat.id)
        forwarding = []
        withAnimation {
            selectedMessages.removeAll()
            isEditMode = false
        }
        if chat.id != viewModel.conversation.chatId {
            chatsViewModel.chatToOpen = chat.id
        }
    }

    func sendForwardedHere() async {
        let items = ForwardDrafts.shared.take(for: viewModel.conversation.chatId)
        guard !items.isEmpty else { return }
        let failures = await viewModel.forward(items)
        if !failures.isEmpty { forwardFailed = true }
    }

}
#endif
