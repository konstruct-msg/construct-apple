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
import GRPCCore
import GRPCNIOTransportHTTP2


final class MediaServiceClient: Sendable {
    static let shared = MediaServiceClient()

    private init() {}

    // MARK: - Models

    struct UploadedMedia: Codable, Sendable {
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
        //
        // On the channel with no token (the sealed one, as Android's `publicMedia`): the
        // server serves `DownloadMedia` to anyone holding the id, and over the signed-in
        // channel every download named the account and device that fetched it — who
        // received whose attachment. Avatars come through here too.
        try await GRPCChannelManager.shared.performSealedRPC(timeout: GRPCTimeouts.downloadMedia) { grpcClient in
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

    /// - Parameter onProgress: called with cumulative upload fraction (0.0…1.0) as chunks
    ///   are written to the stream, for real send-progress UI. Best-effort; may be called
    ///   from a background task, so marshal to the main actor in the handler if updating UI.
    func uploadData(
        _ data: Data,
        mimeType: String = "application/octet-stream",
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedMedia {
        // 1–2. Seal: the core makes the key and the blob — padded to a size bucket, so the
        // server sees a size class rather than the file's size (construct-core `media.rs`).
        let sealed = try sealMedia(plaintext: data)
        let encryptionKey = sealed.key
        let encryptedData = sealed.blob
        let encryptedSize = encryptedData.count
        let hashHex = sealed.sha256.map { String(format: "%02x", $0) }.joined()

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
            // `contentType` left unset on purpose: the server stores an opaque blob and never
            // read it, and a MIME type beside a padded size would name what the padding hides.
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
                    let totalBytes = capturedEncryptedData.count
                    for i in 0..<totalChunks {
                        let start = i * chunkSize
                        let end = min(start + chunkSize, capturedEncryptedData.count)
                        var req = Shared_Proto_Services_V1_UploadMediaRequest()
                        req.uploadToken = uploadToken
                        req.chunk = capturedEncryptedData.subdata(in: start..<end)
                        req.chunkNumber = Int32(i)
                        req.isLast = (i == totalChunks - 1)
                        req.totalSize = Int64(totalBytes)
                        req.fileHash = fileHash
                        try await writer.write(req)
                        if let onProgress, totalBytes > 0 {
                            // Cap streamed-bytes fraction at 0.95 — the final 5% covers the
                            // server's assemble + ack round-trip after the last chunk.
                            onProgress(min(0.95, Double(end) / Double(totalBytes)))
                        }
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
}
