//
//  DraftsView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 09.02.2026.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DraftsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftText: String = ""
    @State private var drafts: [DraftItem] = []

    private let storageKey = "local_drafts"

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("drafts", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    TextEditor(text: $draftText)
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(8)
                        .background(Color.CT.bgMsg)
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.text)
                        .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))

                    Button {
                        addDraft()
                    } label: {
                        Text(LocalizedStringKey("save_draft"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.CT.bgMsg)
                            .overlay(Rectangle().stroke(Color.CT.accent, lineWidth: 1))
                    }
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if drafts.isEmpty {
                    Spacer()
                    Text(LocalizedStringKey("drafts_stored_locally"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(draft.text)
                                    .font(.body)
                                    .lineLimit(3)
                                Text(draft.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .onDelete(perform: deleteDrafts)
                    }
                    .listStyle(.plain)
                }
            }
            .padding()
            .onAppear {
                loadDrafts()
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    private func addDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let draft = DraftItem(id: UUID(), text: trimmed, createdAt: Date())
        drafts.insert(draft, at: 0)
        draftText = ""
        saveDrafts()
    }

    private func deleteDrafts(at offsets: IndexSet) {
        drafts.remove(atOffsets: offsets)
        saveDrafts()
    }

    private func loadDrafts() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([DraftItem].self, from: data) {
            drafts = decoded
        }
    }

    private func saveDrafts() {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private struct DraftItem: Identifiable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
}
