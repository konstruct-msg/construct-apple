//
//  ChatView+Bar.swift
//  Construct Messenger
//
//  The conversation bar: toolbar, title and header actions, split out of ChatView.swift.
//

// iOS only: the Desktop target excludes ChatView.swift / AccountSettingsView.swift.
#if os(iOS)
import SwiftUI
import CoreData
import UniformTypeIdentifiers

extension ChatView {
    // MARK: - Bar

    /// The conversation on the system bar (`decisions/navigation-bars-are-the-systems.md`): the
    /// system back, the person's name as the title, the actions in one menu.
    @ToolbarContentBuilder
    var chatToolbar: some ToolbarContent {
        // The title is a button: a tap on the name opens the person (owner, 2026-10-08). The one
        // bar of ours whose title is a view, so it sets the bar's title face itself.
        ToolbarItem(placement: .principal) {
            Button { showingUserProfile = true } label: {
                ObservedPeerName(userId: peerId) { chatTitle($0) }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Chat.title)
            .accessibilityHint(Text(LocalizedStringKey("profile")))
        }

        if contactTrustAlert != nil {
            ToolbarItem(placement: .primaryAction) {
                Button { showingSafetyNumbers = true } label: {
                    Label(NSLocalizedString("kt_warning", comment: ""), systemImage: "exclamationmark.shield.fill")
                }
                .tint(Color.CT.danger)
                .accessibilityHint(Text(LocalizedStringKey("key_change_verify")))
            }
        }

        if isEditMode {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(title: NSLocalizedString("done", comment: "")) {
                    withAnimation {
                        isEditMode = false
                        selectedMessages.removeAll()
                    }
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                chatActionsItem.barItem()
            }
        }
    }

    /// Search, call, video call — one menu. With a single action (no callable contact) it is
    /// that action's own button: a menu of one is a detour.
    @ViewBuilder
    private var chatActionsItem: some View {
        let actions = headerActions
        if actions.count == 1, let only = actions.first {
            Button { performHeaderAction(only) } label: { chatActionLabel(only) }
        } else {
            Menu {
                ForEach(actions, id: \.self) { action in
                    Button { performHeaderAction(action) } label: { chatActionLabel(action) }
                }
            } label: {
                Label(NSLocalizedString("chat_actions", comment: ""), systemImage: "ellipsis.circle")
            }
        }
    }

    private func chatActionLabel(_ action: ChatAction) -> some View {
        Label(NSLocalizedString(action.labelKey, comment: ""), systemImage: action.symbol)
    }

    /// Name, then the session or connection state under it — the bar's title and subtitle, drawn
    /// in the faces the app-wide bar appearance gives a plain title.
    private func chatTitle(_ name: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: CTLayout.inlinePad / 2) {
                Text(name)
                    .typesetting(asScriptOf: name)
                    .font(CTFont.ui(17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                if contactTrustAlert == nil, contactKTStatus == .verified {
                    Image(systemName: "checkmark.circle.fill")
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.accent)
                        .accessibilityLabel(Text(LocalizedStringKey("kt_verified")))
                }
            }
            if let subtitle = navigationStatusSubtitle {
                Text(subtitle)
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.textDim)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
    }

    /// Load KT status for the contact — as saved, since this runs on the notification a write
    /// posts.
    func loadContactKTStatus() {
        if let contact = try? LocalRepositories.contacts.contact(peerId) {
            contactKTStatus = contact.ktStatus
            contactTrustAlert = contact.trustAlert
        }
    }
}
#endif
