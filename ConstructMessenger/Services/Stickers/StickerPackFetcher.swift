//
//  StickerPackFetcher.swift
//  Construct Messenger
//
//  The wire half of the sticker service: the manifest, then every blob, over the
//  unauthenticated channel. Nothing here is trusted — `StickerService` verifies the manifest
//  and `StickerBlobStore` verifies every blob. This only moves bytes.
//

import Foundation
import GRPCCore
import SwiftProtobuf   // serializedData — explicit under #MemberImportVisibility

/// The test seam. A fetcher returns bytes; what they mean is decided above it.
protocol StickerPackFetching: Sendable {
    /// The manifest's serialized bytes, exactly as the server holds them.
    func manifestBytes(for pack: StickerPackID) async throws -> Data
    /// Every blob of the pack the client does not already hold, delivered as they arrive.
    /// `onBlob` may throw to abort the stream (a blob the store refused).
    func blobs(
        for pack: StickerPackID,
        have: [Data],
        onBlob: @escaping @Sendable (_ sha256: Data, _ data: Data) throws -> Void
    ) async throws
    /// The catalog, all pages.
    func catalog() async throws -> [Shared_Proto_Services_V1_StickerPackSummary]
}

/// gRPC over the same channel prekey bundles use: sealed when the unauthenticated-transport flag
/// is on, the ordinary one otherwise. A pack fetch carries no account identity either way — the
/// RPCs read no caller — and under the sealed flag the server does not see one at all.
struct StickerPackFetcher: StickerPackFetching {
    private var sealed: Bool { FeatureFlags.sealedSenderUnauthenticatedTransport }

    func manifestBytes(for pack: StickerPackID) async throws -> Data {
        try await GRPCChannelManager.shared.performRPC(sealed: sealed, timeout: GRPCTimeouts.stickerManifest) { grpc in
            let client = Shared_Proto_Services_V1_StickerService.Client(wrapping: grpc)
            var request = Shared_Proto_Services_V1_GetStickerPackManifestRequest()
            request.packID = pack.bytes
            let response = try await client.getStickerPackManifest(request: .init(message: request))
            // Re-serialized from the decoded message: for this message the encoding is
            // deterministic, and it is what every client hashes (knst_sticker_pack vectors).
            return try response.manifest.serializedData()
        }
    }

    func blobs(
        for pack: StickerPackID,
        have: [Data],
        onBlob: @escaping @Sendable (_ sha256: Data, _ data: Data) throws -> Void
    ) async throws {
        try await GRPCChannelManager.shared.performRPC(sealed: sealed, timeout: GRPCTimeouts.stickerPack) { grpc in
            let client = Shared_Proto_Services_V1_StickerService.Client(wrapping: grpc)
            var request = Shared_Proto_Services_V1_GetStickerPackBlobsRequest()
            request.packID = pack.bytes
            request.haveSha256 = have
            try await client.getStickerPackBlobs(request: .init(message: request)) { response in
                for try await message in response.messages {
                    try onBlob(message.sha256, message.data)
                }
            }
        }
    }

    func catalog() async throws -> [Shared_Proto_Services_V1_StickerPackSummary] {
        try await GRPCChannelManager.shared.performRPC(sealed: sealed, timeout: GRPCTimeouts.stickerManifest) { grpc in
            let client = Shared_Proto_Services_V1_StickerService.Client(wrapping: grpc)
            var all: [Shared_Proto_Services_V1_StickerPackSummary] = []
            var token = Data()
            repeat {
                var request = Shared_Proto_Services_V1_ListStickerPacksRequest()
                request.pageToken = token
                let page = try await client.listStickerPacks(request: .init(message: request))
                all.append(contentsOf: page.packs)
                token = page.nextPageToken
            } while !token.isEmpty && all.count < StickerService.catalogCeiling
            return all
        }
    }
}
