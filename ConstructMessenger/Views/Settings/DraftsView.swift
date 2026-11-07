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
    @State private var draftText: String = ""
    @State private var drafts: [NoteItem] = []
    @State private var hasLoadedDrafts = false

    private var trimmedDraftText: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSaveDraft: Bool {
        !trimmedDraftText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    TextEditor(text: $draftText)
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(8)
                        .background(Color.CT.bgMsg)
                        .font(CTFont.body)
                        .foregroundColor(Color.CT.text)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .clipShape(CTShape.card())
                        .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 1))

                    CTButton(
                        label: NSLocalizedString("save_draft", comment: ""),
                        role: .secondary,
                        isEnabled: canSaveDraft
                    ) {
                        addDraft()
                    }
                }

                if drafts.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(LocalizedStringKey("drafts_empty_title"))
                                .font(CTFont.headline)
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    } description: {
                        Text(LocalizedStringKey("drafts_stored_locally"))
                            .font(CTFont.body)
                    }
                } else {
                    List {
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(draft.text)
                                    .font(CTFont.message(15))
                                    .lineLimit(3)
                                Text(draft.createdAt, style: .date)
                                    .font(CTFont.secondary)
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
                guard !hasLoadedDrafts else { return }
                loadDrafts()
                hasLoadedDrafts = true
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .screenTitle(NSLocalizedString("drafts", comment: ""))
    }

    private func addDraft() {
        guard canSaveDraft else { return }
        // The text stays in the editor when the store refuses it: nothing typed is lost.
        do {
            drafts = try NotesStore.add(trimmedDraftText)
            draftText = ""
        } catch {
            Log.error("Drafts: could not save — \(error)", category: "Storage")
        }
    }

    private func deleteDrafts(at offsets: IndexSet) {
        do {
            drafts = try NotesStore.delete(Set(offsets.map { drafts[$0].id }))
        } catch {
            Log.error("Drafts: could not delete — \(error)", category: "Storage")
        }
    }

    private func loadDrafts() {
        do {
            drafts = try NotesStore.all()
        } catch {
            Log.error("Drafts: could not read — \(error)", category: "Storage")
        }
    }
}
