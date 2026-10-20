//
//  ChatView+ReplyFocus.swift
//  Construct Messenger
//
//  Soft reply focus (dim non-related bubbles), split out of ChatView.swift.
//

// iOS only: the Desktop target excludes ChatView.swift / AccountSettingsView.swift.
#if os(iOS)
import SwiftUI
import CoreData
import UniformTypeIdentifiers

extension ChatView {
    // MARK: - Soft reply focus (dim non-related bubbles)

    func replyFocusOpacity(for messageId: String) -> Double {
        guard !isEditMode, !replyFocusIds.isEmpty else {
            return ChatUIConstants.ReplyFocus.focusedOpacity
        }
        let id = messageId.lowercased()
        if replyFocusIds.contains(id) {
            return ChatUIConstants.ReplyFocus.focusedOpacity
        }
        return ChatUIConstants.ReplyFocus.dimmedOpacity
    }

    /// Compose-reply focus: keep the quoted parent bright while the reply bar is up.
    func setComposeReplyFocus(messageId: String) {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        // Do not wrap in withAnimation — each bubble already has
        // `.animation(..., value: replyFocusIds)`. A second transaction here
        // animated the whole LazyVStack with composer inset change → flash.
        replyFocusIds = [messageId.lowercased()]
    }

    /// Take the reader to one message, if the transcript is showing it.
    ///
    /// Every guest scroll goes through here, for two reasons the call sites cannot handle
    /// individually.
    ///
    /// **The id is resolved against the rendered list, and the rendered one is what travels on.**
    /// `peekReplyChain` lowercases both ids before it asks, `Message.id` is not lowercase, and the
    /// row that installs the target's reporter matches on `message.id` — so an unresolved id asks
    /// for a row that, to every comparison downstream, does not exist. One normalisation, at the
    /// boundary, rather than a `.lowercased()` at each of the places that compare.
    ///
    /// **A message outside the loaded window is refused here.** The destination is measured by a
    /// reporter installed on the target row, so a message the transcript has not rendered has
    /// nowhere to put one, and the request would sit unfulfilled forever. Saying so is the point: a
    /// jump that silently does nothing is the defect this whole change closes, and replacing it
    /// with a differently-shaped silence would be no better.
    func jumpToMessage(_ messageId: String, anchor: UnitPoint = .center) {
        guard let rendered = filteredMessages.first(
            where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }
        ) else {
            Log.info(
                "SCROLL_GUEST[not_rendered]: \(messageId.prefix(8))… is not in the loaded transcript — no jump",
                category: "ChatView"
            )
            return
        }
        viewport.scrollTo(messageId: rendered.id, anchor: anchor, animated: true)
    }

    /// Tap on in-bubble reply strip: scroll to parent, keep parent + child bright briefly.
    func peekReplyChain(for message: TranscriptRow) {
        let childId = message.id.lowercased()
        let parentId = (message.replyToMessageId ?? "").lowercased()
        guard !parentId.isEmpty else { return }

        replyFocusPeekTask?.cancel()
        withAnimation(.easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration)) {
            replyFocusIds = [parentId, childId]
        }
        // Prefer scrolling to the parent (what the user is looking for).
        jumpToMessage(parentId)

        // Hold while composing a reply to this parent; otherwise auto-clear.
        let holdParent = parentId
        replyFocusPeekTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ChatUIConstants.ReplyFocus.peekHoldNanoseconds)
            guard !Task.isCancelled else { return }
            if replyingTo?.id.lowercased() == holdParent {
                // Compose focus owns the set now.
                return
            }
            clearReplyFocus(animated: true)
        }
    }

    func clearReplyFocus(animated: Bool) {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        guard !replyFocusIds.isEmpty else { return }
        if animated {
            withAnimation(.easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration)) {
                replyFocusIds = []
            }
        } else {
            replyFocusIds = []
        }
    }
}
#endif
