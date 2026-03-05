//
//  DraftsView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 09.02.2026.
//

import SwiftUI

struct DraftsView: View {
    @State private var draftText: String = ""
    @State private var drafts: [DraftItem] = []

    private let storageKey = "local_drafts"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    TextEditor(text: $draftText)
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(8)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)

                    Button {
                        addDraft()
                    } label: {
                        Label("Save Draft", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if drafts.isEmpty {
                    Spacer()
                    Text("Drafts are stored locally on this device.")
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
            .navigationTitle("Drafts")
            .onAppear {
                loadDrafts()
            }
        }
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
