//
//  MediaServiceClient.swift
//  Construct Messenger
//
//  gRPC MediaService client — replaces MediaAPI for media upload/download
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import CryptoKit
import GRPCCore
import GRPCNIOTransportHTTP2


final class MediaServiceClient: Sendable {
    static let shared = MediaServiceClient()

    private init() {}

    // MARK: - Models

    struct UploadedMedia {
        let mediaId: String
        let mediaUrl: String
        let encryptionKey: Data
        /// Size of the encrypted payload in bytes (the data itself is not retained after upload).
        let encryptedSize: Int
        let hash: String
        let mimeType: String
    }
}

extension MediaServiceClient {



    // MARK: - Download Media (server streaming)

    /// - Parameter onProgress: called with cumulative bytes received as chunks arrive,
    ///   for real download progress UI. The caller knows the expected total (the
    ///   descriptor's encrypted `size`) and converts to a fraction.
    nonisolated func downloadEncryptedFile(
        mediaId: String,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Data {
        // Media downloads are long-running server-streaming RPCs. Do NOT arm the 4s
        // fast-fallback direct timeout here — it causes false .deadlineExceeded on
        // healthy but high-latency/slow links.
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.downloadMedia) { grpcClient in
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
                            onProgress?(Int64(assembled.count))
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


    // MARK: - High-Level: Upload Data

    func uploadData(_ data: Data, mimeType: String = "application/octet-stream") async throws -> UploadedMedia {
        // 1. Generate encryption key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes) == errSecSuccess else {
            throw NetworkError.serverError(message: "Failed to generate encryption key", responseBody: nil)
        }
        let encryptionKey = Data(keyBytes)

        // 2. Encrypt (AES-256-GCM: 12-byte nonce + ciphertext + 16-byte tag)
        let symmetricKey = SymmetricKey(data: encryptionKey)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        var encryptedData = Data()
        encryptedData.append(sealedBox.nonce.withUnsafeBytes { Data($0) })
        encryptedData.append(sealedBox.ciphertext)
        encryptedData.append(sealedBox.tag)
        let encryptedSize = encryptedData.count

        let hash = SHA256.hash(data: encryptedData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()

        // 3. Get token + upload on the SAME channel to prevent CANCELLED errors.
        // Upload tokens are tied to the connection that generated them — using two
        // separate performRPC calls (two separate channels) causes the server to
        // cancel the upload stream (RPCError code 1 = CANCELLED).
        let capturedEncryptedData = encryptedData
        // Upload is also long-running; avoid the 4s fast-fallback direct timeout.
        let (mediaId, downloadUrl) = try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.uploadMedia) { grpcClient in
            let client = Shared_Proto_Services_V1_MediaService.Client(wrapping: grpcClient)

            // 3a. Generate upload token
            var tokenRequest = Shared_Proto_Services_V1_GenerateUploadTokenRequest()
            tokenRequest.expectedSize = Int64(capturedEncryptedData.count)
            tokenRequest.contentType = mimeType
            let tokenResponse = try await client.generateUploadToken(
                request: .init(message: tokenRequest)
            )
            let uploadToken = tokenResponse.uploadToken

            // 3b. Stream upload on the same channel
            let chunkSize = 64 * 1024
            let totalChunks = (capturedEncryptedData.count + chunkSize - 1) / chunkSize
            let fileHash = hashHex

            let uploadRequest = StreamingClientRequest<Shared_Proto_Services_V1_UploadMediaRequest>(
                metadata: [],
                producer: { writer in
                    for i in 0..<totalChunks {
                        let start = i * chunkSize
                        let end = min(start + chunkSize, capturedEncryptedData.count)
                        var req = Shared_Proto_Services_V1_UploadMediaRequest()
                        req.uploadToken = uploadToken
                        req.chunk = capturedEncryptedData.subdata(in: start..<end)
                        req.chunkNumber = Int32(i)
                        req.isLast = (i == totalChunks - 1)
                        req.totalSize = Int64(capturedEncryptedData.count)
                        req.fileHash = fileHash
                        try await writer.write(req)
                    }
                }
            )

            let uploadResponse: Shared_Proto_Services_V1_UploadMediaResponse =
                try await client.uploadMedia(request: uploadRequest)
            return (uploadResponse.mediaID, uploadResponse.downloadURL)
        }

        return UploadedMedia(
            mediaId: mediaId,
            mediaUrl: downloadUrl,
            encryptionKey: encryptionKey,
            encryptedSize: encryptedSize,
            hash: hashHex,
            mimeType: mimeType
        )
    }

    // MARK: - High-Level: Download & Decrypt Image

    func downloadAndDecryptImage(from mediaUrl: String, encryptionKey: Data) async throws -> PlatformImage {
        let mediaId = URL(string: mediaUrl)?.lastPathComponent ?? mediaUrl
        let encryptedData = try await downloadEncryptedFile(mediaId: mediaId)

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

        guard let image = PlatformImage(data: decryptedData) else {
            throw NetworkError.serverError(message: "Failed to decode image", responseBody: nil)
        }
        return image
    }
}
