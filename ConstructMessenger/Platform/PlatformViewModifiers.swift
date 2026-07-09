//
//  PlatformViewModifiers.swift
//  Construct Messenger
//
//  SwiftUI modifiers that paper over iOS/macOS API divergence so call sites
//  stay platform-agnostic instead of sprinkling `#if os` at every use.
//

import SwiftUI

extension View {
    /// Presents `content` as a full-screen cover on iOS, falling back to a sheet on
    /// macOS where `fullScreenCover` is unavailable.
    @ViewBuilder
    func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    /// `item:` variant of `platformFullScreenCover`.
    @ViewBuilder
    func platformFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        self.sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}
