import SwiftUI
import UIKit
import Network
import ImageIO

final class TabletBridge: ObservableObject {
    @Published var hosts: [NWBrowser.Result] = []
    @Published var code = ""
    @Published var status = "Find your Mac to get started."
    @Published var connected = false
    @Published var connecting = false
    @Published var mode: InputMode = .draw
    @Published var latencyMS: Double? = nil
    @Published var display: DisplayInfo?
    @Published var targetApp: AppContext?
    @Published var workspace = WorkspaceState()
    @Published var ghostImage: UIImage?
    private var previewPeer: Peer?
    private var previewService: String?
    private var previewGeneration = 0
    private var decoding = false
    private let imageDecoder = DispatchQueue(label: "dev.morgan.pencilbridge.preview-decode", qos: .utility)
    var inputAllowed: Bool { connected && workspace.inputAllowed }
    @Published var pressureFeel = PressureFeel(rawValue: UserDefaults.standard.string(forKey: "pressureFeel") ?? "") ?? .natural {
        didSet { UserDefaults.standard.set(pressureFeel.rawValue, forKey: "pressureFeel") }
    }
    @Published var preserveProportions = UserDefaults.standard.object(forKey: "preserveProportions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preserveProportions, forKey: "preserveProportions") }
    }
    @Published var fingerInput = FingerInput(rawValue: UserDefaults.standard.string(forKey: "fingerInput") ?? "") ?? .trackpad {
        didSet { UserDefaults.standard.set(fingerInput.rawValue, forKey: "fingerInput") }
    }
    @Published var fingerSpeed = UserDefaults.standard.object(forKey: "fingerSpeed") as? Double ?? 1.5 {
        didSet { UserDefaults.standard.set(fingerSpeed, forKey: "fingerSpeed") }
    }
    @Published var resetGeneration = 0
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
        guard Bridge.validJoinCode(code) else { status = "Enter the four-digit code shown on your Mac."; return }
        connect(endpoint: host.endpoint, secret: code)
    }
    func scan(_ text: String) {
        guard let ticket = PairingTicket(url: text) else { status = "This is not a Pencil Bridge pairing code."; return }
        connect(endpoint: .service(name: ticket.serviceName, type: Bridge.qrService, domain: "local.", interface: nil), secret: ticket.secret)
    }
    private func connect(endpoint: NWEndpoint, secret: String) {
        disconnect()
        connecting = true
        status = "Connecting…"
        let peer = Peer(NWConnection(to: endpoint, using: bridgeParameters(code: secret)))
        self.peer = peer
        peer.onReady = { [weak peer] in peer?.send(Packet(kind: .hello)) }
        peer.onPacket = { [weak self, weak peer] packet in
            guard let self else { return }
            switch packet.kind {
            case .welcome where !self.connected:
                guard let display = packet.display, display.valid else { peer?.close("Update both Pencil Bridge apps to the same version."); return }
                self.display = display
                self.targetApp = packet.app
                self.connected = true
                self.connecting = false
                self.status = "Connected"
                if let state = packet.workspace { self.applyWorkspace(state) }
            case .display:
                if let display = packet.display, display != self.display { self.cancelStroke(); self.display = display }
            case .context: self.targetApp = packet.app
            case .workspace:
                if let state = packet.workspace { self.applyWorkspace(state) }
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
            self?.stopPreview()
        }
        peer.onLatency = { [weak self] value in self?.latencyMS = value }
        peer.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer, !self.connected else { return }
            peer.close("Pairing timed out. Check the code and try again.")
        }
    }
    func send(_ sample: PencilSample) {
        guard connected, workspace.inputAllowed || sample.phase == .cancel else { return }
        peer?.send(Packet(kind: .sample, sample: sample))
    }
    func send(_ samples: [PencilSample]) {
        guard inputAllowed, !samples.isEmpty else { return }
        peer?.send(Packet(kind: .sample, samples: Array(samples.suffix(16))))
    }
    func control(_ action: TabletControl.Action) {
        guard inputAllowed else { return }
        cancelStroke()
        peer?.send(Packet(kind: .control, control: TabletControl(action: action)))
    }
    func gesture(_ command: TabletControl) {
        guard inputAllowed else { return }
        peer?.send(Packet(kind: .control, control: command))
    }
    func cancelStroke() {
        resetGeneration += 1
        send(PencilSample(phase: .cancel, x: 0.5, y: 0.5, pressure: 0, mode: mode))
    }
    func disconnect() {
        cancelStroke()
        stopPreview()
        workspace = WorkspaceState()
        peer?.close()
        peer = nil
        connected = false
        connecting = false
    }
    func configureWorkspace(_ request: WorkspaceRequest) {
        guard connected else { return }
        cancelStroke()
        peer?.send(Packet(kind: .workspace, workspaceRequest: request))
    }
    private func applyWorkspace(_ state: WorkspaceState) {
        if state.selected != workspace.selected || state.locked != workspace.locked || state.inputAllowed != workspace.inputAllowed {
            cancelStroke()
        }
        if state.selected?.id != workspace.selected?.id || !state.previewEnabled || !state.previewStatus.hasPrefix("Live") {
            ghostImage = nil; previewGeneration += 1
        }
        workspace = state
        guard state.previewEnabled, let service = state.previewService, let secret = state.previewSecret else {
            stopPreview(); return
        }
        guard previewService != service else { return }
        stopPreview()
        previewService = service
        let connection = NWConnection(to: .service(name: service, type: Bridge.previewService, domain: "local.", interface: nil),
                                      using: bridgeParameters(code: secret))
        let peer = Peer(connection, allowsPreview: true)
        previewPeer = peer
        peer.onReady = { [weak peer] in peer?.send(Packet(kind: .hello)) }
        peer.onPacket = { [weak self, weak peer] packet in
            guard packet.kind == .preview, let frame = packet.preview else { peer?.close("Unexpected preview message"); return }
            self?.receivePreview(frame)
        }
        peer.onClose = { [weak self] _ in
            self?.previewService = nil; self?.previewPeer = nil; self?.ghostImage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.connected, self.workspace.previewEnabled, self.previewPeer == nil else { return }
                self.applyWorkspace(self.workspace)
            }
        }
        peer.start()
    }
    private func receivePreview(_ frame: PreviewFrame) {
        guard !decoding, workspace.previewEnabled, workspace.selected?.id == frame.windowID else { return }
        decoding = true
        let generation = previewGeneration
        imageDecoder.async { [weak self] in
            // Decode off the input/UI thread and reject unreasonable image dimensions before allocation.
            let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil)
            var image: UIImage?
            if let source, let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = info[kCGImagePropertyPixelWidth] as? Int,
               let height = info[kCGImagePropertyPixelHeight] as? Int,
               width > 0, height > 0, width <= 1024, height <= 1024,
               let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                image = UIImage(cgImage: cg)
            }
            let decoded = image
            DispatchQueue.main.async {
                guard let self else { return }
                self.decoding = false
                if self.connected, self.previewGeneration == generation, self.workspace.selected?.id == frame.windowID {
                    self.ghostImage = decoded
                }
            }
        }
    }
    private func stopPreview() {
        previewGeneration += 1
        previewPeer?.onClose = nil
        previewPeer?.close(); previewPeer = nil; previewService = nil; ghostImage = nil
    }
    func suspend() {
        disconnect()
        browser?.cancel()
        browser = nil
        status = "Paused. Find your Mac to reconnect."
    }
}


@main
struct PencilBridgeTabletApp: App {
    init() { DistyllBrand.registerFonts() }
    var body: some Scene { WindowGroup { TabletPanel() } }
}
