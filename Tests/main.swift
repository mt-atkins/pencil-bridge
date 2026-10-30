import Foundation
import Network
import AppKit
import CoreImage.CIFilterBuiltins
import Security

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
    let window = WindowTarget(id: 12, pid: 123, app: "Drawing app", title: "Canvas", bundleID: "test.draw",
                              x: -1000, y: 40, width: 800, height: 600)
    check(window.valid && window.rect.minX == -1000, "window mapping accepts secondary displays with negative coordinates")
    check(window.permits(frontPID: 123, frontWindow: 12), "app lock allows its selected foreground window")
    check(!window.permits(frontPID: 456, frontWindow: 12), "app lock blocks a different foreground process")
    check(!window.permits(frontPID: 123, frontWindow: 13), "app lock blocks another window of the same app")
    check(!window.permits(frontPID: nil, frontWindow: nil), "app lock blocks an unavailable window")
    check(!WorkspaceState(locked: true).valid, "app lock cannot be enabled without a target")
    let paused = WorkspaceState(selected: window, locked: true, inputAllowed: false)
    var longTitle = window
    longTitle.title = String(repeating: "🎨", count: 100)
    longTitle.app = String(repeating: "🎨", count: 80)
    let busyWorkspace = WorkspaceState(windows: Array(repeating: longTitle, count: 12), selected: longTitle, locked: true)
    check(try PacketFramer.encode(Packet(kind: .welcome, workspace: busyWorkspace.forTransport)).count < PacketFramer.limit,
          "Unicode window titles are bounded to fit the input connection")
    var stateFramer = PacketFramer()
    let statePacket = try stateFramer.append(PacketFramer.encode(Packet(kind: .workspace, workspace: paused)))
    check(statePacket.first?.workspace == paused, "paused app lock survives transport without silently unlocking")
    let frame = PreviewFrame(windowID: 12, jpeg: Data(repeating: 42, count: 89_000))
    let encoded = try PacketFramer.encode(Packet(kind: .preview, preview: frame))
    check(rejected(encoded), "preview images cannot enter the latency-sensitive input connection")
    var previewFramer = PacketFramer(allowsPreview: true)
    var frames: [Packet] = []
    for start in stride(from: 0, to: encoded.count, by: 7000) {
        frames += try previewFramer.append(encoded.subdata(in: start..<min(encoded.count, start + 7000)))
    }
    check(frames.first?.preview?.jpeg == frame.jpeg, "large ghost image survives fragmented preview transport")
    check(!PreviewFrame(windowID: 12, jpeg: Data(repeating: 0, count: 90_001)).valid, "oversized preview image rejected")
    var malicious = PacketFramer(allowsPreview: true)
    do {
        _ = try malicious.append(PacketFramer.encode(Packet(kind: .context, app: AppContext(name: String(repeating: "x", count: 9000), bundleID: "test"))))
        check(false, "preview channel must retain small limits for input metadata")
    } catch { check(true, "preview channel retains small limits for input metadata") }
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
    check(queue.pop()?.inputSamples.last?.x == 1, "coalescing retains the latest position")
    check(queue.pop()?.sample?.phase == .up && queue.count == 0, "coalescing preserves button release")
    var marked = sample(.move)
    marked.strokeMoved = true
    _ = queue.append(Packet(kind: .sample, sample: marked))
    _ = queue.append(Packet(kind: .sample, sample: sample(.move)))
    check(queue.pop()?.inputSamples.last?.strokeMoved == true, "coalescing preserves pointer movement history")
    for _ in 0..<32 { _ = queue.append(Packet(kind: .hello)) }
    check(!queue.append(Packet(kind: .hello)) && queue.count == 32, "non-coalescible input queue is bounded")
}

func tabletChecks() throws {
    check(Bridge.validJoinCode("0042") && Bridge.validJoinCode("9999"), "four-digit codes preserve leading zeros")
    check(!Bridge.validJoinCode("123") && !Bridge.validJoinCode("12345") && !Bridge.validJoinCode("１２３４") && !Bridge.validJoinCode("ABCD"), "manual codes require exactly four ASCII digits")
    check((0..<100).allSatisfy { _ in Bridge.validJoinCode(Bridge.newJoinCode()) }, "generated join codes are four digits")
    var limiter = PairingAttemptLimiter()
    check((0..<5).allSatisfy { limiter.allow(at: Double($0)) }, "manual pairing allows five attempts")
    check(!limiter.allow(at: 59) && limiter.allow(at: 60), "manual pairing throttle expires after a minute")
    let ticket = PairingTicket.create()
    check(PairingTicket(url: ticket.url) == ticket, "QR pairing payload round trip")
    check(ticket.secret.count == 64 && ticket.secret != Bridge.newJoinCode(), "QR pairing uses a separate long secret")
    check(PairingTicket(url: ticket.url + "&key=" + ticket.secret) == nil, "duplicate QR keys rejected")
    check(PairingTicket(url: ticket.url.replacingOccurrences(of: "pencilbridge:", with: "https:")) == nil, "unrelated QR URLs rejected")
    check(PairingTicket(url: ticket.url.replacingOccurrences(of: "v=2", with: "v=99")) == nil, "unsupported QR versions rejected")
    check(PairingTicket(url: ticket.url + "#fragment") == nil && PairingTicket(url: "pencilbridge://pair?v=2&name=Mac&key=1234") == nil, "invalid QR credentials rejected")
    let generator = CIFilter.qrCodeGenerator()
    generator.message = Data(ticket.url.utf8); generator.correctionLevel = "M"
    let qr = generator.outputImage!.transformed(by: CGAffineTransform(scaleX: 5, y: 5))
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
    check((detector.features(in: qr).first as? CIQRCodeFeature)?.messageString == ticket.url, "displayed QR image decodes to the exact pairing ticket")
    let area = TabletMapping.area(width: 1024, height: 600, aspect: 16.0 / 9)
    check(abs(area.width / 1920 - area.height / 1080) < 0.00001 && area.y > 0, "active area preserves display proportions")
    let portrait = TabletMapping.area(width: 768, height: 900, aspect: 16.0 / 9)
    check(portrait.width == 768 && portrait.height == 432 && portrait.y == 234, "portrait iPad uses a centered proportional area")
    check(TabletMapping.area(width: .infinity, height: 600, aspect: 1).width == 0, "invalid mapping geometry rejected")
    check(PressureFeel.light.apply(0.4) > 0.4 && PressureFeel.firm.apply(0.4) < 0.4, "tip feel changes pressure response")
    check(PressureFeel.allCases.allSatisfy { $0.apply(0) == 0 && $0.apply(1) == 1 && $0.apply(.nan) == 0 }, "pressure curves retain endpoints and reject nonfinite values")
    var pen = sample(.move)
    pen.tiltX = 0.4; pen.tiltY = -0.3
    let event = PenEvents.mouse(type: .leftMouseDragged, point: CGPoint(x: 10, y: 20), source: nil, number: 7, sample: pen)!
    let native = NSEvent(cgEvent: event)!
    check(event.getIntegerValueField(.mouseEventSubtype) == 1 && native.subtype == .tabletPoint, "pen movement is a native tablet-point mouse subtype")
    // Mouse pressure is quantized to 8 bits; the tablet field retains 16-bit precision.
    check(abs(Double(native.pressure) - 0.7) <= 1.0 / 255, "AppKit receives normalized pen pressure at native mouse-event precision")
    check(abs(event.getDoubleValueField(.tabletEventPointPressure) - 0.7) <= 1.0 / 65535, "tablet pressure field retains high-resolution pressure")
    check(abs(native.tilt.x - 0.4) < 0.001 && abs(native.tilt.y + 0.3) < 0.001, "AppKit receives pen tilt")
    check(event.getIntegerValueField(.tabletEventDeviceID) == PenEvents.deviceID, "tablet events share a stable device identifier")
    let lifted = PenEvents.mouse(type: .leftMouseUp, point: .zero, source: nil, number: 7, sample: pen)!
    check(lifted.getDoubleValueField(.tabletEventPointPressure) == 0 && lifted.getIntegerValueField(.tabletEventPointButtons) == 0, "pen lift releases pressure and tip button")
    let right = PenEvents.mouse(type: .rightMouseDown, point: .zero, source: nil, number: 8, clickCount: 2)!
    check(right.getIntegerValueField(.mouseEventButtonNumber) == 1 && right.getIntegerValueField(.mouseEventClickState) == 2, "finger secondary and double clicks use native button fields")
    check(right.getIntegerValueField(.mouseEventSubtype) == 0, "finger input remains ordinary mouse input")
    let proximity = PenEvents.proximity(enter: true, point: .zero, source: nil)!
    check(proximity.type == .tabletProximity && proximity.getIntegerValueField(.tabletProximityEventEnterProximity) == 1, "pen contact announces tablet proximity")
    check(PenEvents.proximity(enter: false, point: .zero, source: nil)!.getIntegerValueField(.tabletProximityEventEnterProximity) == 0, "pen release exits proximity")
    var state = PointerState()
    check(state.consume(sample(.down, 0.2, 0.3, .pan)) == [.move(0.2, 0.3), .down(0.2, 0.3)], "pan mode starts a draggable contact")
    check(state.consume(sample(.cancel, 0.5, 0.5, .pan)) == [.up(0.2, 0.3)], "cancelled pan releases its mouse contact")
    pen.tiltX = .infinity
    check(!pen.valid, "nonfinite tilt is rejected")
    pen.tiltX = 1.1
    check(!pen.valid, "out-of-range tilt is rejected")
    check(rejected(try PacketFramer.encode(Packet(kind: .control, control: TabletControl(action: .scroll, dx: 9999)))), "oversized finger deltas rejected")
    check(rejected(try PacketFramer.encode(Packet(kind: .control))), "missing shortcut command rejected")
    var queue = OutboundBuffer()
    _ = queue.append(Packet(kind: .control, control: TabletControl(action: .dragBegin)))
    for _ in 0..<20 { _ = queue.append(Packet(kind: .control, control: TabletControl(action: .relativeMove, dx: 2, dy: 3))) }
    _ = queue.append(Packet(kind: .control, control: TabletControl(action: .dragEnd)))
    check(queue.count == 3 && queue.pop()?.control?.action == .dragBegin, "finger drag coalescing preserves the press boundary")
    let movement = queue.pop()!.control!
    check(movement.dx == 40 && movement.dy == 60, "finger coalescing sums relative distance instead of dropping it")
    check(queue.pop()?.control?.action == .dragEnd, "finger drag coalescing preserves release")
    let binding = ShortcutBinding(key: 6, command: true, shift: true)
    check(PenEvents.flags(for: binding) == [.maskCommand, .maskShift], "app shortcut modifiers are explicit")
    check(try JSONDecoder().decode(ShortcutBinding.self, from: JSONEncoder().encode(binding)) == binding, "per-app bindings serialize without losing modifiers")
    check(!ShortcutBinding(key: 999).valid, "invalid shortcut keys are rejected")
    var fingers = FingerPointerState()
    check(fingers.move(to: CGPoint(x: 5, y: 6)).isEmpty, "finger movement before a gesture begins is ignored")
    check(fingers.begin(at: CGPoint(x: 100, y: 200), dragging: false).isEmpty && !fingers.held, "one-finger motion begins without pressing a button")
    check(fingers.move(to: CGPoint(x: 110, y: 220)) == [.move(110, 220)], "finger pointing uses relative cursor movement")
    check(fingers.reset().isEmpty && fingers.point == nil, "finger pointing ends without creating a click")
    check(fingers.begin(at: CGPoint(x: 110, y: 220), dragging: true) == [.down(110, 220)], "three-finger dragging presses at the current cursor")
    check(fingers.move(to: CGPoint(x: 120, y: 240)) == [.drag(120, 240)], "three-finger movement retains its held button")
    check(fingers.reset() == [.up(120, 240)] && !fingers.held, "disconnect or cancellation releases a finger drag at its last point")
    check(fingers.reset().isEmpty, "repeated finger drag cancellation is safe")
    _ = fingers.begin(at: .zero, dragging: true)
    check(fingers.begin(at: CGPoint(x: 3, y: 4), dragging: false) == [.up(0, 0)], "a new finger gesture releases an interrupted drag")
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
    let secret: String
    init(wrongCode: Bool, secret: String = "0042") { self.wrongCode = wrongCode; self.secret = secret }
    func run() throws {
        let code = secret
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
                let peer = Peer(NWConnection(host: "127.0.0.1", port: listener.port!, using: bridgeParameters(code: self.wrongCode ? "9999" : code)))
                self.client = peer
                peer.onReady = {
                    let metadata = peer.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    let suite = metadata.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue }
                    check(suite == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256), "pairing negotiates ephemeral key exchange and authenticated encryption")
                    peer.send(Packet(kind: .hello))
                }
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
    try tabletChecks()
    if !CommandLine.arguments.contains("--unit-only") {
        try NetworkCheck(wrongCode: false).run()
        try NetworkCheck(wrongCode: true).run()
        try NetworkCheck(wrongCode: false, secret: PairingTicket.create().secret).run()
    }
    print("\(checks) checks passed")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
