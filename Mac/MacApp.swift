import SwiftUI
import AppKit
import Network
import ApplicationServices
import CoreImage.CIFilterBuiltins

final class MacBridge: ObservableObject {
    @Published var running = false
    @Published var connected = false
    @Published var status = "Start sharing to connect your iPad."
    @Published var code = ""
    @Published var qrTicket: PairingTicket?
    @Published var qrReady = false
    @Published var tabletEvents = true
    @Published var targetApp = AppContext(name: "Frontmost Mac app", bundleID: "")
    @Published var shortcutProfiles: [String: [String: ShortcutBinding]] = {
        guard let data = UserDefaults.standard.data(forKey: "shortcutProfiles") else { return [:] }
        return (try? JSONDecoder().decode([String: [String: ShortcutBinding]].self, from: data)) ?? [:]
    }()
    @Published var trusted = AXIsProcessTrusted()
    @Published var displayID = CGMainDisplayID()
    @Published var sampleCount = 0
    @Published var latencyMS: Double? = nil
    private var receivedSamples = 0
    private var listener: NWListener?
    private var qrListener: NWListener?
    private var attempts = PairingAttemptLimiter()
    private var peer: Peer?
    private var authenticated = false
    private var pointer = PointerState()
    private var eventNumber: Int64 = 1
    private var permissionTimer: Timer?
    private var sleepObservers: [NSObjectProtocol] = []
    private let source = CGEventSource(stateID: .privateState)
    private var lastSample: PencilSample?
    private var lastPoint = CGPoint.zero
    private var panning = false
    private var penInProximity = false
    private var finger = FingerPointerState()
    private var lastClickTime = -Double.infinity
    private var lastClickPoint = CGPoint.zero
    private var lastClickWasSecondary = false
    private var clickCount: Int64 = 0

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
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.updateTargetApp(app)
        })
        if let front = NSWorkspace.shared.frontmostApplication { updateTargetApp(front) }
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
        code = Bridge.newJoinCode()
        attempts = PairingAttemptLimiter()
        let ticket = PairingTicket.create()
        qrTicket = ticket
        do {
            let listener = try NWListener(using: bridgeParameters(code: code))
            let qrListener = try NWListener(using: bridgeParameters(code: ticket.secret))
            self.listener = listener
            self.qrListener = qrListener
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
            qrListener.service = NWListener.Service(name: ticket.serviceName, type: Bridge.qrService)
            qrListener.newConnectionHandler = { [weak self] connection in self?.accept(connection, scanned: true) }
            qrListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.qrReady = true
                case .failed(let error): self?.stop(); self?.status = error.localizedDescription
                default: break
                }
            }
            running = true
            status = "Starting…"
            listener.start(queue: .main)
            qrListener.start(queue: .main)
        } catch { stop(); status = error.localizedDescription }
    }
    private func accept(_ connection: NWConnection, scanned: Bool = false) {
        guard running, peer == nil else { connection.cancel(); return }
        if !scanned, !attempts.allow(at: ProcessInfo.processInfo.systemUptime) {
            status = "Too many code attempts. Wait a minute or scan the QR code."
            connection.cancel()
            return
        }
        let peer = Peer(connection)
        self.peer = peer
        authenticated = false
        status = "Pairing…"
        peer.onPacket = { [weak self, weak peer] packet in
            guard let self, let peer else { return }
            if !self.authenticated {
                guard packet.kind == .hello else { peer.close("Expected pairing handshake"); return }
                self.authenticated = true
                self.attempts = PairingAttemptLimiter()
                self.connected = true
                self.sampleCount = 0
                self.receivedSamples = 0
                self.status = "iPad connected"
                peer.send(Packet(kind: .welcome, display: self.displayInfo, app: self.targetApp))
                return
            }
            switch packet.kind {
            case .sample:
                guard self.trusted else { self.releaseButton(); return }
                for sample in packet.inputSamples {
                    self.receivedSamples += 1
                    self.consume(sample)
                }
            case .control:
                if self.trusted, let control = packet.control { self.perform(control) }
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
        qrListener?.stateUpdateHandler = nil
        qrListener?.newConnectionHandler = nil
        qrListener?.cancel()
        qrListener = nil
        qrReady = false
        qrTicket = nil
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
        if connected { peer?.send(Packet(kind: .display, display: displayInfo)) }
    }
    private var displayInfo: DisplayInfo {
        let bounds = CGDisplayBounds(displayID)
        let name = displays.first(where: { $0.0 == displayID })?.1 ?? "Mac display"
        return DisplayInfo(name: name, width: bounds.width, height: bounds.height)
    }
    private func releaseButton() {
        post(pointer.reset())
        endTrackpad()
        endTools()
    }
    private func endTrackpad() {
        postFinger(finger.reset())
    }
    private func endTools() {
        if panning { key(49, down: false); panning = false }
        if penInProximity {
            PenEvents.proximity(enter: false, point: lastPoint, source: source)?.post(tap: .cghidEventTap)
            penInProximity = false
        }
    }
    private func consume(_ sample: PencilSample) {
        if sample.phase == .cancel { releaseButton(); return }
        if sample.phase == .down {
            releaseButton()
            if sample.mode == .pan { key(49, down: true); panning = true }
            if sample.mode == .draw, tabletEvents {
                let bounds = CGDisplayBounds(displayID)
                let point = CGPoint(x: bounds.minX + sample.x * bounds.width, y: bounds.minY + sample.y * bounds.height)
                PenEvents.proximity(enter: true, point: point, source: source)?.post(tap: .cghidEventTap)
                penInProximity = true
            }
        }
        lastSample = sample
        post(pointer.consume(sample))
        if sample.phase == .up || sample.phase == .cancel { endTools() }
    }
    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    private func perform(_ control: TabletControl) {
        guard control.valid else { return }
        switch control.action {
        case .trackpadBegin, .dragBegin:
            releaseButton()
            postFinger(finger.begin(at: CGEvent(source: nil)?.location ?? lastPoint, dragging: control.action == .dragBegin))
            return
        case .relativeMove:
            guard let old = finger.point else { return }
            var next = CGPoint(x: old.x + control.dx, y: old.y + control.dy)
            let areas = displays.map { CGDisplayBounds($0.0) }
            if !areas.contains(where: { $0.contains(next) }) {
                next = areas.map { CGRect in
                    CGPoint(x: min(CGRect.maxX - 1, max(CGRect.minX, next.x)), y: min(CGRect.maxY - 1, max(CGRect.minY, next.y)))
                }.min(by: { hypot($0.x - next.x, $0.y - next.y) < hypot($1.x - next.x, $1.y - next.y) }) ?? old
            }
            postFinger(finger.move(to: next))
            return
        case .trackpadEnd, .dragEnd: endTrackpad(); return
        case .click, .secondaryClick:
            releaseButton()
            let point = CGEvent(source: nil)?.location ?? lastPoint
            let secondary = control.action == .secondaryClick
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastClickTime < NSEvent.doubleClickInterval, secondary == lastClickWasSecondary,
               hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 4 { clickCount = min(3, clickCount + 1) }
            else { clickCount = 1 }
            lastClickTime = now; lastClickPoint = point; lastClickWasSecondary = secondary
            eventNumber += 1
            fingerEvent(secondary ? .rightMouseDown : .leftMouseDown, at: point, count: clickCount)
            fingerEvent(secondary ? .rightMouseUp : .leftMouseUp, at: point, count: clickCount)
            return
        default: break
        }
        if control.action == .scroll {
            guard !pointer.held, !finger.held else { return }
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(control.dy.rounded()), wheel2: Int32(control.dx.rounded()), wheel3: 0)?.post(tap: .cghidEventTap)
            return
        }
        releaseButton()
        if control.action == .nextDisplay {
            let ids = displays.map(\.0)
            if let current = ids.firstIndex(of: displayID), !ids.isEmpty { changeDisplay(ids[(current + 1) % ids.count]) }
        } else if let binding = shortcut(for: control.action, app: targetApp.bundleID), binding.valid {
            let flags = PenEvents.flags(for: binding)
            key(binding.key, down: true, flags: flags)
            key(binding.key, down: false, flags: flags)
        }
    }
    private func updateTargetApp(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        targetApp = AppContext(name: app.localizedName ?? id, bundleID: id)
        if connected { peer?.send(Packet(kind: .context, app: targetApp)) }
    }
    func shortcut(for action: TabletControl.Action, app: String) -> ShortcutBinding? {
        shortcutProfiles[app]?[action.rawValue] ?? PenEvents.defaultBinding(for: action)
    }
    func setShortcut(_ binding: ShortcutBinding, action: TabletControl.Action, app: String) {
        guard binding.valid else { return }
        shortcutProfiles[app, default: [:]][action.rawValue] = binding
        saveProfiles()
    }
    func resetShortcuts(app: String) { shortcutProfiles.removeValue(forKey: app); saveProfiles() }
    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(shortcutProfiles) { UserDefaults.standard.set(data, forKey: "shortcutProfiles") }
    }
    private func fingerEvent(_ type: CGEventType, at point: CGPoint, count: Int64 = 1) {
        lastPoint = point
        PenEvents.mouse(type: type, point: point, source: source, number: eventNumber, clickCount: count)?.post(tap: .cghidEventTap)
    }
    private func postFinger(_ actions: [PointerAction]) {
        for action in actions {
            switch action {
            case .move(let x, let y): fingerEvent(.mouseMoved, at: CGPoint(x: x, y: y))
            case .down(let x, let y): eventNumber += 1; fingerEvent(.leftMouseDown, at: CGPoint(x: x, y: y))
            case .drag(let x, let y): fingerEvent(.leftMouseDragged, at: CGPoint(x: x, y: y))
            case .up(let x, let y): fingerEvent(.leftMouseUp, at: CGPoint(x: x, y: y))
            }
        }
    }
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
            lastPoint = point
            guard let event = PenEvents.mouse(type: type, point: point, source: source, number: eventNumber,
                                             sample: tabletEvents ? lastSample : nil) else { continue }
            event.post(tap: .cghidEventTap)
        }
    }
}

struct MacPanel: View {
    @ObservedObject var bridge: MacBridge
    @State private var editingApp: AppContext?
    var body: some View {
        ScrollView {
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
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code or scan to pair").font(.headline)
                        Text(bridge.code).font(.system(size: 48, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text("A new code is created each time sharing starts.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let ticket = bridge.qrTicket, bridge.qrReady { PairingQR(value: ticket.url) }
                }
            }
            Toggle("Send tablet pressure and tilt", isOn: $bridge.tabletEvents)
                .onChange(of: bridge.tabletEvents) { _, _ in bridge.changeDisplay(bridge.displayID) }
            Text("Tablet support varies by drawing app. Turn this off for ordinary mouse input.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Shortcuts: \(bridge.targetApp.name)").font(.caption).lineLimit(1)
                Spacer()
                Button("Edit Shortcuts…") { editingApp = bridge.targetApp }
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
        }.padding(28)
        }.frame(width: 560, height: 680)
            .sheet(item: $editingApp) { app in ShortcutEditor(bridge: bridge, app: app) }
    }
}

struct PairingQR: View {
    let value: String
    @State private var cachedImage: NSImage?
    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), from: output.extent.applying(CGAffineTransform(scaleX: 5, y: 5))) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    var body: some View {
        Group {
        if let qrImage = cachedImage {
            Image(nsImage: qrImage).interpolation(.none).resizable().scaledToFit()
                .frame(width: 144, height: 144).padding(16).background(.white)
                .accessibilityLabel("Pairing QR code. Scan from the iPad app.")
        } else { ProgressView().frame(width: 176, height: 176) }
        }
        .task(id: value) { cachedImage = qrImage }
    }
}

@main
struct PencilBridgeMacApp: App {
    @StateObject private var bridge = MacBridge()
    var body: some Scene {
        WindowGroup {
            MacPanel(bridge: bridge).onAppear {
                if CommandLine.arguments.contains("--start-sharing") { bridge.start() }
            }
        }
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
