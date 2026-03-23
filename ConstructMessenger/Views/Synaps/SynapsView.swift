//
//  SynapsView.swift
//  Construct Messenger
//
//  Synaps — the persistent contact list, independent of chats.
//  Contacts (synapses) survive chat deletion and can be pruned explicitly.
//

import SwiftUI
import CoreData

struct SynapsView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(ChatsViewModel.self) private var chatsViewModel

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \User.displayName, ascending: true)
        ],
        predicate: NSPredicate(format: "isContact == YES"),
        animation: .default
    )
    private var contacts: FetchedResults<User>

    @State private var searchText = ""
    @State private var pruneTarget: User? = nil
    @State private var showPruneConfirm = false

    private var filtered: [User] {
        guard !searchText.isEmpty else { return Array(contacts) }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if contacts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .searchable(text: $searchText, prompt: LocalizedStringKey("synaps_search_prompt"))
        }
        .confirmationDialog(
            LocalizedStringKey("synaps_prune_title"),
            isPresented: $showPruneConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("synaps_prune_action"), role: .destructive) {
                if let user = pruneTarget {
                    chatsViewModel.pruneContact(userId: user.id)
                }
                pruneTarget = nil
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) { pruneTarget = nil }
        } message: {
            if let name = pruneTarget?.displayName {
                Text(String(format: NSLocalizedString("synaps_prune_message", comment: ""), name))
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(filtered) { user in
                SynapsRow(user: user) {
                    openChat(with: user)
                } onPrune: {
                    pruneTarget = user
                    showPruneConfirm = true
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey("synaps_empty_title"))
                .font(.headline)
            Text(LocalizedStringKey("synaps_empty_subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func openChat(with user: User) {
        chatsViewModel.openOrCreateChat(with: user)
    }
}

// MARK: - SynapsRow

private struct SynapsRow: View {

    @ObservedObject var user: User
    var onOpenChat: () -> Void
    var onPrune: () -> Void

    @Environment(\.managedObjectContext) private var context
    @State private var showProfile = false

    private var hasActiveChat: Bool {
        (user.chats as? Set<Chat>)?.isEmpty == false
    }

    var body: some View {
        HStack(spacing: 12) {
            avatarView
            nameStack
            Spacer()
            statusIcons
        }
        .contentShape(Rectangle())
        .onTapGesture { showProfile = true }
        .sheet(isPresented: $showProfile) {
            UserProfileView(user: user, onOpenChat: onOpenChat)
                .environment(\.managedObjectContext, context)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onPrune()
            } label: {
                Label(LocalizedStringKey("synaps_prune_action"), systemImage: "scissors")
            }
        }
        .contextMenu {
            Button { onOpenChat() } label: {
                Label(LocalizedStringKey("synaps_open_chat"), systemImage: "message")
            }
            Button { shareProfile() } label: {
                Label(LocalizedStringKey("share_profile"), systemImage: "person.crop.circle.badge.plus")
            }
            Divider()
            Button { toggleBlock() } label: {
                Label(
                    LocalizedStringKey(user.isBlocked ? "unblock_user" : "block_user"),
                    systemImage: user.isBlocked ? "checkmark.circle" : "slash.circle"
                )
            }
            Button(role: .destructive) { onPrune() } label: {
                Label(LocalizedStringKey("synaps_prune_action"), systemImage: "scissors")
            }
        }
    }

    // MARK: Sub-views

    private var avatarView: some View {
        ZStack {
            if let data = user.avatarData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.hexagonAccent(for: user.id).opacity(0.15)
                Text(initials)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.hexagonAccent(for: user.id))
            }
        }
        .frame(width: AvatarStyle.chatSize, height: AvatarStyle.chatSize)
        .clipShape(AvatarStyle.avatarShape())
    }

    private var nameStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(user.displayName)
                .font(.body)
                .lineLimit(1)
            if !user.username.isEmpty {
                Text("@\(user.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var statusIcons: some View {
        if hasActiveChat {
            Image(systemName: "message.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if user.isBlocked {
            Image(systemName: "slash.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Helpers

    private var initials: String {
        let words = user.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        switch words.count {
        case 0: return "?"
        case 1: return String(words[0].prefix(2)).uppercased()
        default: return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
    }

    private func toggleBlock() {
        user.isBlocked.toggle()
        try? context.save()
    }

    private func shareProfile() {
        let vm = ProfileShareViewModel()
        vm.shareProfile(with: user.id) { _, _ in }
    }
}

// MARK: - Preview

#Preview("With contacts") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    let users: [(String, String, String)] = [
        ("u1", "alice",   "Alice Wonderland"),
        ("u2", "bob",     "Bob Builder"),
        ("u3", "charlie", "Charlie Chaplin"),
    ]
    for (id, username, name) in users {
        let user = PreviewHelpers.createSampleUser(context: context, id: id, username: username, displayName: name)
        user.isContact = true
        user.addedAt = Date()
        _ = PreviewHelpers.createSampleChat(context: context, with: user)
    }
    // One blocked contact without chat
    let blocked = PreviewHelpers.createSampleUser(context: context, id: "u4", username: "dave", displayName: "Dave Villain")
    blocked.isContact = true
    blocked.isBlocked = true
    blocked.addedAt = Date()

    try? context.save()

    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)

    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
}

#Preview("Empty") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let chatsVM = ChatsViewModel()
    chatsVM.setContext(context)

    return SynapsView()
        .environment(\.managedObjectContext, context)
        .environment(chatsVM)
}
