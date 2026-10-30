import Foundation

struct PairingTicket: Equatable {
    let serviceName: String
    let secret: String
    var url: String {
        var parts = URLComponents()
        parts.scheme = "pencilbridge"; parts.host = "pair"
        parts.queryItems = [.init(name: "v", value: "2"), .init(name: "name", value: serviceName), .init(name: "key", value: secret)]
        return parts.string!
    }
    init(serviceName: String, secret: String) { self.serviceName = serviceName; self.secret = secret }
    init?(url: String) {
        guard url.utf8.count <= 512, let parts = URLComponents(string: url),
              parts.scheme == "pencilbridge", parts.host == "pair", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 3,
              Set(items.map(\.name)) == Set(["v", "name", "key"]),
              items.first(where: { $0.name == "v" })?.value == "2",
              let name = items.first(where: { $0.name == "name" })?.value,
              !name.isEmpty, name.utf8.count <= 63,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
              let key = items.first(where: { $0.name == "key" })?.value, key.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        self.init(serviceName: name, secret: key)
    }
    static func create() -> PairingTicket {
        let secret = (0..<32).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        return PairingTicket(serviceName: "PencilBridge-" + UUID().uuidString, secret: secret)
    }
}

struct PairingAttemptLimiter {
    private var attempts: [TimeInterval] = []
    mutating func allow(at time: TimeInterval) -> Bool {
        attempts.removeAll { time - $0 >= 60 }
        guard attempts.count < 5 else { return false }
        attempts.append(time)
        return true
    }
}
