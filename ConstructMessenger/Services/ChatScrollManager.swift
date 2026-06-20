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
    // MARK: - Published State
    
    /// Whether the view should scroll to bottom on next layout
    var shouldScrollToBottom = true
    
    /// Whether the view has scrolled to bottom at least once
    var hasScrolledToBottom = false
    
    /// Current vertical scroll offset
    var scrollOffset: CGFloat = 0
    
    /// Keyboard height when visible
    var keyboardHeight: CGFloat = 0
    
    // MARK: - Private State
    
    /// Reference to ScrollViewProxy for programmatic scrolling
    private var proxy: ScrollViewProxy?
    
    /// Drag offset for pull-to-refresh gestures
    private(set) var dragOffset: CGFloat = 0
    
    /// Cancellables for keyboard notifications
    private var cancellables = Set<AnyCancellable>()
    
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
    /// - Parameter messageId: Optional specific message ID to scroll to (defaults to "bottom")
    func scrollToBottom(messageId: String = "bottom") {
        guard let proxy = proxy else {
            return
        }
        
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo(messageId, anchor: .bottom)
        }
        
        hasScrolledToBottom = true
        Log.debug("Scrolled to bottom (messageId: \(messageId))", category: "ChatScrollManager")
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
    /// Automatically maintains `shouldScrollToBottom` so auto-scroll on new
    /// messages doesn't fight the user when they deliberately scroll up.
    func updateScrollOffset(_ offset: CGFloat) {
        // Ignore offset updates while keyboard is animating — container height
        // changes during animation produce spurious offset values.
        if isKeyboardVisible {
            scrollOffset = offset
            return
        }

        scrollOffset = offset

        if offset >= -60 {
            // User is at (or very near) the bottom — re-enable auto-scroll.
            shouldScrollToBottom = true
        } else if offset < -60 {
            // User has scrolled up — disable auto-scroll so new arrivals
            // don't yank them back down. Single threshold avoids the
            // -160…-60 gap where state would stay stale.
            shouldScrollToBottom = false
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
    
    /// Whether to show "scroll to bottom" button (scrolled far from newest messages)
    var shouldShowScrollToBottomButton: Bool {
        // offsetFromBottom ≈ 0 means at bottom; large negative = scrolled up
        return scrollOffset < -200
    }
}
