//
//  ChatAuxiliaryViews.swift
//  Construct Messenger
//
//  Drop overlay, multi-select bar, and in-chat search chrome.
//

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
                        .padding(CTLayout.sectionGap)
                        .background(Color.CT.bgMsg)
                        .clipShape(CTShape.card())
                        .overlay(CTShape.card().stroke(Color.CT.accent.opacity(0.4), lineWidth: 1))
                )
                .allowsHitTesting(false)
                .padding(CTLayout.inlinePad)
        }
    }
}

struct ChatSelectionBarView: View {
    let selectedCount: Int
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            Button(role: .destructive, action: onDelete) {
                Text(NSLocalizedString("delete_selected", comment: "").uppercased())
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.danger)
                    .frame(minHeight: CTLayout.hitTarget)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(
                "\(selectedCount) \(NSLocalizedString(selectedCount == 1 ? "message_selected" : "messages_selected", comment: ""))"
            )
            .font(CTFont.regular(12))
            .foregroundStyle(Color.CT.textDim)
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(minHeight: CTLayout.controlHeight)
        .background(Color.CT.bgMsg)
        .clipShape(CTShape.card())
        .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 0.5))
        .padding(.horizontal, ChatUIConstants.Shell.auxOuterPad)
    }
}

struct ChatSearchOverlayView: View {
    @Binding var isSearchActive: Bool
    @Binding var searchText: String
    let resultCount: Int

    var body: some View {
        if isSearchActive {
            VStack(spacing: CTLayout.inlinePad) {
                HStack(alignment: .center, spacing: CTLayout.chromeGap) {
                    CTSearchBar(
                        text: $searchText,
                        placeholder: LocalizedStringKey("search_messages")
                    )

                    Button {
                        withAnimation {
                            isSearchActive = false
                            searchText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: CTLayout.navIconSize, weight: .regular))
                            .foregroundStyle(Color.CT.accentDim)
                            .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("close", comment: ""))
                }
                .padding(.horizontal, CTLayout.edgePad)

                if !searchText.isEmpty {
                    HStack {
                        Text(
                            String(
                                format: NSLocalizedString("chat_search_results", comment: ""),
                                resultCount
                            )
                        )
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.textDim)
                        Spacer()
                    }
                    .padding(.horizontal, CTLayout.edgePad + 4)
                }
            }
            // Sit below the floating glass chat nav (navBarHeight + top padding).
            .padding(.top, CTLayout.navBarHeight + CTLayout.chromeGap + 4)
            .padding(.bottom, CTLayout.inlinePad)
            .background(
                Color.CT.bg.opacity(0.92)
                    .background(.ultraThinMaterial)
            )
        }
    }
}
