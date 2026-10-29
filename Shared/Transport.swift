import Foundation
import Network
import Security
import CryptoKit

func bridgeParameters(code: String) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let key = Data(SHA256.hash(data: Data(("PencilBridge-v1:" + Bridge.normalizedCode(code)).utf8)))
    let identity = Data("PencilBridge-v1".utf8)
    let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identityData as __DispatchData)
    // Network.framework's external PSK API uses TLS 1.2 PSK cipher suites.
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.includePeerToPeer = true
    parameters.serviceClass = .responsiveData
    return parameters
}

// All callbacks and calls are on the main queue, including NWConnection callbacks.
final class Peer {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onPacket: ((Packet) -> Void)?
    var onClose: ((String) -> Void)?
    var onLatency: ((Double) -> Void)?
    private var framer = PacketFramer()
    private var closed = false
    private var timer: Timer?
    private var lastReceived = Date()
    private var sending = false
    private var outgoing = OutboundBuffer()

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.lastReceived = Date()
                self.onReady?()
                self.receive()
            case .failed(let error): self.close(error.localizedDescription)
            case .cancelled: self.close("Disconnected")
            default: break
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) > 5 { self.close("Connection timed out. Check the pairing code and Wi-Fi.") }
            else if case .ready = self.connection.state {
                self.send(Packet(kind: .heartbeat, ping: ProcessInfo.processInfo.systemUptime))
            }
        }
        connection.start(queue: .main)
    }
    func send(_ packet: Packet) {
        guard !closed else { return }
        guard outgoing.append(packet) else { close("Connection is too slow. Reconnect to resume."); return }
        flush()
    }
    private func flush() {
        guard !closed, !sending, let packet = outgoing.pop(),
              let data = try? PacketFramer.encode(packet) else { return }
        sending = true
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sending = false
            if let error { self.close(error.localizedDescription) }
            else { self.flush() }
        })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, !data.isEmpty {
                    for packet in try self.framer.append(data) {
                        self.lastReceived = Date()
                        if packet.kind == .heartbeat {
                            if let ping = packet.ping, ping.isFinite {
                                self.send(Packet(kind: .heartbeat, pong: ping))
                            }
                            if let pong = packet.pong, pong.isFinite {
                                let elapsed = ProcessInfo.processInfo.systemUptime - pong
                                if elapsed >= 0, elapsed < 30 { self.onLatency?(elapsed * 1000) }
                            }
                        } else { self.onPacket?(packet) }
                        if self.closed { return }
                    }
                }
            } catch { self.close("Invalid input received"); return }
            if let error { self.close(error.localizedDescription) }
            else if complete { self.close("Peer disconnected") }
            else { self.receive() }
        }
    }
    func close(_ reason: String = "Disconnected") {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onReady = nil; onPacket = nil; onClose = nil; onLatency = nil
    }
}
