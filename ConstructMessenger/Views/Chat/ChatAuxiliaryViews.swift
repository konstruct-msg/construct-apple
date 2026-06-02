import SwiftUI

struct ChatDropOverlayView: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Rectangle()
                .strokeBorder(Color.CT.accent, lineWidth: 2)
                .background(Color.CT.accent.opacity(0.05))
                .overlay(
                    Text(LocalizedStringKey("drop_to_attach"))
                        .font(CTFont.regular(16))
                        .foregroundColor(Color.CT.accent)
                        .padding(16)
                        .background(Color.CT.bgMsg)
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 1))
                )
                .allowsHitTesting(false)
                .padding(8)
        }
    }
}

struct ChatSelectionBarView: View {
    let selectedCount: Int
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(role: .destructive, action: onDelete) {
                Text("[\(NSLocalizedString("delete_selected", comment: "")) →]")
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.danger)
            }
            Spacer()
            Text("\(selectedCount) \(selectedCount == 1 ? "message_selected" : "messages_selected")")
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.textDim)
        }
        .padding()
        .background(Color.CT.bg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.CT.accent.opacity(0.3)), alignment: .top)
    }
}

struct ChatSearchOverlayView: View {
    @Binding var isSearchActive: Bool
    @Binding var searchText: String
    let resultCount: Int

    var body: some View {
        if isSearchActive {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(">")
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.accent)

                    TextField("search_messages", text: $searchText)
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                        .tint(Color.CT.accent)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .submitLabel(.search)
                        #endif
                        .autocorrectionDisabled()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.CT.bgMsg)
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4)))

                    Button {
                        withAnimation {
                            isSearchActive = false
                            searchText = ""
                        }
                    } label: {
                        Text("[x]")
                            .font(CTFont.regular(14))
                            .foregroundStyle(Color.CT.accentDim)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.CT.bg)

                if !searchText.isEmpty {
                    HStack {
                        Text("[\(resultCount) results]")
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .background(Color.CT.bg)
                }

                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.CT.accent.opacity(0.3))

                Spacer()
            }
        }
    }
}
