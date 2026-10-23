import Foundation
import StudioCore
import StudioLink

let usage = """
studio-spike — the studio mode's program-audio path, without the app (vault: todo/205).

  loopback [--seconds N] [--buffer S] [--play]
      Both ends in this process over host candidates: the test signal, FLAC 48/24, a WebRTC data
      channel. Checks every sample against the test signal; reports transport latency, bitrate.

  send --listen PORT [--source tone | --source app:BUNDLE_ID] [--dump FILE.s32] [--seconds N]
      Host. Waits for `recv` on PORT, offers, then streams. `app:com.cockos.reaper` captures that
      process's output with a Core Audio tap (asks for the audio-capture permission once).

  recv --connect HOST:PORT [--verify] [--play] [--buffer S] [--dump FILE.s32] [--seconds N]
      Listener. --verify checks against the test signal (only with --source tone).
      With --dump on both ends, `cmp sent.s32 recv.s32` is the bit-exactness check for a DAW;
      cmp reporting EOF on the shorter file means everything received matched.

  --stun stun:HOST:PORT (both ends, repeatable) adds a STUN server, for two machines behind NAT;
  without it only host candidates are offered (loopback, one LAN). There is no TURN here.
  --buffer is the playout depth in seconds (default 0.4). Stats print every 5 s.
  SDP goes over plain TCP: use on a LAN you trust, not across the internet.
"""

struct Args {
    var command = ""
    var seconds: Double = 0
    var buffer = 0.4
    var play = false
    var verify = false
    var listen: UInt16?
    var connect: (String, UInt16)?
    var source = "tone"
    var dump: String?
    var stun: [String] = []

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        command = it.next() ?? ""
        while let a = it.next() {
            switch a {
            case "--seconds": seconds = Double(it.next() ?? "") ?? 0
            case "--buffer": buffer = Double(it.next() ?? "") ?? 0.4
            case "--play": play = true
            case "--verify": verify = true
            case "--listen": listen = UInt16(it.next() ?? "")
            case "--connect":
                let parts = (it.next() ?? "").split(separator: ":")
                if parts.count == 2, let p = UInt16(parts[1]) { connect = (String(parts[0]), p) }
            case "--source": source = it.next() ?? "tone"
            case "--dump": dump = it.next()
            case "--stun": stun.append(it.next() ?? "")
            default: fail("unknown argument \(a)")
            }
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n\n\(usage)\n".data(using: .utf8)!)
    exit(2)
}

func log(_ s: String) {
    let t = String(format: "%8.2f", Double(nowNanos() - startNanos) / 1e9)
    print("[\(t)] \(s)")
    fflush(stdout)
}

let startNanos = nowNanos()

/// Paces the test signal at real time on the host clock.
final class ToneSource {
    let format: AudioFormat
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "studio.tone", qos: .userInteractive))
    private var next: UInt64 = 0
    private var origin: UInt64 = 0
    var onPacket: (([Int32], UInt64) -> Void)?

    init(format: AudioFormat) { self.format = format }

    func start() {
        origin = nowNanos()
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        let due = UInt64(Double(nowNanos() - origin) / 1e9 * format.sampleRate)
        while next + UInt64(format.framesPerPacket) <= due {
            onPacket?(TestSignal.samples(firstFrame: next, format: format), next)
            next += UInt64(format.framesPerPacket)
        }
    }

    func stop() { timer.cancel() }
}

/// Every 5 s: what arrived, how full the buffer is, the drift so far, latency and RTT.
final class Stats {
    private var fills: [(Double, Double)] = []
    private var lastBytes = 0
    private var lastAt = nowNanos()

    func report(receiver: ProgramReceiver, sender: ProgramSender?) {
        let now = nowNanos()
        let dt = Double(now - lastAt) / 1e9
        lastAt = now
        var parts: [String] = []
        let kbps = Double((receiver.bytesReceived - lastBytes) * 8) / dt / 1000
        lastBytes = receiver.bytesReceived
        parts.append(String(format: "rx %.0f kbit/s", kbps))
        if let b = receiver.buffer {
            let t = Double(now - startNanos) / 1e9
            if b.isPlaying { fills.append((t, b.fillSeconds)) }
            parts.append(String(format: "fill %.3f s", b.fillSeconds))
            if let s = slope(fills), fills.count >= 6 { parts.append(String(format: "drift %+.1f ppm", s * 1e6)) }
            parts.append("underruns \(b.underruns) gapFrames \(b.gapFrames)")
        }
        if receiver.sequenceGaps > 0 { parts.append("seqGaps \(receiver.sequenceGaps)") }
        if receiver.samplesCompared > 0 {
            parts.append("verified \(receiver.samplesCompared) mismatched \(receiver.samplesMismatched)")
        }
        let (transport, rtt) = receiver.snapshot()
        if let sender {
            parts.append("sent \(sender.packetsSent) dropped \(sender.packetsDropped)")
            if let p50 = percentile(transport, 50), let p99 = percentile(transport, 99) {
                parts.append(String(format: "transport p50 %.1f ms p99 %.1f ms", p50 / 1e6, p99 / 1e6))
            }
        }
        if let r50 = percentile(rtt, 50), let r99 = percentile(rtt, 99) {
            parts.append(String(format: "rtt p50 %.1f ms p99 %.1f ms", r50 / 1e6, r99 / 1e6))
        }
        log(parts.joined(separator: " | "))
    }
}

func runFor(_ seconds: Double, every: @escaping () -> Void) async {
    let deadline = seconds > 0 ? nowNanos() + UInt64(seconds * 1e9) : UInt64.max
    while nowNanos() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        every()
    }
}

func waitOpen(_ peer: StudioPeer) async {
    while !peer.isOpen { try? await Task.sleep(nanoseconds: 20_000_000) }
}

let args = Args(CommandLine.arguments)
let format = AudioFormat()
var keepAlive: [AnyObject] = []

func startSource(into sender: ProgramSender) throws -> AnyObject {
    if args.source == "tone" {
        let tone = ToneSource(format: format)
        tone.onPacket = { sender.push($0, firstFrame: $1) }
        tone.start()
        return tone
    }
    guard args.source.hasPrefix("app:") else { fail("--source is tone or app:BUNDLE_ID") }
    let tap = try ProcessTapSource(bundleIdentifier: String(args.source.dropFirst(4)))
    guard tap.format == sender.format else {
        fail("the output device runs at \(tap.format.sampleRate) Hz; set it to 48000 Hz in Audio MIDI Setup")
    }
    tap.onPacket = { sender.push($0, firstFrame: $1) }
    try tap.start()
    log("capturing \(tap.processDescription) at \(tap.format.sampleRate) Hz")
    return tap
}

func main() async throws {
    switch args.command {
    case "loopback":
        let host = StudioPeer(role: .offerer)
        let guest = StudioPeer(role: .answerer)
        let offer = try await host.makeOffer()
        let answer = try await guest.answer(offer: offer)
        try await host.accept(answer: answer)
        let receiver = try ProgramReceiver(peer: guest, verify: .testSignal, bufferSeconds: args.buffer)
        guest.onMessage = { receiver.handle($0) }
        let sender = try ProgramSender(peer: host, format: format)
        host.onMessage = { if (try? StudioFrame(decoding: $0))?.kind == .pong { receiver.handle($0) } }
        receiver.onConfig = { _, buffer in
            if args.play { keepAlive.append(try! ProgramOutput(buffer: buffer)) }
        }
        await waitOpen(host)
        log("open: \(await host.transportSummary())")
        try sender.sendConfig()
        keepAlive.append(try startSource(into: sender))
        let stats = Stats()
        await runFor(args.seconds > 0 ? args.seconds : 30) {
            sender.ping()
            stats.report(receiver: receiver, sender: sender)
        }
        let ok = receiver.samplesCompared > 0 && receiver.samplesMismatched == 0
        log(ok ? "PASS: every received sample matched" : "FAIL: compared \(receiver.samplesCompared), mismatched \(receiver.samplesMismatched)")
        exit(ok ? 0 : 1)

    case "send":
        guard let port = args.listen else { fail("send needs --listen PORT") }
        log("waiting for recv on port \(port)")
        let signalling = try await Signalling.listen(port: port)
        let peer = StudioPeer(role: .offerer, stunServers: args.stun)
        peer.onLog = { log($0) }
        try await signalling.send(try await peer.makeOffer())
        try await peer.accept(answer: try await signalling.receive())
        await waitOpen(peer)
        log("open: \(await peer.transportSummary())")
        let sender = try ProgramSender(peer: peer, format: format, dumpPath: args.dump)
        // The listener measures the round trip; the host only answers.
        peer.onMessage = { data in
            guard var f = try? StudioFrame(decoding: data), f.kind == .ping else { return }
            f.kind = .pong
            peer.send(f.encoded())
        }
        try sender.sendConfig()
        keepAlive.append(try startSource(into: sender))
        await runFor(args.seconds) {
            log("sent \(sender.packetsSent) dropped \(sender.packetsDropped) bytes \(sender.bytesSent) buffered \(peer.bufferedAmount)")
            if let tap = keepAlive.last as? ProcessTapSource, tap.packets > 0, tap.silentPackets == tap.packets {
                log("tap delivers only silence: is the DAW playing, and is audio capture allowed in System Settings › Privacy & Security?")
            }
        }

    case "recv":
        guard let (host, port) = args.connect else { fail("recv needs --connect HOST:PORT") }
        let signalling = try await Signalling.connect(host: host, port: port)
        let peer = StudioPeer(role: .answerer, stunServers: args.stun)
        peer.onLog = { log($0) }
        let receiver = try ProgramReceiver(peer: peer, verify: args.verify ? .testSignal : .none,
                                           bufferSeconds: args.buffer, dumpPath: args.dump)
        peer.onMessage = { receiver.handle($0) }
        receiver.onConfig = { format, buffer in
            log("stream: \(format.sampleRate) Hz, \(format.channels) ch, \(format.framesPerPacket) frames/packet")
            if args.play { keepAlive.append(try! ProgramOutput(buffer: buffer)) }
        }
        try await signalling.send(try await peer.answer(offer: try await signalling.receive()))
        await waitOpen(peer)
        log("open: \(await peer.transportSummary())")
        let stats = Stats()
        await runFor(args.seconds) {
            peer.send(StudioFrame(kind: .ping, frames: 0, sequence: 0, firstFrame: 0, sentAtNanos: nowNanos(),
                                  sampleRate: 0, channels: 0, payload: Data()).encoded())
            stats.report(receiver: receiver, sender: nil)
        }

    default:
        print(usage)
        exit(args.command.isEmpty || args.command == "help" ? 0 : 2)
    }
}

try await main()
