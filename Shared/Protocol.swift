import Foundation

enum Bridge {
    static let service = "_pencilbridge._tcp"
    static let version = 2
    static let qrService = "_pencilqr._tcp"
    static func newJoinCode() -> String { String(format: "%04d", Int.random(in: 0..<10000)) }
    static func validJoinCode(_ text: String) -> Bool {
        text.count == 4 && text.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func normalizedCode(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}

enum InputPhase: String, Codable { case down, move, up, cancel }
enum InputMode: String, Codable, CaseIterable { case draw, pointer, pan }

struct PencilSample: Codable {
    var phase: InputPhase
    var x: Double
    var y: Double
    var pressure: Double
    var mode: InputMode
    var strokeMoved: Bool? = nil
    var tiltX: Double? = nil
    var tiltY: Double? = nil
    var valid: Bool {
        x.isFinite && y.isFinite && pressure.isFinite &&
        (0...1).contains(x) && (0...1).contains(y) && (0...1).contains(pressure) &&
        [tiltX, tiltY].allSatisfy { $0 == nil || ($0!.isFinite && (-1...1).contains($0!)) }
    }
}

struct Packet: Codable {
    enum Kind: String, Codable { case hello, welcome, sample, heartbeat, goodbye, control, display, context }
    var kind: Kind
    var version: Int = Bridge.version
    var sample: PencilSample? = nil
    var ping: Double? = nil
    var pong: Double? = nil
    var display: DisplayInfo? = nil
    var control: TabletControl? = nil
    var samples: [PencilSample]? = nil
    var app: AppContext? = nil
    var inputSamples: [PencilSample] { samples ?? sample.map { [$0] } ?? [] }
    var onlyMovement: Bool { kind == .sample && !inputSamples.isEmpty && inputSamples.allSatisfy { $0.phase == .move } }
}

// Keep the newest position while preserving every press, lift and cancellation.
// A slow connection must not turn a live cursor into a replay of old positions.
struct OutboundBuffer {
    private var packets: [Packet] = []
    var count: Int { packets.count }
    mutating func append(_ packet: Packet) -> Bool {
        if packet.kind == .control, let control = packet.control,
           [.relativeMove, .scroll].contains(control.action),
           let previous = packets.last, previous.kind == .control,
           let old = previous.control, old.action == control.action {
            let sum = TabletControl(action: control.action, dx: old.dx + control.dx, dy: old.dy + control.dy)
            if sum.valid {
                var combined = packet; combined.control = sum
                packets[packets.count - 1] = combined
                return true
            }
        }
        if packet.onlyMovement, let previous = packets.last, previous.onlyMovement,
           previous.inputSamples.last?.mode == packet.inputSamples.first?.mode {
            var newest = packet
            var points = Array((previous.inputSamples + packet.inputSamples).suffix(packet.inputSamples.first?.mode == .pointer ? 1 : 16))
            if previous.inputSamples.contains(where: { $0.strokeMoved == true }) { points[points.count - 1].strokeMoved = true }
            newest.sample = nil
            newest.samples = points
            packets[packets.count - 1] = newest
            return true
        }
        guard packets.count < 32 else { return false }
        packets.append(packet)
        return true
    }
    mutating func pop() -> Packet? {
        packets.isEmpty ? nil : packets.removeFirst()
    }
}

// TCP is a byte stream: a read can contain part of a packet or several packets.
struct PacketFramer {
    private var buffer = Data()
    static let limit = 8192
    enum Failure: Error { case oversized, invalid }
    static func encode(_ packet: Packet) throws -> Data {
        var data = try JSONEncoder().encode(packet)
        data.append(10)
        return data
    }
    mutating func append(_ data: Data) throws -> [Packet] {
        buffer.append(data)
        var packets: [Packet] = []
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= Self.limit else {
                throw Failure.oversized
            }
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard let packet = try? JSONDecoder().decode(Packet.self, from: line),
                  packet.version == Bridge.version,
                  packet.kind != .sample || (!packet.inputSamples.isEmpty && packet.inputSamples.count <= 16 && packet.inputSamples.allSatisfy(\.valid)),
                  packet.kind != .control || packet.control?.valid == true,
                  packet.display == nil || packet.display?.valid == true,
                  packet.app == nil || packet.app?.valid == true else {
                throw Failure.invalid
            }
            packets.append(packet)
        }
        guard buffer.count <= Self.limit else { throw Failure.oversized }
        return packets
    }
}

enum PointerAction: Equatable {
    case move(Double, Double), down(Double, Double), drag(Double, Double), up(Double, Double)
}

// Independent of AppKit so input behavior can be tested without moving the real cursor.
struct PointerState {
    private(set) var held = false
    private var origin: (Double, Double)?
    private var moved = false
    private var last = (0.5, 0.5)
    mutating func reset() -> [PointerAction] {
        defer { held = false; origin = nil; moved = false }
        return held ? [.up(last.0, last.1)] : []
    }
    mutating func consume(_ sample: PencilSample) -> [PointerAction] {
        guard sample.valid else { return [] }
        let x = sample.x, y = sample.y
        switch sample.phase {
        case .cancel: return reset()
        case .down:
            var actions = reset()
            last = (x, y)
            origin = (x, y)
            if sample.mode != .pointer {
                held = true
                actions += [.move(x, y), .down(x, y)]
            } else { actions.append(.move(x, y)) }
            return actions
        case .move:
            guard let start = origin else { return [] }
            last = (x, y)
            if sample.strokeMoved == true || hypot(x - start.0, y - start.1) > 0.012 { moved = true }
            return [held ? .drag(x, y) : .move(x, y)]
        case .up:
            guard origin != nil else { return [] }
            last = (x, y)
            let click = !held && !moved && sample.strokeMoved != true
            var actions = reset()
            if click { actions += [.down(x, y), .up(x, y)] }
            return actions
        }
    }
}
