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

    // MARK: - Notes

    func saveToNotes(_ row: TranscriptRow) {
        Task {
            do {
                let outcome = try await NoteSaver.save(row, sourceName: peerName)
                let key = outcome == .saved ? "notes_saved" : "notes_saved_without_files"
                ErrorRouter.shared.report(.notice(message: UserText(key).resolved, actionTitle: nil))
            } catch {
                Log.error("Notes: a message was not saved — \(error)", category: "Notes")
                ErrorRouter.shared.report(.notice(message: UserText("notes_not_saved").resolved, actionTitle: nil))
            }
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
