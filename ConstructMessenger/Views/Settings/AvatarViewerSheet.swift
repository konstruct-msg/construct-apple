//
//  AvatarViewerSheet.swift
//  Construct Messenger
//
//  The full-size avatar viewer, split out of AccountSettingsView.swift.
//

// iOS only: the Desktop target excludes ChatView.swift / AccountSettingsView.swift.
#if os(iOS)
import SwiftUI

// MARK: - Avatar Viewer Sheet
struct AvatarViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage?
    let onChangeAvatar: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                        .foregroundColor(Color.CT.onMedia)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("change_avatar") { onChangeAvatar() }
                        .foregroundColor(Color.CT.onMedia)
                }
            }
            .navBarChrome(.black)
        }
    }
}
#endif
