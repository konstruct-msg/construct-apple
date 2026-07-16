//
//  ChatScrollManager.swift
//  Construct Messenger
//
//  Created by Copilot on 30.01.2026.
//  Refactored from ChatView to isolate scroll management complexity
//

import SwiftUI
import Combine
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Manages scroll state and behavior for ChatView
///
/// **Responsibilities:**
/// - Scroll position tracking
/// - Auto-scroll to bottom on new messages
/// - Keyboard appearance handling
/// - Scroll gesture state
///
/// **Benefits:**
/// - Reduces ChatView from 620 → 550 lines
/// - Isolates scroll complexity (was 6 @State variables)
/// - Easier to debug scroll issues
/// - Can be reused in other chat-like views
@MainActor
@Observable
class ChatScrollManager {
    // MARK: - Observed UI State
    // Only properties that should invalidate ChatView belong here.
    // High-frequency scroll position is @ObservationIgnored so
    // onScrollGeometryChange does not re-render the chat every frame
    // (that loop also produced "tried to update multiple times per frame").

    /// Whether the view should scroll to bottom on next layout
    var shouldScrollToBottom = true

    /// Whether the view has scrolled to bottom at least once
    var hasScrolledToBottom = false

    /// Keyboard height when visible
    var keyboardHeight: CGFloat = 0

    /// "Jump to bottom" FAB — only flips when crossing the threshold (not every pixel).
    var shouldShowScrollToBottomButton = false

    // MARK: - High-frequency / private state

    /// Current offset from bottom (≈ 0 at bottom; large negative = scrolled up).
    /// Not observed — reading/writing must not invalidate the view every frame.
    @ObservationIgnored
    private(set) var scrollOffset: CGFloat = 0

    /// Reference to ScrollViewProxy for programmatic scrolling
    @ObservationIgnored
    private var proxy: ScrollViewProxy?

    /// Drag offset for pull-to-refresh gestures
    @ObservationIgnored
    private(set) var dragOffset: CGFloat = 0

    /// Cancellables for keyboard notifications
    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Thresholds

    private enum Threshold {
        /// Near bottom → keep auto-scroll on for new messages.
        static let nearBottom: CGFloat = -60
        /// Far enough up to show the jump-to-bottom button.
        static let showJumpButton: CGFloat = -200
    }

    // MARK: - Initialization

    init() {
        setupKeyboardObservers()
    }

    // MARK: - Public Methods

    /// Register the ScrollViewProxy for programmatic scrolling
    /// - Parameter proxy: ScrollViewProxy from ScrollViewReader
    func registerProxy(_ proxy: ScrollViewProxy) {
        self.proxy = proxy
    }

    /// Scroll to bottom of chat
    /// - Parameters:
    ///   - messageId: Optional specific message ID to scroll to (defaults to "bottom")
    ///   - animated: Animate the scroll. Pass `false` for *corrective* re-pins
    ///     (composer-height changes, first appear). An animated scroll interpolates the
    ///     content offset while the `safeAreaInset` composer is *also* animating its height,
    ///     which can drive the offset outside the valid range and de-materialize the
    ///     `LazyVStack` — the "chat goes black / empty" flash. A non-animated `scrollTo`
    ///     lands a valid offset in a single layout pass and forces the visible cells to
    ///     re-materialize immediately.
    func scrollToBottom(messageId: String = "bottom", animated: Bool = true) {
        guard let proxy = proxy else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(messageId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(messageId, anchor: .bottom)
        }

        hasScrolledToBottom = true
        // Corrective re-pins fire often (composer height, keyboard); keep the log
        // for intentional animated scrolls only to cut console noise.
        if animated {
            Log.debug("Scrolled to bottom (messageId: \(messageId), animated: true)", category: "ChatScrollManager")
        }
    }

    /// Scroll to a specific message
    /// - Parameters:
    ///   - messageId: Message ID to scroll to
    ///   - anchor: Anchor position (default: .center)
    ///   - animated: Whether to animate the scroll (default: true)
    func scrollTo(messageId: String, anchor: UnitPoint = .center, animated: Bool = true) {
        guard let proxy = proxy else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(messageId, anchor: anchor)
            }
        } else {
            proxy.scrollTo(messageId, anchor: anchor)
        }

        Log.debug("Scrolled to message: \(messageId)", category: "ChatScrollManager")
    }

    /// Update scroll offset (called from onScrollGeometryChange).
    /// `offset` ≈ 0 when at the bottom; large negative means scrolled far up.
    /// Only mutates observed flags when crossing thresholds so the chat view
    /// does not re-render on every scroll pixel.
    /// `contentFits` — content is shorter than the viewport: there is nothing to jump to,
    /// so the FAB is force-hidden. This runs even while the keyboard is visible, because a
    /// spurious mid-animation offset can latch the button ON right before the keyboard gate
    /// freezes threshold updates (seen as a jump-FAB in a two-message chat).
    func updateScrollOffset(_ offset: CGFloat, contentFits: Bool = false) {
        guard offset.isFinite else { return }

        scrollOffset = offset

        if contentFits {
            if shouldShowScrollToBottomButton {
                shouldShowScrollToBottomButton = false
            }
            if !shouldScrollToBottom {
                shouldScrollToBottom = true
            }
            return
        }

        // Ignore threshold updates while keyboard is animating — container height
        // changes during animation produce spurious offset values.
        if isKeyboardVisible {
            return
        }

        let nearBottom = offset >= Threshold.nearBottom
        if nearBottom != shouldScrollToBottom {
            shouldScrollToBottom = nearBottom
        }

        let showButton = offset < Threshold.showJumpButton
        if showButton != shouldShowScrollToBottomButton {
            shouldShowScrollToBottomButton = showButton
        }
    }

    /// Update drag offset for pull-to-refresh
    /// - Parameter offset: Drag gesture offset
    func updateDragOffset(_ offset: CGFloat) {
        dragOffset = offset
    }

    /// Reset scroll state (e.g., when switching chats)
    func reset() {
        shouldScrollToBottom = true
        hasScrolledToBottom = false
        shouldShowScrollToBottomButton = false
        scrollOffset = 0
        dragOffset = 0
        proxy = nil

        Log.debug("ChatScrollManager reset", category: "ChatScrollManager")
    }

    // MARK: - Keyboard Handling

    private func setupKeyboardObservers() {
        #if canImport(UIKit)
        // Observe keyboard will show
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { notification in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
            .sink { [weak self] height in
                self?.keyboardHeight = height
                // Scroll to bottom when keyboard appears, but only if user was already near bottom.
                // The shouldScrollToBottom flag is managed by updateScrollOffset based on
                // actual scroll position before keyboard animation started.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self else { return }
                    if self.shouldScrollToBottom {
                        self.scrollToBottom()
                    }
                }
            }
            .store(in: &cancellables)

        // Observe keyboard will hide
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                self?.keyboardHeight = 0
                // After keyboard dismisses, re-enable auto-scroll since user
                // is likely back at the input area.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.shouldScrollToBottom = true
                    self?.scrollToBottom()
                }
            }
            .store(in: &cancellables)
        #endif
    }
}

// MARK: - Computed Properties

extension ChatScrollManager {
    /// Whether keyboard is currently visible
    var isKeyboardVisible: Bool {
        keyboardHeight > 0
    }
}
