import Foundation
import Network

var checks = 0
func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
    print("PASS: \(message)")
}
func rejected(_ data: Data) -> Bool {
    var framer = PacketFramer()
    do { _ = try framer.append(data); return false } catch { return true }
}
func sample(_ phase: InputPhase, _ x: Double = 0.2, _ y: Double = 0.3, _ mode: InputMode = .draw) -> PencilSample {
    PencilSample(phase: phase, x: x, y: y, pressure: 0.7, mode: mode)
}

func unitChecks() throws {
    check(Bridge.normalizedCode("abCD-1234 ef56") == "ABCD1234EF56", "pairing code normalization")
    let bytes = try PacketFramer.encode(Packet(kind: .sample, sample: sample(.down)))
    var framer = PacketFramer()
    var output: [Packet] = []
    for byte in bytes { output += try framer.append(Data([byte])) }
    check(output.count == 1 && output[0].sample?.phase == .down, "byte-by-byte TCP fragmentation")
    let together = try framer.append(bytes + bytes + bytes)
    check(together.count == 3, "multiple packets in a single read")
    check(rejected(Data(repeating: 65, count: PacketFramer.limit + 1)), "oversized incomplete frame rejected")
    check(rejected(Data(repeating: 65, count: PacketFramer.limit + 1) + Data([10])), "oversized complete frame rejected")
    check(rejected(Data("garbage\n".utf8)), "malformed JSON rejected")
    check(rejected(Data("{\"kind\":\"hello\",\"version\":99}\n".utf8)), "incompatible protocol rejected")
    check(rejected(try PacketFramer.encode(Packet(kind: .sample, sample: sample(.move, 1.1)))), "out-of-range coordinates rejected")
    check(rejected(try PacketFramer.encode(Packet(kind: .sample))), "missing sample rejected")
    check(!sample(.down, .nan).valid && !sample(.down, .infinity).valid, "nonfinite coordinates rejected")
    var pointer = PointerState()
    check(pointer.consume(sample(.move)).isEmpty, "stray motion ignored")
    check(pointer.consume(sample(.down)) == [.move(0.2, 0.3), .down(0.2, 0.3)], "draw starts mouse press")
    check(pointer.consume(sample(.move, 0.4, 0.5)) == [.drag(0.4, 0.5)], "draw moves as drag")
    check(pointer.consume(sample(.up, 0.4, 0.5)) == [.up(0.4, 0.5)] && !pointer.held, "lifting Pencil releases button")
    _ = pointer.consume(sample(.down))
    check(pointer.reset() == [.up(0.2, 0.3)] && !pointer.held, "disconnect releases held button")
    check(pointer.reset().isEmpty, "repeated disconnect is safe")
    _ = pointer.consume(sample(.down))
    check(pointer.consume(sample(.cancel)) == [.up(0.2, 0.3)], "cancel releases held button")
    _ = pointer.consume(sample(.down, 0.8, 0.9))
    check(pointer.consume(sample(.cancel, 0.5, 0.5)) == [.up(0.8, 0.9)], "cancel preserves the last cursor location")
    _ = pointer.consume(sample(.down, 0.8, 0.9))
    check(pointer.consume(sample(.down, 0.1, 0.1)) == [.up(0.8, 0.9), .move(0.1, 0.1), .down(0.1, 0.1)], "new stroke releases a previous unfinished stroke")
    _ = pointer.reset()
    check(pointer.consume(sample(.down, 0.2, 0.3, .pointer)) == [.move(0.2, 0.3)], "pointer contact moves without pressing")
    check(pointer.consume(sample(.up, 0.2, 0.3, .pointer)) == [.down(0.2, 0.3), .up(0.2, 0.3)], "pointer tap clicks")
    _ = pointer.consume(sample(.down, 0.2, 0.3, .pointer))
    check(pointer.consume(sample(.move, 0.6, 0.7, .pointer)) == [.move(0.6, 0.7)], "pointer stroke moves cursor")
    check(pointer.consume(sample(.up, 0.6, 0.7, .pointer)).isEmpty, "pointer movement does not accidentally click")
    _ = pointer.consume(sample(.down, 0.2, 0.3, .pointer))
    var returned = sample(.up, 0.2, 0.3, .pointer)
    returned.strokeMoved = true
    check(pointer.consume(returned).isEmpty, "coalesced out-and-back movement does not become a click")
    var queue = OutboundBuffer()
    check(queue.append(Packet(kind: .sample, sample: sample(.down))), "press enters outbound queue")
    for index in 0...1000 {
        _ = queue.append(Packet(kind: .sample, sample: sample(.move, Double(index) / 1000, 0.5)))
    }
    check(queue.count == 2, "one thousand queued positions reduce to the newest position")
    _ = queue.append(Packet(kind: .sample, sample: sample(.up, 1, 0.5)))
    check(queue.pop()?.sample?.phase == .down, "coalescing preserves press ordering")
    check(queue.pop()?.sample?.x == 1, "coalescing retains the latest position")
    check(queue.pop()?.sample?.phase == .up && queue.count == 0, "coalescing preserves button release")
    var marked = sample(.move)
    marked.strokeMoved = true
    _ = queue.append(Packet(kind: .sample, sample: marked))
    _ = queue.append(Packet(kind: .sample, sample: sample(.move)))
    check(queue.pop()?.sample?.strokeMoved == true, "coalescing preserves pointer movement history")
    for _ in 0..<32 { _ = queue.append(Packet(kind: .hello)) }
    check(!queue.append(Packet(kind: .hello)) && queue.count == 32, "non-coalescible input queue is bounded")
}

final class NetworkCheck {
    var listener: NWListener?
    var server: Peer?
    var client: Peer?
    var completed = false
    var welcomed = false
    var measured = false
    var state = PointerState()
    var actions: [PointerAction] = []
    let wrongCode: Bool
    init(wrongCode: Bool) { self.wrongCode = wrongCode }
    func run() throws {
        let code = "123456ABCDEF"
        let listener = try NWListener(using: bridgeParameters(code: code), on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection)
            self.server = peer
            peer.onPacket = { packet in
                if packet.kind == .hello { peer.send(Packet(kind: .welcome)) }
                if let sample = packet.sample {
                    self.actions += self.state.consume(sample)
                    if sample.phase == .move { self.client?.close("Simulated network loss") }
                }
            }
            peer.onClose = { reason in
                self.actions += self.state.reset()
                if !self.wrongCode {
                    print("Network close: \(reason); actions: \(self.actions)")
                    check(self.actions == [.move(0.2, 0.3), .down(0.2, 0.3), .drag(0.4, 0.5), .up(0.4, 0.5)], "TLS input round trip and release after network loss")
                    self.completed = true
                }
            }
            peer.start()
        }
        listener.stateUpdateHandler = { status in
            switch status {
            case .ready:
                let peer = Peer(NWConnection(host: "127.0.0.1", port: listener.port!, using: bridgeParameters(code: self.wrongCode ? "WRONGCODE123" : code)))
                self.client = peer
                peer.onReady = { peer.send(Packet(kind: .hello)) }
                peer.onPacket = { packet in
                    if packet.kind == .welcome {
                        self.welcomed = true
                        peer.send(Packet(kind: .heartbeat, ping: ProcessInfo.processInfo.systemUptime))
                    }
                }
                peer.onLatency = { ms in
                    guard self.welcomed, !self.measured else { return }
                    self.measured = true
                    check(ms >= 0 && ms < 5000, "connection round-trip measured across encrypted transport")
                    peer.send(Packet(kind: .sample, sample: sample(.down)))
                    peer.send(Packet(kind: .sample, sample: sample(.move, 0.4, 0.5)))
                }
                peer.onClose = { reason in
                    print("Client close: \(reason)")
                    if self.wrongCode {
                        check(!self.welcomed, "wrong pairing code cannot establish TLS session")
                        self.completed = true
                    }
                }
                peer.start()
            case .failed(let error): fputs("Listener failed: \(error)\n", stderr); exit(1)
            default: break
            }
        }
        listener.start(queue: .main)
        let deadline = Date().addingTimeInterval(12)
        while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(completed, wrongCode ? "wrong-code test completed" : "encrypted network test completed")
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        server?.onClose = nil; server?.close()
        client?.onClose = nil; client?.close()
    }
}

do {
    try unitChecks()
    if !CommandLine.arguments.contains("--unit-only") {
        try NetworkCheck(wrongCode: false).run()
        try NetworkCheck(wrongCode: true).run()
    }
    print("\(checks) checks passed")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
