//
//  SynapsView.swift
//  Construct Messenger
//
//  Synaps — persistent contact network, independent of chats.
//  Layout: Apple Watch-style honeycomb grid of round avatars.
//  Actions: tap → contact card overlay with all options inside.
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
    @State private var selectedContact: User? = nil
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
            ZStack {
                Color.Construct.bg.ignoresSafeArea()

                if contacts.isEmpty {
                    emptyState
                } else {
                    HoneycombGrid(contacts: filtered, selected: $selectedContact)
                        .padding(.top, 8)
                }

                // Contact card overlay
                if let user = selectedContact {
                    SynapsContactCard(
                        user: user,
                        onOpenChat: {
                            chatsViewModel.openOrCreateChat(with: user)
                            selectedContact = nil
                        },
                        onPrune: {
                            pruneTarget = user
                            showPruneConfirm = true
                            selectedContact = nil
                        },
                        onDismiss: { selectedContact = nil }
                    )
                    .environment(\.managedObjectContext, context)
                    .zIndex(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .searchable(text: $searchText, prompt: LocalizedStringKey("synaps_search_prompt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.Construct.bg2, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SYNAPSES")
                        .font(ConstructFont.mono(13, weight: .semibold))
                        .foregroundStyle(Color.Construct.textBright)
                        .tracking(3)
                }
            }
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.Construct.textDim)
            Text(LocalizedStringKey("synaps_empty_title"))
                .font(ConstructFont.display(17, weight: .semibold))
                .foregroundStyle(Color.Construct.textBright)
            Text(LocalizedStringKey("synaps_empty_subtitle"))
                .font(ConstructFont.display(14))
                .foregroundStyle(Color.Construct.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Honeycomb Grid

/// Hexagonal staggered grid — even rows 4 circles, odd rows 3 circles offset by half cell.
/// Vertical spacing uses hex packing: vStep = cellWidth × √3/2.
private struct HoneycombGrid: View {

    let contacts: [User]
    @Binding var selected: User?

    private let wideCols = 4

    var body: some View {
        GeometryReader { geo in
            let cellW  = geo.size.width / CGFloat(wideCols)
            let size   = cellW * 0.74            // circle diameter
            let vStep  = cellW * 0.866           // √3/2 ≈ hex row height
            let rows   = buildRows(contacts)
            let totalH = CGFloat(rows.count) * vStep + cellW * 0.6

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: geo.size.width, height: totalH)

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                        let isOdd   = rowIdx % 2 == 1
                        let xShift  = isOdd ? cellW / 2 : 0

                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, user in
                            let cx = xShift + CGFloat(colIdx) * cellW + cellW / 2
                            let cy = CGFloat(rowIdx) * vStep + cellW / 2

                            ContactCircle(user: user, size: size) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                                    selected = user
                                }
                            }
                            .position(x: cx, y: cy)
                        }
                    }
                }
            }
        }
    }

    /// Split contacts into alternating rows of 4 (even) and 3 (odd).
    private func buildRows(_ items: [User]) -> [[User]] {
        var result: [[User]] = []
        var idx = 0, rowIdx = 0
        while idx < items.count {
            let n = rowIdx % 2 == 0 ? wideCols : wideCols - 1
            result.append(Array(items[idx ..< min(idx + n, items.count)]))
            idx += n
            rowIdx += 1
        }
        return result
    }
}

// MARK: - Contact Circle

private struct ContactCircle: View {

    @ObservedObject var user: User
    let size: CGFloat
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let data = user.avatarData, let img = PlatformImage(data: data) {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(accentColor.opacity(0.18))
                    Text(initials)
                        .font(ConstructFont.mono(size * 0.26, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(
                    user.isBlocked ? Color.red.opacity(0.55) : Color.Construct.dim,
                    lineWidth: 1.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var accentColor: Color { .hexagonAccent(for: user.id) }

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
}

// MARK: - Contact Card Overlay

/// Full-screen dimmed overlay with a centered contact card.
/// All contact actions live here — nothing outside the card.
private struct SynapsContactCard: View {

    @ObservedObject var user: User
    @Environment(\.managedObjectContext) private var context
    var onOpenChat: () -> Void
    var onPrune: () -> Void
    var onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // ── Avatar ──
                avatarView
                    .padding(.bottom, 14)

                // ── Identity ──
                Text(user.displayName)
                    .font(ConstructFont.display(20, weight: .semibold))
                    .foregroundStyle(Color.Construct.textBright)

                if !user.username.isEmpty {
                    Text("@\(user.username)")
                        .font(ConstructFont.mono(12))
                        .foregroundStyle(Color.Construct.textDim)
                        .padding(.top, 3)
                }

                Rectangle()
                    .fill(Color.Construct.dim)
                    .frame(height: 1)
                    .padding(.vertical, 20)

                // ── Actions ──
                VStack(spacing: 9) {
                    actionRow(icon: "message.fill",  title: "Message",      role: .primary)   { onOpenChat() }
                    actionRow(icon: "phone.fill",    title: "Voice call",   role: .disabled)  {}
                    actionRow(
                        icon: user.isBlocked ? "checkmark.circle" : "slash.circle",
                        title: user.isBlocked ? "Unblock" : "Block",
                        role: .secondary
                    ) {
                        user.isBlocked.toggle()
                        try? context.save()
                        dismiss()
                    }
                    actionRow(icon: "scissors", title: "Remove contact", role: .destructive) { onPrune() }
                }

                // ── Dismiss hint ──
                Text("tap outside to close")
                    .font(ConstructFont.mono(10))
                    .foregroundStyle(Color.Construct.textDim.opacity(0.5))
                    .padding(.top, 18)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.Construct.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(Color.Construct.line, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 40)
            )
            .padding(.horizontal, 24)
            .scaleEffect(appeared ? 1.0 : 0.88)
            .opacity(appeared ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    // MARK: Avatar

    private var avatarView: some View {
        ZStack {
            if let data = user.avatarData, let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(accentColor.opacity(0.18))
                Text(initials)
                    .font(ConstructFont.mono(30, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
        }
        .frame(width: 90, height: 90)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(
                user.isBlocked ? Color.red.opacity(0.5) : Color.Construct.dim,
                lineWidth: 2
            )
        )
    }

    // MARK: Action button

    enum ActionRole { case primary, secondary, destructive, disabled }

    @ViewBuilder
    private func actionRow(icon: String, title: String, role: ActionRole, action: @escaping () -> Void) -> some View {
        Button {
            guard role != .disabled else { return }
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 18, alignment: .center)
                    .font(.system(size: 15))
                Text(title)
                    .font(ConstructFont.display(15))
                if role == .disabled {
                    Spacer()
                    Text("soon")
                        .font(ConstructFont.mono(10))
                        .foregroundStyle(Color.Construct.textDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.Construct.bg3)
                        )
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(rowFill(role))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(rowBorder(role), lineWidth: 1)
                    )
            )
            .foregroundStyle(rowForeground(role))
        }
        .buttonStyle(.plain)
        .disabled(role == .disabled)
    }

    private func rowFill(_ role: ActionRole) -> Color {
        switch role {
        case .primary:     return Color.Construct.accent.opacity(0.12)
        case .destructive: return Color.red.opacity(0.10)
        default:           return Color.Construct.bg3
        }
    }

    private func rowBorder(_ role: ActionRole) -> Color {
        switch role {
        case .primary:     return Color.Construct.accent.opacity(0.35)
        case .destructive: return Color.red.opacity(0.30)
        default:           return Color.Construct.line
        }
    }

    private func rowForeground(_ role: ActionRole) -> Color {
        switch role {
        case .primary:     return Color.Construct.accent
        case .destructive: return Color.red
        case .disabled:    return Color.Construct.textDim
        case .secondary:   return Color.Construct.text
        }
    }

    // MARK: Helpers

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss() }
    }

    private var accentColor: Color { .hexagonAccent(for: user.id) }

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
}

// MARK: - Preview

#Preview("Honeycomb") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    let users: [(String, String, String)] = [
        ("u1", "alice",   "Alice Wonderland"),
        ("u2", "bob",     "Bob Builder"),
        ("u3", "charlie", "Charlie Chaplin"),
        ("u4", "dave",    "Dave Villain"),
        ("u5", "eve",     "Eve Listener"),
        ("u6", "frank",   "Frank Ocean"),
        ("u7", "grace",   "Grace Hopper"),
        ("u8", "henry",   "Henry Ford"),
        ("u9", "iris",    "Iris Chang"),
        ("u10","james",   "James Webb"),
    ]
    for (id, username, name) in users {
        let user = PreviewHelpers.createSampleUser(context: context, id: id, username: username, displayName: name)
        user.isContact = true
        user.addedAt = Date()
    }
    let blocked = PreviewHelpers.createSampleUser(context: context, id: "u11", username: "blocked", displayName: "Blocked User")
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
