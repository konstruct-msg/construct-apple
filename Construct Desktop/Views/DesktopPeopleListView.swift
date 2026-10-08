//
//  DesktopPeopleListView.swift
//  Construct Desktop
//
//  macOS sidebar people list.
//

import SwiftUI
import CoreData

struct DesktopPeopleListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(ChatsViewModel.self) private var chatsViewModel

    /// People marked as contacts, in the order shown (`ContactsLive.contacts`).
    private var contacts: [ContactRecord] { ContactsLive.shared.contacts() }

    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            peopleList
        }
        .ctBackground()
        .onAppear {
            chatsViewModel.setContext(viewContext)
        }
    }

    private var searchBar: some View {
        CTSearchBar(text: $searchQuery, focused: $searchFocused)
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, 7)
            .background(Color.CT.bg)
            .ctBorderBottom()
    }

    private var filteredContacts: [ContactRecord] {
        guard !searchQuery.isEmpty else { return contacts }
        let q = searchQuery.lowercased()
        return contacts.filter { user in
            user.resolvedDisplayName.lowercased().contains(q)
                || user.username.lowercased().contains(q)
                || user.id.lowercased().contains(q)
        }
    }

    @ViewBuilder
    private var peopleList: some View {
        if filteredContacts.isEmpty {
            emptyState
        } else {
            List {
                ForEach(filteredContacts) { user in
                    Button {
                        chatsViewModel.openOrCreateChat(withContact: user.id)
                    } label: {
                        DesktopPeopleRow(user: user)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.CT.bg)
                    .listRowSeparatorTint(Color.CT.noise)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.CT.bg)
        }
    }

    private var emptyState: some View {
        VStack(spacing: CTLayout.sectionGap) {
            Image(systemName: "person.2")
                .font(CTFont.ui(30, weight: .light))
                .foregroundStyle(Color.CT.textDim)

            Text(LocalizedStringKey("synapses_empty_title"))
                .font(CTFont.ui(15, weight: .bold))
                .foregroundStyle(Color.CT.text)
                .multilineTextAlignment(.center)

            Text(LocalizedStringKey("synapses_empty_subtitle"))
                .font(CTFont.secondary)
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CTLayout.sectionGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, CTLayout.edgePad)
    }
}

private struct DesktopPeopleRow: View {
    let user: ContactRecord

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: CTLayout.inlinePad) {
                    Text(user.resolvedDisplayName)
                        .font(CTFont.bodyEmphasis)
                        .foregroundStyle(Color.CT.text)
                        .lineLimit(1)

                    if user.trustAlert != nil {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(CTFont.ui(11, weight: .semibold))
                            .foregroundStyle(Color.CT.danger)
                            .accessibilityLabel(Text(LocalizedStringKey("kt_warning")))
                    }

                    Spacer(minLength: 0)
                }

                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, CTLayout.inlinePad)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatarView: some View {
        let seed = user.id
        let initials = initials(for: user)
        if let data = user.avatar,
           let platformImg = ImageHelper.imageFromData(data) {
            CTHexAvatar(initials: initials, image: Image(platformImage: platformImg), size: .medium, colorSeed: seed)
        } else {
            CTHexAvatar(initials: initials, size: .medium, colorSeed: seed)
        }
    }

    private func initials(for user: ContactRecord) -> String {
        let parts = user.resolvedDisplayName.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(user.resolvedDisplayName.prefix(2)).uppercased()
    }
}

// DEBUG only: the previews seed `ContactsLive.useForPreview`, which a release build does not have.
#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    ContactsLive.useForPreview(container)
    let context = container.viewContext
    _ = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    _ = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    try? context.save()
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)
    return DesktopPeopleListView()
        .environment(\.managedObjectContext, context)
        .environment(chatsViewModel)
        .frame(width: 280, height: 600)
}
#endif
