import Foundation
import StudioCore

public func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

/// Optional raw dump of a sample stream: interleaved Int32 little-endian, nothing else. Two dumps
/// of the same stream are byte-identical, so `cmp sent.s32 received.s32` is the bit-exactness
/// check for a real DAW signal (the received one is shorter by what was in flight at the end).
public final class SampleDump {
    private let handle: FileHandle
    public init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }
    public func write(_ samples: [Int32]) {
        samples.withUnsafeBytes { handle.write(Data($0)) }
    }
    deinit { try? handle.close() }
}

/// Host side: PCM packets in, FLAC frames out on the peer, in order.
public final class ProgramSender {
    public let format: AudioFormat
    private let peer: StudioPeer
    private let encoder: FlacEncoder
    private let lock = NSLock()
    /// Frame index of each packet the encoder has taken and not yet released.
    private var heldFrames: [UInt64] = []
    private var sequence: UInt32 = 0
    private var dump: SampleDump?

    /// SCTP send-buffer level above which a packet is dropped rather than queued: the program must
    /// stay live, and a reliable channel that cannot keep up only grows its own delay.
    public var dropAboveBufferedBytes: UInt64 = 2 << 20

    public private(set) var packetsSent = 0
    public private(set) var packetsDropped = 0
    public private(set) var bytesSent = 0

    public init(peer: StudioPeer, format: AudioFormat, dumpPath: String? = nil) throws {
        self.peer = peer
        self.format = format
        encoder = try FlacEncoder(format: format)
        dump = try dumpPath.map(SampleDump.init(path:))
    }

    public func sendConfig() throws {
        let config = StreamConfig(format: format, magicCookie: try encoder.magicCookie())
        peer.send(config.frame(sentAtNanos: nowNanos()).encoded())
    }

    public func push(_ samples: [Int32], firstFrame: UInt64) {
        lock.lock(); defer { lock.unlock() }
        dump?.write(samples)
        heldFrames.append(firstFrame)
        let released: [Data]
        do { released = try encoder.encode(samples) } catch {
            FileHandle.standardError.write("encode failed: \(error)\n".data(using: .utf8)!)
            return
        }
        for packet in released {
            let first = heldFrames.removeFirst()
            if peer.bufferedAmount > dropAboveBufferedBytes {
                packetsDropped += 1
                continue
            }
            sequence &+= 1
            let frame = StudioFrame(kind: .audio, frames: UInt16(format.framesPerPacket), sequence: sequence,
                                    firstFrame: first, sentAtNanos: nowNanos(), sampleRate: UInt32(format.sampleRate),
                                    channels: UInt16(format.channels), payload: packet).encoded()
            peer.send(frame)
            packetsSent += 1
            bytesSent += frame.count
        }
    }

    public func ping() {
        peer.send(StudioFrame(kind: .ping, frames: 0, sequence: 0, firstFrame: 0, sentAtNanos: nowNanos(),
                              sampleRate: 0, channels: 0, payload: Data()).encoded())
    }
}

/// Listener side: frames in, decoded samples into the playout buffer, with the checks the spike
/// is for — bit-exactness against the test signal, transport latency (loopback only), RTT.
public final class ProgramReceiver {
    public enum Verify { case none, testSignal }

    private let peer: StudioPeer
    private let verify: Verify
    private let bufferSeconds: Double
    private let lock = NSLock()
    private var decoder: FlacDecoder?
    private var dump: SampleDump?
    /// First frame index of each packet given to the decoder and not yet released by it, and the
    /// decoded samples not yet a whole packet. FLAC frames decode independently, so a packet the
    /// sender dropped is just a missing index, not a broken stream.
    private var heldFrames: [UInt64] = []
    private var decodedCarry: [Int32] = []
    private var lastSequence: UInt32?

    public private(set) var format: AudioFormat?
    public private(set) var buffer: PlayoutBuffer?
    public private(set) var framesReceived = 0
    public private(set) var bytesReceived = 0
    public private(set) var sequenceGaps = 0
    public private(set) var samplesCompared = 0
    public private(set) var samplesMismatched = 0
    /// Send → receive, nanoseconds. Meaningful only when both ends share a clock (loopback).
    public private(set) var transportNanos: [Double] = []
    public private(set) var rttNanos: [Double] = []

    public var onConfig: ((AudioFormat, PlayoutBuffer) -> Void)?

    public init(peer: StudioPeer, verify: Verify, bufferSeconds: Double, dumpPath: String? = nil) throws {
        self.peer = peer
        self.verify = verify
        self.bufferSeconds = bufferSeconds
        dump = try dumpPath.map(SampleDump.init(path:))
    }

    public func handle(_ data: Data) {
        let frame: StudioFrame
        do { frame = try StudioFrame(decoding: data) } catch {
            FileHandle.standardError.write("bad frame: \(error)\n".data(using: .utf8)!)
            return
        }
        switch frame.kind {
        case .config: configure(frame)
        case .audio: audio(frame)
        case .ping:
            var pong = frame
            pong.kind = .pong
            peer.send(pong.encoded())
        case .pong:
            lock.lock(); rttNanos.append(Double(nowNanos() &- frame.sentAtNanos)); lock.unlock()
        }
    }

    private func configure(_ frame: StudioFrame) {
        do {
            let config = try StreamConfig(frame: frame)
            let decoder = try FlacDecoder(format: config.format, magicCookie: config.magicCookie)
            let buffer = PlayoutBuffer(channels: Int(config.format.channels), sampleRate: config.format.sampleRate,
                                       targetSeconds: bufferSeconds)
            lock.lock()
            self.decoder = decoder
            self.format = config.format
            self.buffer = buffer
            lock.unlock()
            onConfig?(config.format, buffer)
        } catch {
            FileHandle.standardError.write("bad config: \(error)\n".data(using: .utf8)!)
        }
    }

    private func audio(_ frame: StudioFrame) {
        lock.lock(); defer { lock.unlock() }
        guard let decoder, let format, let buffer else { return }
        framesReceived += 1
        bytesReceived += frame.payload.count + StudioFrame.headerSize
        transportNanos.append(Double(nowNanos() &- frame.sentAtNanos))
        if let last = lastSequence, frame.sequence != last &+ 1 { sequenceGaps += 1 }
        lastSequence = frame.sequence
        heldFrames.append(frame.firstFrame)

        do { decodedCarry += try decoder.decode(frame.payload) } catch {
            FileHandle.standardError.write("decode failed: \(error)\n".data(using: .utf8)!)
            heldFrames.removeLast()
            return
        }
        let n = format.samplesPerPacket
        while decodedCarry.count >= n, !heldFrames.isEmpty {
            let decoded = Array(decodedCarry.prefix(n))
            decodedCarry.removeFirst(n)
            let first = heldFrames.removeFirst()
            dump?.write(decoded)
            if verify == .testSignal {
                let expected = TestSignal.samples(firstFrame: first, format: format)
                samplesCompared += decoded.count
                samplesMismatched += zip(decoded, expected).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            }
            buffer.write(decoded, firstFrame: first)
        }
    }

    public func snapshot() -> (transport: [Double], rtt: [Double]) {
        lock.lock(); defer { lock.unlock() }
        return (transportNanos, rttNanos)
    }
}
