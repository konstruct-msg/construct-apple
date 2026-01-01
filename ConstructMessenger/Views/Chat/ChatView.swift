//
//  ChatView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

struct ChatView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var viewModel: ChatViewModel  // ✅ FIX: StateObject persists across view updates
    @State private var messageText = ""
    @State private var replyingTo: Message?

    init(chat: Chat, context: NSManagedObjectContext) {
        // ✅ FIX: Use StateObject initializer to create ViewModel only once
        _viewModel = StateObject(wrappedValue: ChatViewModel(chat: chat, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSending {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Sending...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 0) {
                                MessageBubble(
                                    message: message,
                                    isLastInGroup: isLastInGroup(message, at: index, in: viewModel.messages),
                                    onRetry: { msg in
                                        viewModel.retryMessage(msg)
                                    },
                                    onReply: { msg in
                                        replyingTo = msg
                                    },
                                    onDelete: { msg in
                                        deleteMessage(msg)
                                    }
                                )
                                .id(message.id)

                                // Add spacing after each message
                                if index < viewModel.messages.count - 1 {
                                    Spacer()
                                        .frame(height: spacingAfterMessage(at: index, in: viewModel.messages))
                                }
                            }
                        }
                    }
                    .padding()
                }
                .onAppear {
                    if AppConstants.enableDebugLogging {
                        print("ChatView appeared with \(viewModel.messages.count) messages")
                    }
                }
                .onChange(of: viewModel.messages.count) { count in
                    if AppConstants.enableDebugLogging {
                        print("ChatView: messages count changed to \(count)")
                    }
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            MessageInputView(
                text: $messageText,
                isSending: viewModel.isSending,
                replyingTo: replyingTo,
                onSend: {
                    viewModel.sendMessage(text: messageText, replyTo: replyingTo)
                    messageText = ""
                    replyingTo = nil
                },
                onCancelReply: {
                    replyingTo = nil
                }
            )
        }
        .navigationTitle(viewModel.chat.otherUser?.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
            }
        }
    }

    // MARK: - Actions

    private func deleteMessage(_ message: Message) {
        viewContext.delete(message)
        do {
            try viewContext.save()
        } catch {
            print("Failed to delete message: \(error)")
        }
    }

    // MARK: - Message Grouping Logic

    /// Determines if a message is the last in a group of consecutive messages from the same sender
    private func isLastInGroup(_ message: Message, at index: Int, in messages: [Message]) -> Bool {
        // If this is the last message, it's always the last in its group
        guard index < messages.count - 1 else {
            return true
        }

        let nextMessage = messages[index + 1]

        // Different sender = end of group
        if message.isSentByMe != nextMessage.isSentByMe {
            return true
        }

        // If more than 5 minutes apart, start a new group
        let timeDifference = nextMessage.timestamp.timeIntervalSince(message.timestamp)
        if timeDifference > 300 { // 5 minutes
            return true
        }

        return false
    }

    /// Returns appropriate spacing after a message
    private func spacingAfterMessage(at index: Int, in messages: [Message]) -> CGFloat {
        let message = messages[index]

        // If this is the last in group, use larger spacing
        if isLastInGroup(message, at: index, in: messages) {
            return 12
        }

        // Otherwise, use compact spacing within the group
        return 4
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    // Create sample data
    let user = PreviewHelpers.createSampleUser(context: context, username: "alice", displayName: "Alice")
    let chat = PreviewHelpers.createSampleChat(context: context, with: user)

    // Add sample messages
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Hi! How are you?")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: true, text: "I'm good, thanks!")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Great to hear!")

    try? context.save()

    return NavigationStack {
        ChatView(chat: chat, context: context)
            .environment(\.managedObjectContext, context)
    }
}

