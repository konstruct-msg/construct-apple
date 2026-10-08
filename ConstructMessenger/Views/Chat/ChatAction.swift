//
//  ChatAction.swift
//  Construct Messenger
//
//  The chat header's actions — search, call, video call — behind one system menu on the bar, so
//  the header keeps its quiet on a small screen (owner, 2026-10-05; a menu since 2026-10-08,
//  `decisions/navigation-bars-are-the-systems.md`).
//

enum ChatAction: CaseIterable, Hashable {
    case search, call, videoCall

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .call: return "phone"
        case .videoCall: return "video"
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
