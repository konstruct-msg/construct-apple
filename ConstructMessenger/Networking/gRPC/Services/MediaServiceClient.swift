//
//  MediaServiceClient.swift
//  Construct Messenger
//
//  gRPC MediaService client — replaces MediaAPI for media upload/download
//

import Foundation
import UIKit
import CryptoKit
import GRPCCore
import GRPCNIOTransportHTTP2

@available(iOS 18.0, *)
final class MediaServiceClient: Sendable {
    static let shared = MediaServiceClient()

    private init() {}

    // MARK: - Generate Upload Token (replaces MediaAPI.requestMediaToken)

    func generateUploadToken(expectedSize: Int64 = 0, contentType: String = "application/octet-stream") async throws -> MediaTokenData {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_MediaService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_GenerateUploadTokenRequest()
            request.expectedSize = expectedSize
            request.contentType = contentType

            let response = try await client.generateUploadToken(
                request: .init(message: request)
            )

            return MediaTokenData(
                requestId: UUID().uuidString,
                uploadToken: response.uploadToken,
                uploadUrl: response.uploadURL,
                maxFileSize: Int(response.maxFileSize),
                expiresAt: response.expiresAt
            )
        }
    }

    // MARK: - Upload Media (client streaming, replaces MediaAPI.uploadEncryptedFile)

    func uploadEncryptedFile(encryptedData: Data, token: String) async throws -> MediaAPI.UploadResponse {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_MediaService.Client(wrapping: grpcClient)

            let chunkSize = 64 * 1024 // 64 KB chunks
            let totalChunks = (encryptedData.count + chunkSize - 1) / chunkSize
            let hash = SHA256.hash(data: encryptedData)
            let hashHex = hash.map { String(format: "%02x", $0) }.joined()

            let capturedData = encryptedData
            let request = StreamingClientRequest<Shared_Proto_Services_V1_UploadMediaRequest>(
                metadata: [],
                producer: { writer in
                    for i in 0..<totalChunks {
                        let start = i * chunkSize
                        let end = min(start + chunkSize, capturedData.count)
                        let chunkData = capturedData.subdata(in: start..<end)

                        var req = Shared_Proto_Services_V1_UploadMediaRequest()
                        req.uploadToken = token
                        req.chunk = chunkData
                        req.chunkNumber = Int32(i)
                        req.isLast = (i == totalChunks - 1)
                        req.totalSize = Int64(capturedData.count)
                        req.fileHash = hashHex

                        try await writer.write(req)
                    }
                }
            )

            let response: Shared_Proto_Services_V1_UploadMediaResponse = try await client.uploadMedia(request: request)

            return MediaAPI.UploadResponse(
                mediaId: response.mediaID,
                expiresAt: Int(response.fileSize) // Use fileSize as placeholder; expiresAt from proto is String
            )
        }
    }

    // MARK: - Download Media (server streaming, replaces MediaAPI.downloadEncryptedFile)

    nonisolated func downloadEncryptedFile(mediaId: String) async throws -> Data {
        try await GRPCChannelManager.shared.performRPC { grpcClient in
            let client = Shared_Proto_Services_V1_MediaService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_DownloadMediaRequest()
            request.mediaID = mediaId

            let data: Data = try await client.downloadMedia(
                request: .init(message: request),
                onResponse: { (response: StreamingClientResponse<Shared_Proto_Services_V1_DownloadMediaResponse>) async throws -> Data in
                    let contents: StreamingClientResponse<Shared_Proto_Services_V1_DownloadMediaResponse>.Contents
                    switch response.accepted {
                    case .success(let c):
                        contents = c
                    case .failure(let error):
                        throw error
                    }

                    var assembled = Data()
                    for try await part in contents.bodyParts {
                        switch part {
                        case .message(let chunk):
                            assembled.append(chunk.chunk)
                        case .trailingMetadata:
                            break
                        }
                    }
                    return assembled
                }
            )

            return data
        }
    }

    // MARK: - High-Level: Upload Image (replaces MediaAPI.uploadImage)

    func uploadImage(_ image: UIImage, quality: CGFloat = 0.8) async throws -> MediaAPI.UploadedMedia {
        guard let imageData = image.jpegData(compressionQuality: quality) else {
            throw NetworkError.serverError(message: "Failed to compress image", responseBody: nil)
        }
        Log.info("📸 Image compressed: \(imageData.count) bytes (quality: \(quality))", category: "MediaService")
        return try await uploadData(imageData, mimeType: "image/jpeg")
    }

    // MARK: - High-Level: Upload Data (replaces MediaAPI.uploadData)

    func uploadData(_ data: Data, mimeType: String = "application/octet-stream") async throws -> MediaAPI.UploadedMedia {
        // 1. Generate encryption key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            throw NetworkError.serverError(message: "Failed to generate encryption key", responseBody: nil)
        }
        let encryptionKey = Data(keyBytes)

        // 2. Encrypt
        let symmetricKey = SymmetricKey(data: encryptionKey)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        var encryptedData = Data()
        encryptedData.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        encryptedData.append(sealedBox.ciphertext)
        encryptedData.append(sealedBox.tag)

        let hash = SHA256.hash(data: encryptedData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()

        // 3. Get token
        let tokenData = try await generateUploadToken(
            expectedSize: Int64(encryptedData.count),
            contentType: mimeType
        )

        // 4. Upload
        let uploadResponse = try await uploadEncryptedFile(
            encryptedData: encryptedData,
            token: tokenData.uploadToken
        )

        // 5. Construct download URL
        let baseUrl = tokenData.uploadUrl.replacingOccurrences(of: "/upload", with: "")
        let downloadUrl = "\(baseUrl)/\(uploadResponse.mediaId)"

        return MediaAPI.UploadedMedia(
            mediaId: uploadResponse.mediaId,
            mediaUrl: downloadUrl,
            encryptionKey: encryptionKey,
            encryptedData: encryptedData,
            hash: hashHex,
            mimeType: mimeType,
            expiresAt: uploadResponse.expiresAt
        )
    }

    // MARK: - High-Level: Download & Decrypt Image (replaces MediaAPI.downloadAndDecryptImage)

    func downloadAndDecryptImage(from mediaUrl: String, encryptionKey: Data) async throws -> UIImage {
        let mediaId = URL(string: mediaUrl)?.lastPathComponent ?? mediaUrl
        let encryptedData = try await downloadEncryptedFile(mediaId: mediaId)

        // Decrypt AES-256-GCM
        let nonceSize = 12
        let tagSize = 16
        guard encryptedData.count >= nonceSize + tagSize else {
            throw NetworkError.serverError(message: "Invalid encrypted data", responseBody: nil)
        }
        let nonce = try AES.GCM.Nonce(data: encryptedData.prefix(nonceSize))
        let ciphertext = encryptedData.dropFirst(nonceSize).dropLast(tagSize)
        let tag = encryptedData.suffix(tagSize)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let decryptedData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: encryptionKey))

        guard let image = UIImage(data: decryptedData) else {
            throw NetworkError.serverError(message: "Failed to decode image", responseBody: nil)
        }
        return image
    }
}
