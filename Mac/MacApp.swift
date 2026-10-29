import SwiftUI
import AppKit
import Network
import ApplicationServices

final class MacBridge: ObservableObject {
    @Published var running = false
    @Published var connected = false
    @Published var status = "Start sharing to connect your iPad."
    @Published var code = ""
    @Published var trusted = AXIsProcessTrusted()
    @Published var displayID = CGMainDisplayID()
    @Published var sampleCount = 0
    @Published var latencyMS: Double? = nil
    private var receivedSamples = 0
    private var listener: NWListener?
    private var peer: Peer?
    private var authenticated = false
    private var pointer = PointerState()
    private var eventNumber: Int64 = 1
    private var permissionTimer: Timer?
    private var sleepObservers: [NSObjectProtocol] = []
    private let source = CGEventSource(stateID: .privateState)

    init() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.trusted = AXIsProcessTrusted()
            self.sampleCount = self.receivedSamples
            if !self.trusted { self.releaseButton() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() })
        }
        sleepObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() })
    }
    var displays: [(CGDirectDisplayID, String)] {
        NSScreen.screens.enumerated().map { index, screen in
            ((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID(), "\(index + 1): \(screen.localizedName)")
        }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func start() {
        guard !running else { return }
        code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        do {
            let listener = try NWListener(using: bridgeParameters(code: code))
            self.listener = listener
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Pencil Bridge Mac", type: Bridge.service)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.status = "Waiting for your iPad"
                case .failed(let error): self.stop(); self.status = error.localizedDescription
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            running = true
            status = "Starting…"
            listener.start(queue: .main)
        } catch { status = error.localizedDescription }
    }
    private func accept(_ connection: NWConnection) {
        guard running, peer == nil else { connection.cancel(); return }
        let peer = Peer(connection)
        self.peer = peer
        authenticated = false
        status = "Pairing…"
        peer.onPacket = { [weak self, weak peer] packet in
            guard let self, let peer else { return }
            if !self.authenticated {
                guard packet.kind == .hello else { peer.close("Expected pairing handshake"); return }
                self.authenticated = true
                self.connected = true
                self.sampleCount = 0
                self.receivedSamples = 0
                self.status = "iPad connected"
                peer.send(Packet(kind: .welcome))
                return
            }
            switch packet.kind {
            case .sample:
                guard let sample = packet.sample else { return }
                guard self.trusted else { self.releaseButton(); return }
                self.receivedSamples += 1
                self.post(self.pointer.consume(sample))
            case .heartbeat: break
            case .goodbye: peer.close()
            default: peer.close("Unexpected message")
            }
        }
        peer.onClose = { [weak self] reason in
            guard let self else { return }
            self.releaseButton()
            self.peer = nil
            self.authenticated = false
            self.connected = false
            self.latencyMS = nil
            self.status = self.running ? "\(reason) — ready to reconnect" : "Stopped"
        }
        peer.onLatency = { [weak self] value in self?.latencyMS = value }
        peer.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer, !self.authenticated else { return }
            peer.close("Pairing timed out")
        }
    }
    func stop() {
        running = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        peer?.close()
        peer = nil
        releaseButton()
        connected = false
        code = ""
        status = "Stopped"
    }
    func changeDisplay(_ id: CGDirectDisplayID) {
        releaseButton()
        displayID = id
    }
    private func releaseButton() { post(pointer.reset()) }
    private func post(_ actions: [PointerAction]) {
        if CGDisplayIsActive(displayID) == 0 { displayID = CGMainDisplayID() }
        let bounds = CGDisplayBounds(displayID)
        for action in actions {
            let type: CGEventType
            let x: Double, y: Double
            switch action {
            case .move(let a, let b): type = .mouseMoved; x = a; y = b
            case .down(let a, let b): type = .leftMouseDown; x = a; y = b; eventNumber += 1
            case .drag(let a, let b): type = .leftMouseDragged; x = a; y = b
            case .up(let a, let b): type = .leftMouseUp; x = a; y = b
            }
            let point = CGPoint(x: bounds.minX + x * max(0, bounds.width - 1), y: bounds.minY + y * max(0, bounds.height - 1))
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
            event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }
}

struct MacPanel: View {
    @ObservedObject var bridge: MacBridge
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Pencil Bridge", systemImage: "pencil.tip.crop.circle")
                .font(.largeTitle.bold())
            Text("Use your iPad and Apple Pencil to control this Mac.").foregroundStyle(.secondary)
            Label(bridge.status, systemImage: bridge.connected ? "checkmark.circle.fill" : "network")
            if !bridge.trusted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow Accessibility access so Pencil Bridge can move the cursor and click.")
                    Button("Open Accessibility Settings") { bridge.requestAccessibility() }
                }.padding().background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if bridge.running {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this pairing code on your iPad").font(.headline)
                    Text(bridge.code).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Text("The connection is encrypted. A new code is created each time sharing starts.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Target display", selection: Binding(get: { bridge.displayID }, set: { bridge.changeDisplay($0) })) {
                ForEach(bridge.displays, id: \.0) { id, name in Text(name).tag(id) }
            }
            HStack {
                Button(bridge.running ? "Stop Sharing" : "Start Sharing") {
                    if bridge.running { bridge.stop() } else { bridge.start() }
                }.buttonStyle(.borderedProminent)
                if bridge.connected { Text("\(bridge.sampleCount) input samples").font(.caption).foregroundStyle(.secondary) }
            }
            if let latency = bridge.latencyMS, bridge.connected {
                Text("Connection round trip: \(Int(latency)) ms").font(.caption).foregroundStyle(.secondary)
            }
            Text("Keep both apps open on the same Wi-Fi network. Use the menu bar to stop sharing at any time.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 500)
    }
}

@main
struct PencilBridgeMacApp: App {
    @StateObject private var bridge = MacBridge()
    var body: some Scene {
        WindowGroup { MacPanel(bridge: bridge) }
            .windowResizability(.contentSize)
        MenuBarExtra("Pencil Bridge", systemImage: "pencil.tip.crop.circle") {
            Text(bridge.status)
            if bridge.running {
                Text("Pairing code: \(bridge.code)")
                Button("Stop Sharing") { bridge.stop() }
            } else { Button("Start Sharing") { bridge.start() } }
            Divider()
            Button("Quit Pencil Bridge") { bridge.stop(); NSApplication.shared.terminate(nil) }
        }
    }
}
