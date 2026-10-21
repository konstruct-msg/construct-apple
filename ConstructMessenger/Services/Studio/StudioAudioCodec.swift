//
//  StudioAudioCodec.swift
//  Construct Messenger
//
//  The program audio's codecs for studio mode (vault `decisions/studio-mode-on-desktop.md`): FLAC
//  for the lossless mode and Opus at 510 kbit/s for the other, both through AudioToolbox, so the
//  two modes share one delivery path (a data channel) and neither goes through WebRTC's NetEQ,
//  which time-stretches on loss. No codec library: `AudioConverter` encodes both.
//
//  PCM on both ends is interleaved `Int32`, one 24-bit sample in the low 24 bits, sign-extended.
//  FLAC is given exactly that (shifted into the high bits, "24 valid bits in a 32-bit container")
//  and returns it bit for bit. Opus takes Float32, so it is converted at the edge; what comes back
//  is close, not equal, and arrives later by the codec's look-ahead.
//
//  Both encoders hold input back — FLAC releases nothing for the first packet it is given — so a
//  packet in does not mean a packet out: the converter is driven as a stream, and callers pair
//  released packets with the frame indices they queued, in order.
//

import AudioToolbox
import Foundation

struct StudioAudioFormat: Equatable, Sendable {
    enum Codec: Equatable, Sendable {
        case flac
        /// Bits per second; AudioToolbox's Opus accepts up to 512 000.
        case opus(bitRate: UInt32)
    }

    var codec: Codec
    var sampleRate: Double
    var channels: UInt32
    /// Frames per packet, and so per data-channel message.
    var framesPerPacket: UInt32

    /// FLAC 48 kHz / 24-bit stereo, 1024 frames (21.3 ms) a packet.
    static let lossless = StudioAudioFormat(codec: .flac, sampleRate: 48_000, channels: 2, framesPerPacket: 1024)
    /// Opus 510 kbit/s stereo, 960 frames (20 ms) — Opus has no 1024-frame packet.
    static let high = StudioAudioFormat(codec: .opus(bitRate: 510_000), sampleRate: 48_000, channels: 2,
                                        framesPerPacket: 960)

    var samplesPerPacket: Int { Int(framesPerPacket * channels) }

    /// What the program PCM is handed to the converter as.
    fileprivate var pcm: AudioStreamBasicDescription {
        switch codec {
        case .flac:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
                mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
        case .opus:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        }
    }

    fileprivate var compressed: AudioStreamBasicDescription {
        switch codec {
        case .flac:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatFLAC,
                mFormatFlags: kAppleLosslessFormatFlag_24BitSourceData, mBytesPerPacket: 0,
                mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels,
                mBitsPerChannel: 0, mReserved: 0)
        case .opus:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels,
                mBitsPerChannel: 0, mReserved: 0)
        }
    }
}

struct StudioCodecError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what): OSStatus \(status)" }
}

/// Full scale of a 24-bit sample.
let studioSampleFullScale = Float((1 << 23) - 1)

final class StudioAudioEncoder {
    let format: StudioAudioFormat
    private let converter: StreamingConverter
    private let maxPacketSize: UInt32

    init(format: StudioAudioFormat) throws {
        self.format = format
        converter = try StreamingConverter(from: format.pcm, to: format.compressed, what: "studio encoder")
        if case .opus(let bitRate) = format.codec {
            var rate = bitRate
            try check(AudioConverterSetProperty(converter.ref, kAudioConverterEncodeBitRate,
                                                UInt32(MemoryLayout<UInt32>.size), &rate), "Opus bit rate")
        }
        var size: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioConverterGetProperty(converter.ref, kAudioConverterPropertyMaximumOutputPacketSize,
                                            &propSize, &size), "max packet size")
        maxPacketSize = size
    }

    /// What the decoder needs before the first packet (FLAC's STREAMINFO; Opus's header). Empty
    /// when the encoder has none.
    func magicCookie() throws -> Data {
        var size: UInt32 = 0
        let info = AudioConverterGetPropertyInfo(converter.ref, kAudioConverterCompressionMagicCookie, &size, nil)
        guard info == noErr, size > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        try check(AudioConverterGetProperty(converter.ref, kAudioConverterCompressionMagicCookie, &size, &bytes),
                  "magic cookie")
        return Data(bytes.prefix(Int(size)))
    }

    /// Queue one packet of exactly `format.samplesPerPacket` samples; returns the compressed
    /// packets the encoder released, in order — possibly none.
    func encode(_ samples: [Int32]) throws -> [Data] {
        precondition(samples.count == format.samplesPerPacket, "a packet is exactly framesPerPacket frames")
        let bytes: [UInt8]
        switch format.codec {
        case .flac:
            bytes = samples.map { $0 << 8 }.withUnsafeBytes { [UInt8]($0) }
        case .opus:
            bytes = samples.map { Float($0) / studioSampleFullScale }.withUnsafeBytes { [UInt8]($0) }
        }
        converter.enqueue(bytes, units: format.framesPerPacket)
        return try converter.drain(capacity: maxPacketSize, outputPacketsPerCall: 1, compressedOutput: true)
    }
}

final class StudioAudioDecoder {
    let format: StudioAudioFormat
    private let converter: StreamingConverter

    init(format: StudioAudioFormat, magicCookie: Data) throws {
        self.format = format
        converter = try StreamingConverter(from: format.compressed, to: format.pcm, what: "studio decoder")
        if !magicCookie.isEmpty {
            var cookie = [UInt8](magicCookie)
            try check(AudioConverterSetProperty(converter.ref, kAudioConverterDecompressionMagicCookie,
                                                UInt32(cookie.count), &cookie), "set magic cookie")
        }
    }

    /// One compressed packet in; the PCM samples released, interleaved. A decoder that holds a
    /// packet back returns fewer here and catches up later, so callers treat this as a stream.
    func decode(_ packet: Data) throws -> [Int32] {
        converter.enqueue([UInt8](packet), units: 1)
        let capacity = UInt32(format.samplesPerPacket * 4)
        let chunks = try converter.drain(capacity: capacity, outputPacketsPerCall: format.framesPerPacket,
                                         compressedOutput: false)
        switch format.codec {
        case .flac:
            return chunks.flatMap { d in d.withUnsafeBytes { $0.bindMemory(to: Int32.self).map { $0 >> 8 } } }
        case .opus:
            return chunks.flatMap { d in
                d.withUnsafeBytes { raw in
                    raw.bindMemory(to: Float.self).map { Int32((max(-1, min(1, $0)) * studioSampleFullScale).rounded()) }
                }
            }
        }
    }
}

// MARK: - The converter as a stream

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw StudioCodecError(what: what, status: status) }
}

/// Returned by the input proc when nothing is queued. Any non-zero value works; AudioToolbox
/// passes it back out of `AudioConverterFillComplexBuffer` with whatever it could produce.
private let inputExhausted: OSStatus = 0x6578_6831 // 'exh1'

/// An `AudioConverter` fed from a queue. The buffer handed to the converter stays alive until it
/// asks for the next one — the lifetime AudioToolbox requires of input data.
private final class StreamingConverter {
    let ref: AudioConverterRef
    private let channels: UInt32
    private let compressedInput: Bool
    /// Input units per queued chunk: frames for PCM input, one packet for compressed input.
    private var queue: [(bytes: [UInt8], units: UInt32)] = []
    private var current: UnsafeMutableRawBufferPointer?
    /// Handed to the converter by address for compressed input, so it lives as long as we do.
    private let currentDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init(from: AudioStreamBasicDescription, to: AudioStreamBasicDescription, what: String) throws {
        var a = from, b = to
        var r: AudioConverterRef?
        try check(AudioConverterNew(&a, &b, &r), what)
        ref = r!
        channels = from.mChannelsPerFrame
        compressedInput = from.mFormatID != kAudioFormatLinearPCM
    }

    deinit {
        current?.deallocate()
        currentDescription.deallocate()
        AudioConverterDispose(ref)
    }

    func enqueue(_ bytes: [UInt8], units: UInt32) { queue.append((bytes, units)) }

    /// Pull output until the converter has nothing more to give from what is queued. `capacity`
    /// is one output call's buffer in bytes.
    func drain(capacity: UInt32, outputPacketsPerCall: UInt32, compressedOutput: Bool) throws -> [Data] {
        var produced: [Data] = []
        while true {
            var out = [UInt8](repeating: 0, count: Int(capacity))
            var packets = outputPacketsPerCall
            var description = AudioStreamPacketDescription()
            let me = Unmanaged.passUnretained(self).toOpaque()
            let status = out.withUnsafeMutableBytes { outRaw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: channels, mDataByteSize: capacity, mData: outRaw.baseAddress))
                if compressedOutput {
                    return AudioConverterFillComplexBuffer(ref, streamingInput, me, &packets, &list, &description)
                }
                return AudioConverterFillComplexBuffer(ref, streamingInput, me, &packets, &list, nil)
            }
            guard status == noErr || status == inputExhausted else {
                throw StudioCodecError(what: "convert", status: status)
            }
            if packets == 0 { return produced }
            if compressedOutput {
                let start = Int(description.mStartOffset)
                produced.append(Data(out[start..<start + Int(description.mDataByteSize)]))
            } else {
                // PCM: `packets` counts frames, and a short pull is a short buffer.
                produced.append(Data(out.prefix(Int(packets * channels * 4))))
            }
            if status == inputExhausted { return produced }
        }
    }

    fileprivate func supply(
        _ ioPackets: UnsafeMutablePointer<UInt32>,
        _ ioData: UnsafeMutablePointer<AudioBufferList>,
        _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        current?.deallocate()
        current = nil
        guard !queue.isEmpty else {
            ioPackets.pointee = 0
            return inputExhausted
        }
        let next = queue.removeFirst()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: next.bytes.count, alignment: 16)
        next.bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        current = buffer
        ioPackets.pointee = next.units
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = buffer.baseAddress
        ioData.pointee.mBuffers.mDataByteSize = UInt32(next.bytes.count)
        ioData.pointee.mBuffers.mNumberChannels = channels
        if compressedInput {
            currentDescription.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(next.bytes.count))
            outDescription?.pointee = currentDescription
        }
        return noErr
    }
}

private func streamingInput(
    _ converter: AudioConverterRef,
    _ ioPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    Unmanaged<StreamingConverter>.fromOpaque(context!).takeUnretainedValue().supply(ioPackets, ioData, outDescription)
}
