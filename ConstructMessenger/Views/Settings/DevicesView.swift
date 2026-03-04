//
//  DevicesView.swift
//  ConstructMessenger
//

import SwiftUI

struct DevicesView: View {

    @State private var showingLinkAlert = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UIDevice.current.name)
                            .font(.body)
                        Text("this_device")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                .padding(.vertical, 4)
            } header: {
                Text("linked_devices")
            }

            Section {
                Button {
                    showingLinkAlert = true
                } label: {
                    Label("link_new_device", systemImage: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
            } footer: {
                Text("linked_devices_hint")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("linked_devices")
        .alert("link_new_device", isPresented: $showingLinkAlert) {
            Button("ok", role: .cancel) { }
        } message: {
            Text("linked_devices_coming_soon")
        }
    }
}
