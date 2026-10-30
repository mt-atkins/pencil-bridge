import AppKit
import SwiftUI
import ScreenCaptureKit
import Network

final class WindowWorkspace: ObservableObject {
    @Published private(set) var state = WorkspaceState()
    var onChange: ((WorkspaceState) -> Void)?
    var onWillChange: (() -> Void)?
    private var timer: Timer?
    private var previewListener: NWListener?
    private var previewPeer: Peer?
    private var previewReady = false
    private var captureBusy = false
    private var capturing = false
    private var epoch = 0
    private let encoder = DispatchQueue(label: "dev.morgan.pencilbridge.preview-encode", qos: .utility)

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    static func windowList() -> [WindowTarget] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let running = NSRunningApplication(processIdentifier: pid), running.activationPolicy == .regular,
                  let values = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: values), rect.width >= 100, rect.height >= 80 else { return nil }
            return WindowTarget(id: id, pid: pid, app: String((running.localizedName ?? "Mac app").prefix(80)),
                title: String((row[kCGWindowName as String] as? String ?? "Window \(id)").prefix(100)),
                bundleID: running.bundleIdentifier ?? "", x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }.filter(\.valid)
    }
    func allowsInput(at point: CGPoint? = nil) -> Bool {
        guard state.locked else { return true }
        guard let selected = state.selected else { return false }
        let windows = Self.windowList()
        guard selected.permits(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                               frontWindow: windows.first(where: { $0.pid == selected.pid })?.id),
              windows.contains(where: { $0.id == selected.id }) else { return false }
        if let point {
            guard selected.rect.contains(point) else { return false }
            // Prevent clicks through a different app's overlapping window.
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let hit = rows.first { row in
                guard let values = row[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: values),
                      (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return false }
                return bounds.contains(point)
            }
            guard hit?[kCGWindowNumber as String] as? UInt32 == selected.id else { return false }
        }
        return true
    }
    func request(_ request: WorkspaceRequest) {
        onWillChange?()
        epoch += 1
        if request.clearSelection == true {
            state.selected = nil; state.locked = false
        } else if let id = request.windowID, let target = Self.windowList().first(where: { $0.id == id }) {
            state.selected = target
        }
        if let locked = request.locked { state.locked = locked && state.selected != nil }
        if let preview = request.preview {
            state.previewEnabled = preview
            if preview && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        }
        refresh(force: true)
    }
    func refresh(force: Bool = false) {
        let old = state
        let windows = Self.windowList()
        state.windows = Array(windows.prefix(12))
        if let selected = state.selected {
            if let live = windows.first(where: { $0.id == selected.id && $0.pid == selected.pid }) {
                if live.rect != selected.rect { onWillChange?(); epoch += 1 }
                state.selected = live
            }
            // Retain a missing target so a locked workspace stays paused until it returns or is unlocked.
        }
        state.inputAllowed = allowsInput()
        if old.inputAllowed && !state.inputAllowed { onWillChange?() }
        if !state.previewEnabled { state.previewStatus = "Ghost preview is off." }
        else if state.selected == nil { state.previewStatus = "Choose a Mac window for its ghost preview." }
        else if !CGPreflightScreenCaptureAccess() { state.previewStatus = "Allow Screen Recording for Pencil Bridge on your Mac, then retry." }
        else if !windows.contains(where: { $0.id == state.selected?.id && $0.pid == state.selected?.pid }) { state.previewStatus = "Selected window is closed or minimized." }
        else if !capturing { state.previewStatus = "Connect your iPad to start its window ghost." }
        else if !previewReady { state.previewStatus = "Waiting for the iPad ghost connection." }
        else { state.previewStatus = "Live window ghost // up to 4 fps" }
        if force || state != old { onChange?(state) }
        if capturing, state.previewEnabled, CGPreflightScreenCaptureAccess(), let target = state.selected,
           windows.contains(where: { $0.id == target.id && $0.pid == target.pid }) { capture(target) }
    }
    func startSession() {
        stopSession()
        capturing = true
        let ticket = PairingTicket.create()
        do {
            let listener = try NWListener(using: bridgeParameters(code: ticket.secret))
            previewListener = listener
            listener.service = NWListener.Service(name: ticket.serviceName, type: Bridge.previewService)
            listener.stateUpdateHandler = { [weak self] phase in
                guard let self else { return }
                if case .ready = phase {
                    self.state.previewService = ticket.serviceName; self.state.previewSecret = ticket.secret
                    self.onChange?(self.state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.previewPeer == nil else { connection.cancel(); return }
                let peer = Peer(connection, allowsPreview: true)
                self.previewPeer = peer
                peer.onPacket = { [weak self, weak peer] packet in
                    if packet.kind == .hello { self?.previewReady = true }
                    else { peer?.close("Unexpected preview message") }
                }
                peer.onClose = { [weak self] _ in self?.previewPeer = nil; self?.previewReady = false }
                peer.start()
            }
            listener.start(queue: .main)
        } catch { state.previewStatus = "Could not start the ghost preview connection."; onChange?(state) }
    }
    func stopSession() {
        capturing = false; epoch += 1
        previewListener?.stateUpdateHandler = nil
        previewListener?.newConnectionHandler = nil
        previewListener?.cancel(); previewListener = nil
        previewPeer?.close(); previewPeer = nil; previewReady = false
        state.previewService = nil; state.previewSecret = nil
    }
    private func capture(_ target: WindowTarget) {
        guard !captureBusy, previewReady else { return }
        captureBusy = true
        let generation = epoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == target.pid }) else { self.captureBusy = false; return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = min(1, 960 / max(target.width, target.height))
                config.width = max(1, Int(target.width * scale)); config.height = max(1, Int(target.height * scale))
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let publish: @MainActor @Sendable (Data?) -> Void = { [weak self] jpeg in
                    guard let self else { return }
                    self.captureBusy = false
                    guard self.capturing, self.epoch == generation, self.state.selected?.id == target.id,
                          self.state.previewEnabled, let jpeg, jpeg.count <= 90_000 else { return }
                    self.previewPeer?.sendPreview(PreviewFrame(windowID: target.id, jpeg: jpeg))
                }
                self.encoder.async {
                    let rep = NSBitmapImageRep(cgImage: image)
                    var jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.45])
                    for quality in [0.25, 0.12] where (jpeg?.count ?? 0) > 90_000 {
                        jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
                    }
                    let encoded = jpeg
                    DispatchQueue.main.async { publish(encoded) }
                }
            } catch {
                self.captureBusy = false
                self.state.previewStatus = "Preview unavailable. Check Screen Recording permission and the selected window."
                self.onChange?(self.state)
            }
        }
    }
}

struct WindowWorkspaceSettings: View {
    @ObservedObject var workspace: WindowWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("App window", selection: Binding(get: { workspace.state.selected?.id ?? 0 }, set: { id in
                workspace.request(WorkspaceRequest(windowID: id == 0 ? nil : id, clearSelection: id == 0))
            })) {
                Text("Whole display").tag(UInt32(0))
                if let selected = workspace.state.selected, !workspace.state.windows.contains(where: { $0.id == selected.id }) {
                    Text("\(selected.app) // \(selected.title)").tag(selected.id)
                }
                ForEach(workspace.state.windows) { window in Text("\(window.app) // \(window.title)").tag(window.id) }
            }
            Toggle("Lock input to selected app window", isOn: Binding(get: { workspace.state.locked }, set: {
                workspace.request(WorkspaceRequest(locked: $0))
            })).disabled(workspace.state.selected == nil)
            Toggle("Show window ghost on iPad", isOn: Binding(get: { workspace.state.previewEnabled }, set: {
                workspace.request(WorkspaceRequest(preview: $0))
            }))
            Text(workspace.state.locked && !workspace.state.inputAllowed ? "Input paused // activate the selected window on your Mac." : workspace.state.previewStatus)
                .font(DistyllBrand.body(12)).foregroundStyle(DistyllBrand.muted)
            if workspace.state.previewEnabled && !CGPreflightScreenCaptureAccess() {
                Button("Open Screen Recording settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }.padding(16).distyllPanel()
    }
}
