import SwiftUI
import UIKit
import Network

final class TabletBridge: ObservableObject {
    @Published var hosts: [NWBrowser.Result] = []
    @Published var code = ""
    @Published var status = "Find your Mac to get started."
    @Published var connected = false
    @Published var connecting = false
    @Published var mode: InputMode = .draw
    @Published var latencyMS: Double? = nil
    private var browser: NWBrowser?
    private var peer: Peer?
    func search() {
        browser?.cancel()
        hosts = []
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Bridge.service, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.hosts = results.sorted { Self.name($0) < Self.name($1) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.status = error.localizedDescription }
            if case .waiting = state { self?.status = "Allow Local Network access in Settings, then try again." }
        }
        status = "Searching for Macs…"
        browser.start(queue: .main)
    }
    static func name(_ host: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = host.endpoint { return name }
        return "Mac"
    }
    func connect(to host: NWBrowser.Result) {
        disconnect()
        connecting = true
        status = "Connecting…"
        let peer = Peer(NWConnection(to: host.endpoint, using: bridgeParameters(code: code)))
        self.peer = peer
        peer.onReady = { [weak peer] in peer?.send(Packet(kind: .hello)) }
        peer.onPacket = { [weak self, weak peer] packet in
            guard let self else { return }
            switch packet.kind {
            case .welcome where !self.connected:
                self.connected = true
                self.connecting = false
                self.status = "Connected"
            case .heartbeat: break
            default: peer?.close("Unexpected message")
            }
        }
        peer.onClose = { [weak self] reason in
            self?.connected = false
            self?.connecting = false
            self?.status = reason
            self?.peer = nil
            self?.latencyMS = nil
        }
        peer.onLatency = { [weak self] value in self?.latencyMS = value }
        peer.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer, !self.connected else { return }
            peer.close("Pairing timed out. Check the code and try again.")
        }
    }
    func send(_ sample: PencilSample) {
        guard connected else { return }
        peer?.send(Packet(kind: .sample, sample: sample))
    }
    func cancelStroke() {
        send(PencilSample(phase: .cancel, x: 0.5, y: 0.5, pressure: 0, mode: mode))
    }
    func disconnect() {
        cancelStroke()
        peer?.close()
        peer = nil
        connected = false
        connecting = false
    }
    func suspend() {
        disconnect()
        browser?.cancel()
        browser = nil
        status = "Paused. Find your Mac to reconnect."
    }
}

final class PencilSurface: UIView {
    var onSample: ((PencilSample) -> Void)?
    var mode = InputMode.draw
    var enabled = false
    private var active: UITouch?
    private var activeMode = InputMode.draw
    private var trail: [CGPoint] = []
    private var strokeOrigin = CGPoint.zero
    private var strokeMoved = false
    private var previousSize = CGSize.zero
    private var lastPoint: CGPoint?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground
        isMultipleTouchEnabled = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func cancel() {
        guard active != nil else { return }
        onSample?(PencilSample(phase: .cancel, x: 0.5, y: 0.5, pressure: 0, mode: activeMode))
        active = nil
        trail.removeAll(keepingCapacity: true)
        lastPoint = nil
        setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Rotation or resizing must never change coordinate mapping mid-drag.
        if previousSize != bounds.size {
            if active != nil { cancel() }
            previousSize = bounds.size
        }
    }
    private func trackMovement(_ touch: UITouch) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let p = touch.location(in: self)
        if hypot((p.x - strokeOrigin.x) / bounds.width, (p.y - strokeOrigin.y) / bounds.height) > 0.012 {
            strokeMoved = true
        }
    }
    private func emit(_ touch: UITouch, _ phase: InputPhase) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let p = touch.location(in: self)
        if phase == .down { strokeOrigin = p; strokeMoved = false }
        else { trackMovement(touch) }
        let pressure = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0
        onSample?(PencilSample(phase: phase, x: Double(min(1, max(0, p.x / bounds.width))), y: Double(min(1, max(0, p.y / bounds.height))), pressure: Double(min(1, max(0, pressure))), mode: activeMode, strokeMoved: strokeMoved))
        if phase == .down { trail.removeAll(keepingCapacity: true) }
        trail.append(p)
        if trail.count > 128 { trail.removeFirst(trail.count - 128) }
        lastPoint = p
        setNeedsDisplay()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, active == nil, let pencil = touches.first(where: { $0.type == .pencil }) else { return }
        active = pencil
        activeMode = mode
        emit(pencil, .down)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, let active, touches.contains(active) else { return }
        let touches = event?.coalescedTouches(for: active) ?? [active]
        // Use historical touches for tap detection, but send only the live position.
        for touch in touches { trackMovement(touch) }
        emit(touches.last ?? active, .move)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        emit(active, .up)
        self.active = nil
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }
    override func draw(_ rect: CGRect) {
        UIColor.systemTeal.withAlphaComponent(0.4).setStroke()
        let trace = UIBezierPath()
        if let first = trail.first { trace.move(to: first) }
        for p in trail.dropFirst() { trace.addLine(to: p) }
        trace.lineWidth = 2
        trace.stroke()
        if let p = lastPoint {
            UIColor.systemTeal.setFill()
            UIBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
        }
    }
}

struct Canvas: UIViewRepresentable {
    @ObservedObject var bridge: TabletBridge
    func makeUIView(context: Context) -> PencilSurface {
        let view = PencilSurface()
        view.onSample = { [weak bridge] in bridge?.send($0) }
        return view
    }
    func updateUIView(_ view: PencilSurface, context: Context) {
        if view.mode != bridge.mode || !bridge.connected { view.cancel() }
        view.mode = bridge.mode
        view.enabled = bridge.connected
    }
    static func dismantleUIView(_ view: PencilSurface, coordinator: ()) { view.cancel() }
}

struct TabletPanel: View {
    @StateObject private var bridge = TabletBridge()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Label(bridge.status, systemImage: bridge.connected ? "checkmark.circle.fill" : "network")
                    Spacer()
                    if bridge.connected || bridge.connecting { Button("Disconnect") { bridge.disconnect() } }
                    else { Button("Find Mac") { bridge.search() } }
                }
                if bridge.connected {
                    Picker("Input mode", selection: $bridge.mode) {
                        Text("Draw / Drag").tag(InputMode.draw)
                        Text("Pointer / Tap to Click").tag(InputMode.pointer)
                    }.pickerStyle(.segmented)
                    Canvas(bridge: bridge)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(alignment: .topLeading) {
                            Text(bridge.mode == .draw ? "Touch with Apple Pencil to draw or drag on your Mac." : "Move Apple Pencil to point. Tap to click.")
                                .foregroundStyle(.secondary).padding().allowsHitTesting(false)
                        }
                    Text("The canvas maps to your selected Mac display. Finger touches are ignored.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let latency = bridge.latencyMS {
                        Text("Connection round trip: \(Int(latency)) ms").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Connect your Mac").font(.title2.bold())
                        Text("Start sharing in Pencil Bridge on your Mac, then enter its pairing code here.")
                        TextField("12-character pairing code", text: $bridge.code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        ForEach(bridge.hosts, id: \.endpoint) { host in
                            Button { bridge.connect(to: host) } label: {
                                HStack { Image(systemName: "desktopcomputer"); Text(TabletBridge.name(host)); Spacer(); Image(systemName: "arrow.right.circle") }
                            }.disabled(Bridge.normalizedCode(bridge.code).count != 12 || bridge.connecting)
                        }
                        if bridge.hosts.isEmpty {
                            Text("No Macs found yet. Use the same Wi-Fi network and allow Local Network access on both devices.")
                                .foregroundStyle(.secondary)
                        }
                        if bridge.connecting { ProgressView("Pairing…") }
                    }.padding(24).background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                    Spacer()
                }
            }.padding(24).navigationTitle("Pencil Bridge")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { bridge.suspend() }
            else if phase == .inactive { bridge.cancelStroke() }
        }
        .onChange(of: bridge.connected) { connected in UIApplication.shared.isIdleTimerDisabled = connected }
    }
}

@main
struct PencilBridgeTabletApp: App {
    var body: some Scene { WindowGroup { TabletPanel() } }
}
