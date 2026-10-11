//
//  PendingFetch.swift
//  Konstruct Notifications
//
//  One `GetPendingMessages` call, the read the app's background fetch makes, from the cursor the
//  app committed. The server trims nothing on a read (`since_cursor` is an offset), and this
//  never acks, never commits a cursor and never refreshes the token: those are the app's. Direct
//  TLS only — the VEIL proxy lives in the app's process, so where the direct path is blocked the
//  fetch fails and the alert is shown as it came.
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

struct PendingDelivery {
    let messageId: String
    let sealedInner: Data
}

struct PendingPage {
    let deliveries: [PendingDelivery]
    let hasMore: Bool
    /// Deliveries with no `SealedInner`: not readable by the peek.
    let unsealed: Int
}

enum PendingFetch {
    /// The app's page size (`BackgroundFetchManager`): the same read, the same window.
    static let pageLimit: Int32 = 50

    struct Credentials {
        let host: String
        let port: Int
        let token: String
        let userId: String
        let deviceId: String
        let cursor: String?
    }

    static func page(_ credentials: Credentials, timeout: Duration) async throws -> PendingPage {
        let transport = try HTTP2ClientTransport.TransportServices(
            target: .dns(host: credentials.host, port: credentials.port),
            transportSecurity: .tls
        )
        return try await withGRPCClient(transport: transport) { client in
            let messaging = Shared_Proto_Services_V1_MessagingService.Client(wrapping: client)
            var request = Shared_Proto_Services_V1_GetPendingMessagesRequest()
            if let cursor = credentials.cursor, !cursor.isEmpty {
                request.sinceCursor = cursor
            }
            request.limit = pageLimit
            // The headers the app's AuthInterceptor sends.
            var metadata = Metadata()
            metadata.addString("Bearer \(credentials.token)", forKey: "authorization")
            metadata.addString(credentials.userId, forKey: "x-user-id")
            metadata.addString(credentials.deviceId, forKey: "x-device-id")
            var options = CallOptions.defaults
            options.timeout = timeout

            let response = try await messaging.getPendingMessages(
                request: ClientRequest(message: request, metadata: metadata),
                options: options
            )
            let sealed = response.messages.filter { !$0.sealedInnerData.isEmpty }
            return PendingPage(
                deliveries: sealed.map { PendingDelivery(messageId: $0.messageID, sealedInner: $0.sealedInnerData) },
                hasMore: response.hasMore_p,
                unsealed: response.messages.count - sealed.count
            )
        }
    }
}
