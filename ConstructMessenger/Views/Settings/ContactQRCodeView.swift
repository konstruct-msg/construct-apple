//
//  ContactQRCodeView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ContactQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let userId: String
    let username: String

    private var contactLink: String {
        let link = generateContactLink(userId: userId, username: username)
        print("🔗 ContactQRCodeView: Generated link: \(link)")
        return link
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 24) {
                    Text("my_qr_code")
                        .font(.title2)
                        .fontWeight(.semibold)

                    // QR Code
                    if let qrImage = generateQRCode(from: contactLink) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 250, height: 250)
                            .padding()
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 250)
                            .cornerRadius(16)
                            .overlay {
                                Text("failed_to_generate_qr_code")
                                    .foregroundColor(.secondary)
                            }
                    }

                    VStack(spacing: 8) {
                        Text("@\(username)")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("show_this_code_to_someone_nearby")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                Spacer()

                // Hint text
                Text("scan_with_camera_or_screenshot")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - QR Code Generation
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        if let outputImage = filter.outputImage {
            // Scale up the QR code
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }
    
    private func generateContactLink(userId: String, username: String) -> String {
        let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username

        let httpsLink = "https://konstruct.cc/add?id=\(userId)&username=\(encodedUsername)"

        return httpsLink
    }
}

#Preview {
    ContactQRCodeView(
        userId: "user123",
        username: "john_doe"
    )
}
