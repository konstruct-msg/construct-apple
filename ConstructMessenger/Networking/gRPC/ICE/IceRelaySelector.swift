//
//  IceRelaySelector.swift
//  Construct Messenger
//

import Foundation
import Network

struct IceRelayLatencySelection {
    let orderedAddresses: [String]
    let relayQualityScores: [String: RelayQualityScore]
    let measuredLatency: Bool
}

struct IceRelayFailureSelection {
    let orderedAddresses: [String]
    let failedAddresses: [String]
}

/// Builds and orders ICE relay candidates without starting the native proxy.
enum IceRelaySelector {
    static func manifestIdMap() -> [String: String] {
        let infos = IceCertFetcher.cachedRelayInfosSync() ?? []
        return Dictionary(uniqueKeysWithValues: infos.map { ($0.addressWithPort, $0.id) })
    }

    static func candidateAddresses(currentHost: String) -> [String] {
        let iceHost = "ice.\(currentHost)"
        var seen = Set<String>()
        var candidates: [String] = []
        let allAddresses = ["\(iceHost):443"] + ICEConfig.hardcodedRelayAddresses + IceProxyStore.cachedRelayList()
        for address in allAddresses where seen.insert(address).inserted {
            candidates.append(address)
        }
        return candidates
    }

    static func cachedRelayAddresses() -> [String] {
        IceProxyStore.cachedRelayAddresses(fallback: ICEConfig.hardcodedRelayAddresses)
    }

    static func certificateExpiryAddresses() -> Set<String> {
        var addresses = Set<String>()
        ICEConfig.hardcodedRelayAddresses.forEach { addresses.insert($0) }
        IceProxyStore.cachedRelayList().forEach { addresses.insert($0) }
        return addresses
    }

    static func applyRegionPreference(to candidates: [String]) -> [String] {
        // GeoIP takes priority when resolved; fall through to timezone-based server config otherwise.
        let geoRegion = GeoIPManager.shared.region
        if geoRegion != .unknown {
            return applyGeoIPPreference(to: candidates, region: geoRegion)
        }

        // Timezone fallback: use server-provided or hardcoded region rules.
        let regions = IceProxyStore.cachedRelayRegions(fallback: ICEConfig.hardcodedRelayRegions)
        let tzOffset = TimeZone.current.secondsFromGMT() / 3600
        guard let rule = regions.first(where: {
            tzOffset >= $0.tzOffsetMin && tzOffset <= $0.tzOffsetMax
        }) else { return candidates }
        let preferred = rule.preferredRelays
        let front = preferred.filter { candidates.contains($0) }
        let back = candidates.filter { !preferred.contains($0) }
        return front + back
    }

    // Reorders candidates based on GeoIP region: ruLike countries prefer the RU relay
    // (WebTunnel/obfs4-capable), all others prefer the AMS relay (lower latency for EU/global).
    private static func applyGeoIPPreference(to candidates: [String], region: GeoIPRegion) -> [String] {
        let preferred: [String]
        switch region {
        case .ruLike:
            preferred = [ICEConfig.ruRelayAddress, ICEConfig.amsRelayAddress]
        case .other, .unknown:
            preferred = [ICEConfig.amsRelayAddress, ICEConfig.ruRelayAddress]
        }
        let front = preferred.filter { candidates.contains($0) }
        let back = candidates.filter { !preferred.contains($0) }
        return front + back
    }

    /// Probes all addresses concurrently and returns them sorted by TCP latency.
    /// Cached fresh EWMA entries are used without network probing.
    static func sortByLatency(
        _ addresses: [String],
        relayQualityScores: [String: RelayQualityScore],
        timeout: TimeInterval = NetworkTiming.ICE.relayLatencyProbeTimeout
    ) async -> IceRelayLatencySelection {
        guard !addresses.isEmpty else {
            return IceRelayLatencySelection(
                orderedAddresses: [],
                relayQualityScores: relayQualityScores,
                measuredLatency: false
            )
        }

        var updatedScores = relayQualityScores
        var cachedEntries: [(String, TimeInterval)] = []
        var toProbe: [String] = []

        for address in addresses {
            if let score = updatedScores[address], score.hasRecentLatency {
                cachedEntries.append((address, score.ewmaLatencyMs / 1000))
            } else {
                toProbe.append(address)
            }
        }

        var probeResults: [(String, TimeInterval?)] = []
        var earlyExitAfter: Date?

        if !toProbe.isEmpty {
            await withTaskGroup(of: (String, TimeInterval?).self) { group in
                for address in toProbe {
                    group.addTask { (address, await probeLatency(address: address, timeout: timeout)) }
                }
                for await (address, latency) in group {
                    probeResults.append((address, latency))
                    if latency != nil, earlyExitAfter == nil {
                        earlyExitAfter = Date().addingTimeInterval(NetworkTiming.ICE.sortByLatencyEarlyExitDelay)
                    }
                    if probeResults.count == toProbe.count { break }
                    if let deadline = earlyExitAfter, Date() >= deadline {
                        group.cancelAll()
                        break
                    }
                }
            }

            for (address, latency) in probeResults {
                guard let sample = latency else { continue }
                updatedScores[address, default: RelayQualityScore()].applyLatencySample(sample)
            }
        }

        if !cachedEntries.isEmpty {
            let skipped = cachedEntries.map { "\($0.0) (\(Int($0.1 * 1000))ms cached)" }.joined(separator: ", ")
            Log.debug("Latency cache hit for: \(skipped)", category: "ICE")
        }

        let freshReachable = probeResults.filter { $0.1 != nil }
        let allReachable: [(String, TimeInterval)] = (cachedEntries + freshReachable.map { ($0.0, $0.1!) })
            .sorted { $0.1 < $1.1 }

        let probedSet = Set(probeResults.map(\.0))
        let cancelled = toProbe.filter { !probedSet.contains($0) }
        let unreachable = probeResults.filter { $0.1 == nil }.map(\.0) + cancelled

        return IceRelayLatencySelection(
            orderedAddresses: allReachable.map(\.0) + unreachable,
            relayQualityScores: updatedScores,
            measuredLatency: !probeResults.isEmpty
        )
    }

    static func deprioritizeFailed(
        _ ordered: [String],
        isRecentlyFailed: (String) -> Bool,
        isWebTunnelBlocked: (String) -> Bool
    ) -> IceRelayFailureSelection {
        let notFailed = ordered.filter { !isRecentlyFailed($0) }
        let failed = ordered.filter { isRecentlyFailed($0) }
        guard !failed.isEmpty else {
            return IceRelayFailureSelection(orderedAddresses: ordered, failedAddresses: [])
        }

        let reordered: [String]
        if notFailed.isEmpty {
            // All relays recently failed. Prefer WebTunnel-capable relays first because CDN-fronted
            // HTTPS WebSocket is less fingerprintable than obfs4 TLS profile on some networks.
            let failedWebTunnel = failed.filter {
                IceCertFetcher.wtPathSync(for: $0) != nil && !isWebTunnelBlocked($0)
            }
            let failedNoWebTunnel = failed.filter {
                IceCertFetcher.wtPathSync(for: $0) == nil || isWebTunnelBlocked($0)
            }
            reordered = failedWebTunnel + failedNoWebTunnel
        } else {
            // NotFailed first, then failed — but within failed, demote "definitively bad" relays
            // (repeat WebTunnel blocks) below transient failures.
            let definitivelyBad = failed.filter { isWebTunnelBlocked($0) }
            let transientFailed = failed.filter { !isWebTunnelBlocked($0) }
            reordered = notFailed + transientFailed + definitivelyBad
        }

        return IceRelayFailureSelection(orderedAddresses: reordered, failedAddresses: failed)
    }

    /// Opens a TCP connection to `host:port` and returns time-to-ready, or nil if unreachable.
    private static func probeLatency(
        address: String,
        timeout: TimeInterval = NetworkTiming.ICE.relayLatencyProbeTimeout
    ) async -> TimeInterval? {
        let parts = address.split(separator: ":")
        guard parts.count >= 2, let port = NWEndpoint.Port(String(parts.last!)) else { return nil }
        let hostname = String(parts.dropLast().joined(separator: ":"))

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: .init(hostname), port: port, using: .tcp)
            let flag = RelayProbeResumeFlag()
            let start = CFAbsoluteTimeGetCurrent()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard flag.trigger() else { return }
                    connection.cancel()
                    continuation.resume(returning: CFAbsoluteTimeGetCurrent() - start)
                case .failed, .cancelled:
                    guard flag.trigger() else { return }
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard flag.trigger() else { return }
                connection.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

private final class RelayProbeResumeFlag: @unchecked Sendable {
    private var triggered = false
    private let lock = NSLock()

    func trigger() -> Bool {
        lock.withLock {
            guard !triggered else { return false }
            triggered = true
            return true
        }
    }
}
