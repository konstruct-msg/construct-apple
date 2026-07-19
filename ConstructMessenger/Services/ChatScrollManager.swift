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

    /// Distance from the bottom of the content in points (≈ 0 at bottom; large positive = scrolled up).
    /// Not observed — reading/writing must not invalidate the view every frame.
    @ObservationIgnored
    private(set) var distanceFromBottom: CGFloat = 0

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
        /// Within this many points of the bottom → auto-scroll stays on; FAB hidden.
        static let nearBottom: CGFloat = 60
        /// Need at least this much content below the viewport to show the jump FAB.
        static let showJumpButton: CGFloat = 200
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
        shouldScrollToBottom = true
        // Programmatic jump always clears the FAB — don't wait for the next geometry tick.
        if shouldShowScrollToBottomButton {
            shouldShowScrollToBottomButton = false
        }
        // Corrective re-pins fire often (composer height, keyboard); keep the log
        // for intentional animated scrolls only to cut console noise.
        if animated {
            Log.debug("Scrolled to bottom (messageId: \(messageId), animated: true)", category: "ChatScrollManager")
        }
    }

    /// Multi-pass non-animated pin used when the composer inset / first layout is still
    /// settling. Stops early if the user scrolls away (`shouldScrollToBottom == false`).
    /// Default delays cover: immediate · after first inset · after load-more/FRC churn.
    func pinToBottomCorrective(
        delaysMs: [UInt64] = [0, 50, 160, 350],
        messageId: String = "bottom"
    ) {
        Task { @MainActor [weak self] in
            for (index, ms) in delaysMs.enumerated() {
                if ms > 0 {
                    try? await Task.sleep(for: .milliseconds(ms))
                }
                guard let self else { return }
                guard self.shouldScrollToBottom else { return }
                guard self.proxy != nil else { return }
                self.scrollToBottom(messageId: messageId, animated: false)
                // First tick is often a no-op if LazyVStack has not produced the anchor yet.
                if index == 0 {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard self.shouldScrollToBottom else { return }
                    self.scrollToBottom(messageId: messageId, animated: false)
                }
            }
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

    /// Update scroll metrics (from `onScrollGeometryChange`).
    ///
    /// - Parameter distanceFromBottom: points of content **below** the visible rect
    ///   (`contentSize.height - visibleRect.maxY`). ≈ 0 at bottom; large when scrolled up.
    ///   Prefer this over `contentOffset + containerHeight - contentSize` — that formula
    ///   ignores `contentInsets` from the composer `safeAreaInset`, so with keyboard/composer
    ///   open the chat looked "at bottom" while the metric stayed ≤ −200 and the FAB stuck on.
    /// - Parameter contentFits: content shorter than the viewport → nothing to jump to.
    ///
    /// Only mutates observed flags when crossing thresholds (not every pixel).
    func updateScrollOffset(distanceFromBottom distance: CGFloat, contentFits: Bool = false) {
        guard distance.isFinite else { return }

        distanceFromBottom = distance

        if contentFits {
            if shouldShowScrollToBottomButton {
                shouldShowScrollToBottomButton = false
            }
            if !shouldScrollToBottom {
                shouldScrollToBottom = true
            }
            return
        }

        let nearBottom = distance <= Threshold.nearBottom
        let farUp = distance >= Threshold.showJumpButton

        // Keyboard / composer-height animation produces transient distances.
        // Never latch the FAB ON while the keyboard is up; still allow hide + near-bottom.
        if isKeyboardVisible {
            if nearBottom {
                if !shouldScrollToBottom { shouldScrollToBottom = true }
                if shouldShowScrollToBottomButton { shouldShowScrollToBottomButton = false }
            }
            return
        }

        if nearBottom != shouldScrollToBottom {
            shouldScrollToBottom = nearBottom
        }

        if farUp != shouldShowScrollToBottomButton {
            shouldShowScrollToBottomButton = farUp
        }
    }

    /// Legacy alias — treats argument as **signed** bottom offset (0 at bottom, negative up).
    func updateScrollOffset(_ offset: CGFloat, contentFits: Bool = false) {
        // Convert old convention (negative = up) to distance-from-bottom (positive = up).
        updateScrollOffset(distanceFromBottom: -offset, contentFits: contentFits)
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
        distanceFromBottom = 0
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
                // Corrective pin only — animated scroll during keyboard animation
                // dematerializes LazyVStack (empty chat flash).
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self else { return }
                    // Don't keep a stuck FAB over the keyboard while the inset settles.
                    if self.shouldShowScrollToBottomButton {
                        self.shouldShowScrollToBottomButton = false
                    }
                    if self.shouldScrollToBottom {
                        self.scrollToBottom(animated: false)
                        try? await Task.sleep(for: .milliseconds(120))
                        if self.shouldScrollToBottom {
                            self.scrollToBottom(animated: false)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Observe keyboard will hide
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                self?.keyboardHeight = 0
                // After keyboard dismisses, re-enable auto-scroll and clear any FAB that
                // latched during the keyboard geometry thrash.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    self.shouldScrollToBottom = true
                    self.shouldShowScrollToBottomButton = false
                    self.scrollToBottom(animated: false)
                    try? await Task.sleep(for: .milliseconds(100))
                    if self.shouldScrollToBottom {
                        self.scrollToBottom(animated: false)
                    }
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
