import SwiftUI
import UIKit

struct TabletPanel: View {
    @StateObject private var bridge = TabletBridge()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScanner = false
    @State private var showSettings = false
    @FocusState private var codeFocused: Bool
    var body: some View {
        NavigationStack {
            Group {
                if bridge.connected { TabletWorkspace(bridge: bridge) }
                else { pairing }
            }
            .navigationTitle("Pencil Bridge").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(bridge.connected ? "Pencil Bridge" : "Distyll").font(DistyllBrand.display(17))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if bridge.connected || bridge.connecting { Button("Disconnect") { bridge.disconnect() } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { bridge.cancelStroke(); showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Tablet settings and pen test")
                }
            }
        }
        .background(DistyllBrand.graphite)
        .toolbarBackground(DistyllBrand.graphite, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .distyllAppearance()
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingScanner { text in showScanner = false; bridge.scan(text) }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        Text("Point the camera at the QR code on your Mac.")
                            .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                    }
                    .navigationTitle("Scan to pair").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
            }.distyllAppearance()
        }
        .sheet(isPresented: $showSettings) { TabletSettings(bridge: bridge) }
        .onAppear { AudioFeedback.shared.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { phase in
            AudioFeedback.shared.setActive(phase == .active)
            if phase == .background { showScanner = false; bridge.suspend() }
            else if phase == .inactive { bridge.cancelStroke() }
        }
        .onChange(of: bridge.connected) { UIApplication.shared.isIdleTimerDisabled = $0 }
    }
    private var pairing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pencil Bridge").font(DistyllBrand.display(36)).tracking(-0.36)
                        Text("Draw on your iPad. Work on your Mac.")
                            .font(DistyllBrand.body(16)).foregroundStyle(DistyllBrand.muted).lineSpacing(6)
                    }
                    Spacer(minLength: 0)
                    DistyllProductMark(size: 64)
                }
                Text("Start sharing on your Mac. Scan its QR code or enter the four-digit code below.")
                    .font(DistyllBrand.body(15)).foregroundStyle(DistyllBrand.muted).lineSpacing(6)
                Button { showScanner = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(DistyllButtonStyle(primary: true)).disabled(bridge.connecting)
                Divider()
                Text("Or enter the join code").font(DistyllBrand.body(15, strong: true))
                TextField("0000", text: $bridge.code)
                    .focused($codeFocused)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(DistyllBrand.mono(42, strong: true))
                    .multilineTextAlignment(.center).textFieldStyle(.plain)
                    .padding(.vertical, 16).distyllPanel(radius: 8, recessed: true)
                    .accessibilityLabel("Four-digit join code")
                    .onChange(of: bridge.code) { value in
                        let filtered = String(value.filter { "0123456789".contains($0) }.prefix(4))
                        if filtered != value { bridge.code = filtered }
                        if Bridge.validJoinCode(filtered) { codeFocused = false }
                    }
                HStack {
                    Text(bridge.status).font(DistyllBrand.body(14)).foregroundStyle(DistyllBrand.muted)
                    Spacer()
                    Button("Find Mac") { bridge.search() }.buttonStyle(DistyllButtonStyle(compact: true)).disabled(bridge.connecting)
                }
                ForEach(bridge.hosts, id: \.endpoint) { host in
                    Button { bridge.connect(to: host) } label: {
                        HStack { Image(systemName: "desktopcomputer"); Text(TabletBridge.name(host)); Spacer(); Image(systemName: "link.circle") }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(DistyllButtonStyle())
                        .disabled(!Bridge.validJoinCode(bridge.code) || bridge.connecting)
                }
                if bridge.connecting { ProgressView("Pairing…") }
                Text("Both devices must be on the same local network.").font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                DistyllLayerLines().frame(height: 24)
                Text("Distyll // Local input").font(DistyllBrand.mono(11)).foregroundStyle(DistyllBrand.muted)
            }.padding(28).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(DistyllBrand.graphite)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { bridge.search() }
    }
}

struct TabletWorkspace: View {
    @ObservedObject var bridge: TabletBridge
    @AppStorage("leftHanded") private var leftHanded = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(bridge.targetApp?.name ?? bridge.display?.name ?? "Mac display", systemImage: "display").lineLimit(1)
                Spacer()
                if bridge.workspace.locked {
                    Label(bridge.workspace.inputAllowed ? "App locked" : "Input paused", systemImage: "lock.fill")
                        .font(DistyllBrand.mono(11)).foregroundStyle(DistyllBrand.muted)
                }
                if let ms = bridge.latencyMS { Text("\(Int(ms)) ms // round trip").font(DistyllBrand.mono(11)).foregroundStyle(DistyllBrand.muted) }
            }.font(DistyllBrand.body(12)).padding(.horizontal, 20)
            Picker("Input mode", selection: $bridge.mode) {
                Text("Pen").tag(InputMode.draw)
                Text("Pointer").tag(InputMode.pointer)
                Text("Pan").tag(InputMode.pan)
            }.pickerStyle(.segmented).padding(.horizontal, 20)
                .onChange(of: bridge.mode) { _ in bridge.cancelStroke(); AudioFeedback.shared.play(.tool) }
            HStack(spacing: 4) {
                if !leftHanded { rail }
                Canvas(bridge: bridge)
                    .overlay {
                        if !bridge.workspace.inputAllowed {
                            Text("Input paused // Activate the selected app window on your Mac")
                                .font(DistyllBrand.body(15, strong: true)).padding(20)
                                .background(DistyllBrand.graphite.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
                                .allowsHitTesting(false)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(DistyllBrand.line, lineWidth: 1))
                if leftHanded { rail }
            }.padding(.horizontal, 12)
            Text(bridge.mode == .pan ? "Pencil contact pans with Space + drag. Lift to release." : "Pencil to draw // fingers to point // two fingers to scroll // pinch to zoom")
                .font(DistyllBrand.body(12)).foregroundStyle(DistyllBrand.muted).padding(.bottom, 8)
        }
        .background(DistyllBrand.graphite)
    }
    private var rail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                shortcut("Undo", "arrow.uturn.backward", .undo)
                shortcut("Redo", "arrow.uturn.forward", .redo)
                Divider()
                shortcut("Brush", "paintbrush.pointed", .brush)
                shortcut("Eraser", "eraser", .eraser)
                shortcut("Smaller", "minus.circle", .smallerBrush)
                shortcut("Larger", "plus.circle", .largerBrush)
                Divider()
                shortcut("Zoom in", "plus.magnifyingglass", .zoomIn)
                shortcut("Zoom out", "minus.magnifyingglass", .zoomOut)
                shortcut("Fit", "arrow.up.left.and.arrow.down.right", .fit)
                shortcut("Display", "display.2", .nextDisplay)
            }.padding(.vertical, 8)
        }.frame(width: 68)
    }
    private func shortcut(_ title: String, _ icon: String, _ action: TabletControl.Action) -> some View {
        Button {
            if action == .brush || action == .eraser { bridge.mode = .draw }
            bridge.control(action)
            AudioFeedback.shared.play(.tool)
        } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(title).font(DistyllBrand.body(11)) }
                .frame(width: 60, height: 48).contentShape(Rectangle())
                .background(DistyllBrand.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DistyllBrand.line, lineWidth: 1))
        }.buttonStyle(.borderless).accessibilityLabel(title).disabled(!bridge.inputAllowed)
    }
}

struct TabletSettings: View {
    @AppStorage("ghostOpacity") private var ghostOpacity = 0.45
    @ObservedObject private var feedback = AudioFeedback.shared
    @ObservedObject var bridge: TabletBridge
    @Environment(\.dismiss) private var dismiss
    @AppStorage("leftHanded") private var leftHanded = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac app window") {
                    Picker("Selected window", selection: Binding(get: { bridge.workspace.selected?.id ?? 0 }, set: { id in
                        bridge.configureWorkspace(WorkspaceRequest(windowID: id == 0 ? nil : id, clearSelection: id == 0))
                    })) {
                        Text("Whole display").tag(UInt32(0))
                        if let selected = bridge.workspace.selected, !bridge.workspace.windows.contains(where: { $0.id == selected.id }) {
                            Text("\(selected.app) // \(selected.title)").tag(selected.id)
                        }
                        ForEach(bridge.workspace.windows) { window in Text("\(window.app) // \(window.title)").tag(window.id) }
                    }
                    Toggle("Lock input to selected app", isOn: Binding(get: { bridge.workspace.locked }, set: {
                        bridge.configureWorkspace(WorkspaceRequest(locked: $0))
                    })).disabled(bridge.workspace.selected == nil)
                    Toggle("Show window ghost", isOn: Binding(get: { bridge.workspace.previewEnabled }, set: {
                        bridge.configureWorkspace(WorkspaceRequest(preview: $0))
                    }))
                    if bridge.workspace.previewEnabled {
                        HStack { Text("Ghost opacity"); Slider(value: $ghostOpacity, in: 0.15...0.8, step: 0.05).accessibilityLabel("Ghost opacity") }
                    }
                    Text(bridge.workspace.previewStatus).font(DistyllBrand.body(12)).foregroundStyle(DistyllBrand.muted)
                    Text("Choose a window to map the Pencil to that window. App lock pauses input when another app or window is active. Unlock or choose Whole display to return to normal control.")
                        .font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                }.disabled(!bridge.connected).listRowBackground(DistyllBrand.surface)
                Section("Tip feel") {
                    Picker("Pressure response", selection: $bridge.pressureFeel) {
                        ForEach(PressureFeel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Light reaches full pressure with less force. Firm gives more room for delicate strokes.")
                        .font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                    PenTestPad(feel: bridge.pressureFeel).frame(height: 220)
                    Text("Try your Pencil here. This test pad does not send input to your Mac.").font(DistyllBrand.body(12)).foregroundStyle(DistyllBrand.muted)
                }.listRowBackground(DistyllBrand.surface)
                Section("Audio feedback") {
                    Toggle("Click sounds on iPad", isOn: $feedback.enabled)
                    HStack {
                        Text("Output: \(feedback.outputName)").font(DistyllBrand.body(13))
                        Spacer()
                        FeedbackAudioRoutePicker().frame(width: 44, height: 44)
                    }
                    Toggle("Play when iPad is muted", isOn: $feedback.playWhenMuted).disabled(!feedback.enabled)
                    if feedback.enabled {
                        HStack {
                            Text("Volume")
                            Slider(value: $feedback.volume, in: 0...1, step: 0.05)
                                .accessibilityLabel("Feedback volume")
                            Text("\(Int(feedback.volume * 100))%")
                                .font(DistyllBrand.mono(12)).frame(minWidth: 36)
                        }
                        Button("Test sound") { feedback.play(.pencil) }
                    }
                    Text("Soft clicks for Pencil contact, finger taps, dragging and tool buttons. This is sound, not vibration. Generated on the iPad and controlled by its media volume. Choose iPad speakers in the output picker for the most direct feel.")
                        .font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                }.listRowBackground(DistyllBrand.surface)
                Section("Workspace") {
                    Toggle("Left-handed controls", isOn: $leftHanded)
                    Toggle("Keep display proportions", isOn: $bridge.preserveProportions)
                        .onChange(of: bridge.preserveProportions) { _ in bridge.cancelStroke() }
                    Text("Uses a proportional active area so circles stay circular on your Mac.").font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                    Picker("Finger input", selection: $bridge.fingerInput) {
                        ForEach(FingerInput.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.onChange(of: bridge.fingerInput) { _ in bridge.cancelStroke() }
                    if bridge.fingerInput == .trackpad {
                        HStack { Text("Pointer speed"); Slider(value: $bridge.fingerSpeed, in: 0.5...3, step: 0.1) }
                        Text("One finger moves; tap to click; two-finger tap for secondary click; three fingers drag. Pinch uses your app’s zoom shortcuts.").font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                    }
                    Text("Touch gestures pause during Pencil contact and briefly after lifting to reject resting fingers.").font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                }.listRowBackground(DistyllBrand.surface)
                Section("Drawing apps") {
                    Text("Shortcuts follow the active Mac app. Use Edit Shortcuts in the Mac companion to customize each app’s keys and modifiers.").font(DistyllBrand.body(13))
                    Text("Brush, eraser and size buttons use B, E, [ and ]. Zoom uses ⌘+/− and Fit uses ⌘0. Pan holds Space while the Pencil touches. Your Mac app must support these shortcuts.")
                        .font(DistyllBrand.body(13))
                    Text("Pressure and tilt are sent as macOS tablet events. Support depends on the drawing app. First-generation Apple Pencil does not provide hover or a double-tap button.")
                        .font(DistyllBrand.body(13)).foregroundStyle(DistyllBrand.muted)
                }.listRowBackground(DistyllBrand.surface)
                Section("Distyll") {
                    Text("Pencil Bridge // Toolpath").font(DistyllBrand.mono(12)).foregroundStyle(DistyllBrand.muted)
                    NavigationLink("Font licences") { DistyllFontLicenses() }
                    Text("Space Grotesk, Inter and IBM Plex Mono are bundled under the SIL Open Font License. Licence notices ship with the app.")
                        .font(DistyllBrand.body(12)).foregroundStyle(DistyllBrand.muted)
                }.listRowBackground(DistyllBrand.surface)
            }.scrollContentBackground(.hidden).background(DistyllBrand.graphite)
                .navigationTitle("Tablet settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.buttonStyle(DistyllButtonStyle(primary: true, compact: true)) } }
        }.distyllAppearance()
    }
}

struct DistyllFontLicenses: View {
    private let families = [("Space Grotesk", "SpaceGrotesk-OFL"), ("Inter", "Inter-OFL"), ("IBM Plex Mono", "IBMPlexMono-OFL")]
    var body: some View {
        List {
            ForEach(families, id: \.1) { family, file in
                NavigationLink(family) {
                    ScrollView {
                        Text(contents(file)).font(DistyllBrand.body(13)).lineSpacing(6)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }.background(DistyllBrand.graphite).navigationTitle(family)
                }.listRowBackground(DistyllBrand.surface)
            }
        }.scrollContentBackground(.hidden).background(DistyllBrand.graphite)
            .navigationTitle("Font licences")
    }
    private func contents(_ file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "FontLicenses"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "Licence notice unavailable in this build." }
        return text
    }
}
