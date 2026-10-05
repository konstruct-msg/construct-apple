//
//  ChatActionPalette.swift
//  Construct Messenger
//
//  The chat header's actions — search, call, video call — behind one button, so the header keeps
//  its quiet on a small screen. Owner, 2026-10-05.
//
//  Two ways in, one palette. A tap opens it with every action named, to be tapped: that is how the
//  actions are found. A hold opens it under the finger, which slides toward an action and lets go:
//  that is how a hand that knows them works without looking (a marking menu). Each action keeps
//  one direction — search to the left, call on the diagonal, video straight down — so the hand
//  can learn it.
//
//  The thumb covers what it reaches for. So the actions sit well apart on an arc around the
//  button, and the one under the finger is also named away from the hand, as the keyboard shows
//  the key under a finger above it.
//

import SwiftUI

enum ChatAction: CaseIterable, Hashable {
    case search, call, videoCall

    /// The direction from the button, in screen coordinates (y grows downwards). Fixed per action,
    /// never re-laid out by which actions are present.
    var direction: CGVector {
        switch self {
        case .search: return CGVector(dx: -1, dy: 0)
        case .call: return CGVector(dx: -0.7071, dy: 0.7071)
        case .videoCall: return CGVector(dx: 0, dy: 1)
        }
    }

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .call: return "phone.fill"
        case .videoCall: return "video.fill"
        }
    }

    var labelKey: String {
        switch self {
        case .search: return "chat_action_search"
        case .call: return "chat_action_call"
        case .videoCall: return "chat_action_video"
        }
    }

    /// The actions the header offers. Search always; calls with a callable contact; video only
    /// with video calls on.
    static func available(canCall: Bool, videoEnabled: Bool) -> [ChatAction] {
        var actions: [ChatAction] = [.search]
        if canCall {
            actions.append(.call)
            if videoEnabled { actions.append(.videoCall) }
        }
        return actions
    }
}

/// The palette while it is open.
enum ChatActionPaletteState: Equatable {
    /// Opened by a tap: it stays, every action is a button, a tap elsewhere closes it.
    case tapped
    /// Opened by a hold: it follows the finger; `selected` is the action under it, if any.
    case held(selected: ChatAction?)
}

enum ChatActionPaletteGeometry {
    /// Far enough that the thumb on the button does not cover the action it slides to, and that
    /// neighbours 45° apart leave more than half a fingertip between them (84 pt centre to centre
    /// for 52 pt items). 96 left 21 pt, under half of `CTLayout.hitTarget`.
    static let radius: CGFloat = 110
    static let itemSize: CGFloat = 52
    /// A finger that has barely moved has chosen nothing yet.
    static let deadZone: CGFloat = 28
    /// A finger this far past the arc has given up; letting go there starts nothing.
    static let cancelBeyond: CGFloat = 64
    /// Half the angle between neighbours: closer than this to an action's direction picks it. Not
    /// wider: at 45° "down" without video calls on would pick the call, and a direction must mean
    /// one action whatever else is offered.
    static let sectorHalfAngle: Double = 22.5

    /// Where the chosen action is named: below the header on the left, clear of the arc and of a
    /// right thumb coming up from the bottom corner. Not the middle of the header — search sits
    /// there, to the left of the button, and the name covered it.
    static func calloutPosition(buttonCenter: CGPoint, containerWidth: CGFloat) -> CGPoint {
        CGPoint(x: containerWidth * 0.3, y: buttonCenter.y + radius)
    }

    static func offset(of action: ChatAction) -> CGSize {
        CGSize(width: action.direction.dx * radius, height: action.direction.dy * radius)
    }

    /// The action a finger at `offset` from the button's centre chooses, or nil.
    static func action(at offset: CGSize, among actions: [ChatAction]) -> ChatAction? {
        let distance = hypot(offset.width, offset.height)
        guard distance >= deadZone, distance <= radius + cancelBeyond else { return nil }
        let angle = atan2(Double(offset.height), Double(offset.width))
        let nearest = actions.min { a, b in
            angularDistance(angle, of: a) < angularDistance(angle, of: b)
        }
        guard let nearest, angularDistance(angle, of: nearest) <= sectorHalfAngle * .pi / 180 else { return nil }
        return nearest
    }

    private static func angularDistance(_ angle: Double, of action: ChatAction) -> Double {
        let target = atan2(Double(action.direction.dy), Double(action.direction.dx))
        let d = abs(angle - target).truncatingRemainder(dividingBy: 2 * .pi)
        return min(d, 2 * .pi - d)
    }
}

// MARK: - The button

/// The header's action button: vertical dots on the place the magnifier had. With a single action
/// (no callable contact) it is that action's own button — a palette of one is a detour.
struct ChatActionButton: View {
    let actions: [ChatAction]
    @Binding var palette: ChatActionPaletteState?
    let onAction: (ChatAction) -> Void

    @State private var pressTask: Task<Void, Never>?
    @State private var pressStartedOpen = false

    private let size = CTLayout.hitTarget

    var body: some View {
        if actions.count == 1, let only = actions.first {
            Button { onAction(only) } label: { glyph(only.symbol) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(only.labelKey)))
        } else {
            glyph("ellipsis.circle")
                .rotationEffect(.degrees(90))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { pressChanged(at: $0.location) }
                        .onEnded { pressEnded(at: $0.location) }
                )
                .sensoryFeedback(.impact(weight: .light), trigger: palette != nil) { _, isOpen in isOpen }
                .sensoryFeedback(.selection, trigger: heldSelection) { old, new in old != new && new != nil }
                .accessibilityElement()
                .accessibilityLabel(Text(LocalizedStringKey("chat_actions")))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { palette = palette == nil ? .tapped : nil }
                .modifier(PaletteAccessibilityActions(actions: actions, onAction: onAction))
        }
    }

    private var heldSelection: ChatAction? {
        if case .held(let selected) = palette { return selected }
        return nil
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: CTLayout.navIconSizeLg, weight: .medium))
            .foregroundColor(Color.CT.accent)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }

    private func offset(of point: CGPoint) -> CGSize {
        CGSize(width: point.x - size / 2, height: point.y - size / 2)
    }

    private func pressChanged(at point: CGPoint) {
        if case .held = palette {
            palette = .held(selected: ChatActionPaletteGeometry.action(at: offset(of: point), among: actions))
        } else if pressTask == nil, !pressStartedOpen {
            pressStartedOpen = palette != nil
            guard !pressStartedOpen else { return }
            pressTask = Task { @MainActor in
                try? await Task.sleep(for: ChatUIConstants.HoldSwitch.pressDelay)
                guard !Task.isCancelled else { return }
                palette = .held(selected: nil)
            }
        }
    }

    private func pressEnded(at point: CGPoint) {
        pressTask?.cancel()
        pressTask = nil
        defer { pressStartedOpen = false }
        switch palette {
        case .held(let selected):
            palette = nil
            if let selected { onAction(selected) }
        case .tapped:
            // A tap on the open palette's own button closes it.
            if pressStartedOpen { palette = nil }
        case nil:
            palette = .tapped
        }
    }
}

/// VoiceOver cannot hold and slide; every action is a named action on the button.
private struct PaletteAccessibilityActions: ViewModifier {
    let actions: [ChatAction]
    let onAction: (ChatAction) -> Void

    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { view, action in
            AnyView(view.accessibilityAction(named: Text(LocalizedStringKey(action.labelKey))) { onAction(action) })
        }
    }
}

/// Where the button is, for the palette drawn over the whole chat.
struct ChatActionButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - The palette

/// Drawn by the chat over everything, centred on the button. Held, it is only a picture — the
/// finger's drag belongs to the button. Tapped, its actions are buttons and the dimmed rest of the
/// screen closes it.
struct ChatActionPaletteView: View {
    let state: ChatActionPaletteState
    let actions: [ChatAction]
    /// The button's centre in this view's coordinates.
    let center: CGPoint
    /// Where the chosen action is named (`ChatActionPaletteGeometry.calloutPosition`).
    let callout: CGPoint
    let onAction: (ChatAction) -> Void
    let onDismiss: () -> Void

    private var selected: ChatAction? {
        if case .held(let selected) = state { return selected }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(NSLocalizedString("close", comment: ""))

            ForEach(actions, id: \.self) { action in
                item(action)
                    .position(
                        x: center.x + ChatActionPaletteGeometry.offset(of: action).width,
                        y: center.y + ChatActionPaletteGeometry.offset(of: action).height
                    )
            }

            if let selected {
                Text(LocalizedStringKey(selected.labelKey))
                    .font(CTFont.headline)
                    .foregroundStyle(Color.CT.text)
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.vertical, CTLayout.inlinePad)
                    .glassCapsule()
                    .position(callout)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(state == .tapped)
        .animation(.spring(duration: 0.2), value: selected)
    }

    private func item(_ action: ChatAction) -> some View {
        let isSelected = selected == action
        return Button {
            onAction(action)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.symbol)
                    .font(.system(size: CTLayout.navIconSize, weight: .medium))
                    .foregroundStyle(isSelected ? Color.CT.bg : Color.CT.accent)
                    .frame(width: ChatActionPaletteGeometry.itemSize, height: ChatActionPaletteGeometry.itemSize)
                    .background(isSelected ? AnyShapeStyle(Color.CT.accent) : AnyShapeStyle(.regularMaterial), in: Circle())
                Text(LocalizedStringKey(action.labelKey))
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.text)
                    .fixedSize()
            }
            .scaleEffect(isSelected ? 1.15 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(action.labelKey)))
    }
}
