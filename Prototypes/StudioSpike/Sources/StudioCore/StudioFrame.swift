import Foundation

/// One data-channel message of the program stream. Little-endian, fixed 32-byte header:
///
///     0  u8   version (1)
///     1  u8   kind: 0 = config (payload: frames per packet + magic cookie), 1 = audio (payload:
///             FLAC packet), 2 = ping, 3 = pong
///     2  u16  frames in the packet
///     4  u32  sequence number, per kind
///     8  u64  first frame index on the host's capture clock
///    16  u64  host send time, nanoseconds (mach continuous) — comparable only on the same machine
///    24  u32  sample rate, Hz
///    28  u16  channels
///    30  u16  reserved
///
/// The frame index is what the receiver schedules by and what the test signal is a function of;
/// the send time measures latency in a loopback run and means nothing across two machines.
public struct StudioFrame: Equatable, Sendable {
    /// `ping`/`pong` carry no payload: a pong echoes the ping's `sentAtNanos`, so the pinger reads
    /// the round trip on its own clock.
    public enum Kind: UInt8, Sendable { case config = 0, audio = 1, ping = 2, pong = 3 }

    public static let version: UInt8 = 1
    public static let headerSize = 32

    public var kind: Kind
    public var frames: UInt16
    public var sequence: UInt32
    public var firstFrame: UInt64
    public var sentAtNanos: UInt64
    public var sampleRate: UInt32
    public var channels: UInt16
    public var payload: Data

    public init(kind: Kind, frames: UInt16, sequence: UInt32, firstFrame: UInt64, sentAtNanos: UInt64,
                sampleRate: UInt32, channels: UInt16, payload: Data) {
        self.kind = kind
        self.frames = frames
        self.sequence = sequence
        self.firstFrame = firstFrame
        self.sentAtNanos = sentAtNanos
        self.sampleRate = sampleRate
        self.channels = channels
        self.payload = payload
    }

    public func encoded() -> Data {
        var d = Data(capacity: Self.headerSize + payload.count)
        d.append(Self.version)
        d.append(kind.rawValue)
        d.appendLE(frames)
        d.appendLE(sequence)
        d.appendLE(firstFrame)
        d.appendLE(sentAtNanos)
        d.appendLE(sampleRate)
        d.appendLE(channels)
        d.appendLE(UInt16(0))
        d.append(payload)
        return d
    }

    public enum DecodeError: Error, Equatable { case short, version(UInt8), kind(UInt8) }

    public init(decoding d: Data) throws {
        guard d.count >= Self.headerSize else { throw DecodeError.short }
        let b = [UInt8](d.prefix(Self.headerSize))
        guard b[0] == Self.version else { throw DecodeError.version(b[0]) }
        guard let kind = Kind(rawValue: b[1]) else { throw DecodeError.kind(b[1]) }
        self.kind = kind
        frames = b.le(2)
        sequence = b.le(4)
        firstFrame = b.le(8)
        sentAtNanos = b.le(16)
        sampleRate = b.le(24)
        channels = b.le(28)
        payload = Data(d.dropFirst(Self.headerSize))
    }
}

/// The config frame's payload: the format, then the encoder's magic cookie.
public struct StreamConfig: Equatable, Sendable {
    public var format: AudioFormat
    public var magicCookie: Data

    public init(format: AudioFormat, magicCookie: Data) {
        self.format = format
        self.magicCookie = magicCookie
    }

    public func frame(sentAtNanos: UInt64) -> StudioFrame {
        var p = Data()
        p.appendLE(format.framesPerPacket)
        p.append(magicCookie)
        return StudioFrame(kind: .config, frames: UInt16(format.framesPerPacket), sequence: 0, firstFrame: 0,
                           sentAtNanos: sentAtNanos, sampleRate: UInt32(format.sampleRate),
                           channels: UInt16(format.channels), payload: p)
    }

    public init(frame: StudioFrame) throws {
        guard frame.kind == .config, frame.payload.count >= 4 else { throw StudioFrame.DecodeError.short }
        let b = [UInt8](frame.payload)
        let fpp: UInt32 = b.le(0)
        format = AudioFormat(sampleRate: Double(frame.sampleRate), channels: UInt32(frame.channels), framesPerPacket: fpp)
        magicCookie = Data(b.dropFirst(4))
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func le<T: FixedWidthInteger>(_ offset: Int) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v |= T(self[offset + i]) << (8 * i) }
        return v
    }
}
