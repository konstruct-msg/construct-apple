//
//  PeerDeviceStore.swift
//  Construct Messenger
//
//  The peer-device table as a repository: values in, values out, no managed object and no
//  context. The first domain behind the storage seam (`client/specs/LOCAL_STORE_MIGRATION_PLAN.md`
//  step 1): Core Data answers today, `LocalStore` (construct-store) takes over on macOS in step 3
//  with the same operations — `record_peer_device`, `peer_devices`, `peer_device`,
//  `all_peer_devices`, `retain_peer_devices`.
//

import Foundation
import CoreData

/// One device of a peer's account. `deviceId` is `SHA256(identityKey)[0..16]`; the store does not
/// check that — `SessionAddressing.recordDevices` does, before anything reaches it.
struct PeerDeviceRecord: Equatable, Sendable {
    let deviceId: String
    let accountId: String
    let identityKey: Data
    let firstSeenAt: Date
}

/// Reading and writing the table. Policy — what to record, when to prune, what to log — is
/// `SessionAddressing`'s; this answers and writes.
///
/// There are no change events yet: nothing observes this table. They come with the first domain a
/// screen observes, rather than as a producer with no consumer.
protocol PeerDeviceStore: Sendable {
    /// `accountId`'s devices, oldest first, `deviceId` breaking ties. Empty means none recorded,
    /// never "the account has no devices".
    func devices(ofAccount accountId: String) throws -> [PeerDeviceRecord]

    func device(_ deviceId: String) throws -> PeerDeviceRecord?

    /// Every account's devices — the hints a history snapshot carries.
    func allDevices() throws -> [PeerDeviceRecord]

    /// Adds the devices whose id is not recorded yet, in one write, and returns their ids. A
    /// recorded id stays as it was first recorded, account included.
    func record(_ devices: [PeerDeviceRecord]) throws -> [String]

    /// Removes `accountId`'s devices outside `keeping` and returns their ids. An empty `keeping`
    /// removes nothing: it cannot be told from a server that does not send the list.
    func retain(ofAccount accountId: String, keeping: Set<String>) throws -> [String]
}

/// `PeerDevice` rows.
///
/// Each call runs on a fresh background context. Callers are on the main actor, on other
/// contexts' queues and on bare threads — and `viewContext` read off the main thread does not fail,
/// it returns nothing, which reads as "this peer has no devices". `viewContext.performAndWait` from
/// a background thread would instead wait on the main queue, which the background decrypt path
/// already waits on the other way. A fetch of a handful of rows on an indexed column is the cheap
/// part.
final class CoreDataPeerDeviceStore: PeerDeviceStore, @unchecked Sendable {

    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func devices(ofAccount accountId: String) throws -> [PeerDeviceRecord] {
        try fetch(NSPredicate(format: "accountId == %@", accountId))
    }

    func device(_ deviceId: String) throws -> PeerDeviceRecord? {
        try fetch(NSPredicate(format: "deviceId == %@", deviceId), limit: 1).first
    }

    func allDevices() throws -> [PeerDeviceRecord] {
        try fetch(nil, byAccount: true)
    }

    func record(_ devices: [PeerDeviceRecord]) throws -> [String] {
        guard !devices.isEmpty else { return [] }
        return try run { context in
            let req = PeerDevice.fetchRequest()
            req.predicate = NSPredicate(format: "deviceId IN %@", devices.map(\.deviceId))
            var known = Set(try context.fetch(req).map(\.deviceId))
            var added: [String] = []
            for device in devices where !known.contains(device.deviceId) {
                let row = PeerDevice(context: context)
                row.deviceId = device.deviceId
                row.accountId = device.accountId
                row.identityKey = device.identityKey
                row.firstSeenAt = device.firstSeenAt
                known.insert(device.deviceId)
                added.append(device.deviceId)
            }
            if context.hasChanges { try context.saveOrThrow(category: "Crypto") }
            return added
        }
    }

    func retain(ofAccount accountId: String, keeping: Set<String>) throws -> [String] {
        guard !keeping.isEmpty else { return [] }
        return try run { context in
            let req = PeerDevice.fetchRequest()
            req.predicate = NSPredicate(
                format: "accountId == %@ AND NOT (deviceId IN %@)", accountId, Array(keeping)
            )
            let stale = try context.fetch(req)
            let ids = stale.map(\.deviceId).sorted()
            stale.forEach(context.delete)
            if context.hasChanges { try context.saveOrThrow(category: "Crypto") }
            return ids
        }
    }

    private func fetch(
        _ predicate: NSPredicate?, limit: Int = 0, byAccount: Bool = false
    ) throws -> [PeerDeviceRecord] {
        try run { context in
            let req = PeerDevice.fetchRequest()
            req.predicate = predicate
            req.fetchLimit = limit
            req.sortDescriptors = (byAccount ? [NSSortDescriptor(key: "accountId", ascending: true)] : []) + [
                NSSortDescriptor(key: "firstSeenAt", ascending: true),
                NSSortDescriptor(key: "deviceId", ascending: true)
            ]
            return try context.fetch(req).map {
                PeerDeviceRecord(
                    deviceId: $0.deviceId, accountId: $0.accountId,
                    identityKey: $0.identityKey, firstSeenAt: $0.firstSeenAt
                )
            }
        }
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}
