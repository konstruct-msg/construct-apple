//
//  HistoryByteTransport.swift
//  Construct Messenger
//
//  Byte pipe for CTH1 nearby. NWConnection in production; in-memory duplex in tests.
//

import Foundation

protocol HistoryByteTransport: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receiveExact(_ count: Int) async throws -> Data
    func close()
}

enum HistoryByteTransportError: Error {
    case closed
    case dropped
}

/// In-process duplex. `left` writes what `right` reads, and the reverse.
final class HistoryMemoryDuplex: @unchecked Sendable {
    let left: End
    let right: End

    init() {
        let a = Buffer()
        let b = Buffer()
        left = End(outbound: a, inbound: b)
        right = End(outbound: b, inbound: a)
    }

    /// Fail the next write after `n` successful `send` calls on `left`.
    func dropOutbound(afterSends n: Int) {
        left.outbound.dropAfterSends = n
    }

    final class End: HistoryByteTransport, @unchecked Sendable {
        let outbound: Buffer
        let inbound: Buffer

        init(outbound: Buffer, inbound: Buffer) {
            self.outbound = outbound
            self.inbound = inbound
        }

        func send(_ data: Data) async throws {
            try outbound.write(data)
        }

        func receiveExact(_ count: Int) async throws -> Data {
            try await inbound.readExact(count)
        }

        func close() {
            outbound.close()
            inbound.close()
        }
    }

    final class Buffer: @unchecked Sendable {
        private var data = Data()
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private let lock = NSLock()
        private var closed = false
        var dropAfterSends: Int?
        private var sends = 0

        func write(_ incoming: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            if closed { throw HistoryByteTransportError.closed }
            if let cap = dropAfterSends, sends >= cap {
                closed = true
                failWaitersLocked(HistoryByteTransportError.dropped)
                throw HistoryByteTransportError.dropped
            }
            sends += 1
            data.append(incoming)
            wakeLocked()
        }

        func readExact(_ count: Int) async throws -> Data {
            while true {
                switch take(count) {
                case .ready(let out): return out
                case .closed: throw HistoryByteTransportError.closed
                case .wait: break
                }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if data.count >= count {
                        lock.unlock()
                        cont.resume()
                    } else if closed {
                        lock.unlock()
                        cont.resume(throwing: HistoryByteTransportError.closed)
                    } else {
                        waiters.append(cont)
                        lock.unlock()
                    }
                }
            }
        }

        private enum Take {
            case ready(Data)
            case closed
            case wait
        }

        /// One locked look at the buffer. Synchronous on purpose: `readExact` is async and an
        /// NSLock must not be held across a suspension.
        private func take(_ count: Int) -> Take {
            lock.lock()
            defer { lock.unlock() }
            if data.count >= count {
                let out = Data(data.prefix(count))
                data.removeSubrange(0..<count)
                return .ready(out)
            }
            return closed ? .closed : .wait
        }

        func close() {
            lock.lock()
            closed = true
            failWaitersLocked(HistoryByteTransportError.closed)
            lock.unlock()
        }

        private func wakeLocked() {
            let w = waiters
            waiters.removeAll()
            w.forEach { $0.resume() }
        }

        private func failWaitersLocked(_ error: Error) {
            let w = waiters
            waiters.removeAll()
            w.forEach { $0.resume(throwing: error) }
        }
    }
}
