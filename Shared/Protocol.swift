import Foundation

enum Bridge {
    static let service = "_pencilbridge._tcp"
    static let version = 1
    static func normalizedCode(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}

enum InputPhase: String, Codable { case down, move, up, cancel }
enum InputMode: String, Codable, CaseIterable { case draw, pointer }

struct PencilSample: Codable {
    var phase: InputPhase
    var x: Double
    var y: Double
    var pressure: Double
    var mode: InputMode
    var strokeMoved: Bool? = nil
    var valid: Bool {
        x.isFinite && y.isFinite && pressure.isFinite &&
        (0...1).contains(x) && (0...1).contains(y) && (0...1).contains(pressure)
    }
}

struct Packet: Codable {
    enum Kind: String, Codable { case hello, welcome, sample, heartbeat, goodbye }
    var kind: Kind
    var version: Int = Bridge.version
    var sample: PencilSample? = nil
    var ping: Double? = nil
    var pong: Double? = nil
}

// Keep the newest position while preserving every press, lift and cancellation.
// A slow connection must not turn a live cursor into a replay of old positions.
struct OutboundBuffer {
    private var packets: [Packet] = []
    var count: Int { packets.count }
    mutating func append(_ packet: Packet) -> Bool {
        if packet.kind == .sample, packet.sample?.phase == .move,
           let previous = packets.last, previous.kind == .sample,
           previous.sample?.phase == .move, previous.sample?.mode == packet.sample?.mode {
            var newest = packet
            if previous.sample?.strokeMoved == true { newest.sample?.strokeMoved = true }
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
                  packet.kind != .sample || packet.sample?.valid == true else {
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
            if sample.mode == .draw {
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
