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
                ToolbarItem(placement: .navigationBarLeading) {
                    if bridge.connected || bridge.connecting { Button("Disconnect") { bridge.disconnect() } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { bridge.cancelStroke(); showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Tablet settings and pen test")
                }
            }
        }
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
            }
        }
        .sheet(isPresented: $showSettings) { TabletSettings(bridge: bridge) }
        .onChange(of: scenePhase) { phase in
            if phase == .background { showScanner = false; bridge.suspend() }
            else if phase == .inactive { bridge.cancelStroke() }
        }
        .onChange(of: bridge.connected) { UIApplication.shared.isIdleTimerDisabled = $0 }
    }
    private var pairing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 52)).foregroundStyle(.teal)
                Text("Your iPad. Your pen tablet.").font(.largeTitle.bold())
                Text("Start sharing on your Mac, then scan its QR code or enter the four-digit code.")
                    .foregroundStyle(.secondary)
                Button { showScanner = true } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(bridge.connecting)
                Divider()
                Text("Or enter the join code").font(.headline)
                TextField("0000", text: $bridge.code)
                    .focused($codeFocused)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Four-digit join code")
                    .onChange(of: bridge.code) { value in
                        let filtered = String(value.filter { "0123456789".contains($0) }.prefix(4))
                        if filtered != value { bridge.code = filtered }
                        if Bridge.validJoinCode(filtered) { codeFocused = false }
                    }
                HStack {
                    Text(bridge.status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Find Mac") { bridge.search() }.disabled(bridge.connecting)
                }
                ForEach(bridge.hosts, id: \.endpoint) { host in
                    Button { bridge.connect(to: host) } label: {
                        HStack { Image(systemName: "desktopcomputer"); Text(TabletBridge.name(host)); Spacer(); Image(systemName: "arrow.right.circle.fill") }
                            .padding(12)
                    }.buttonStyle(.bordered)
                        .disabled(!Bridge.validJoinCode(bridge.code) || bridge.connecting)
                }
                if bridge.connecting { ProgressView("Pairing…") }
                Text("Both devices must be on the same local network.").font(.footnote).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
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
                if let ms = bridge.latencyMS { Text("\(Int(ms)) ms round trip").monospacedDigit().foregroundStyle(.secondary) }
            }.font(.caption).padding(.horizontal, 20)
            Picker("Input mode", selection: $bridge.mode) {
                Text("Pen").tag(InputMode.draw)
                Text("Pointer").tag(InputMode.pointer)
                Text("Pan").tag(InputMode.pan)
            }.pickerStyle(.segmented).padding(.horizontal, 20)
                .onChange(of: bridge.mode) { _ in bridge.cancelStroke() }
            HStack(spacing: 4) {
                if !leftHanded { rail }
                Canvas(bridge: bridge).clipShape(RoundedRectangle(cornerRadius: 20))
                if leftHanded { rail }
            }.padding(.horizontal, 8)
            Text(bridge.mode == .pan ? "Pencil contact pans with Space + drag. Lift to release." : "Pencil to draw · fingers to point · two fingers to scroll · pinch to zoom")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
        }
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
        } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(title).font(.system(size: 10)) }
                .frame(width: 60, height: 48).contentShape(Rectangle())
        }.buttonStyle(.borderless).accessibilityLabel(title)
    }
}

struct TabletSettings: View {
    @ObservedObject var bridge: TabletBridge
    @Environment(\.dismiss) private var dismiss
    @AppStorage("leftHanded") private var leftHanded = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Tip feel") {
                    Picker("Pressure response", selection: $bridge.pressureFeel) {
                        ForEach(PressureFeel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Light reaches full pressure with less force. Firm gives more room for delicate strokes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    PenTestPad(feel: bridge.pressureFeel).frame(height: 220)
                    Text("Try your Pencil here. This test pad does not send input to your Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Workspace") {
                    Toggle("Left-handed controls", isOn: $leftHanded)
                    Toggle("Keep display proportions", isOn: $bridge.preserveProportions)
                        .onChange(of: bridge.preserveProportions) { _ in bridge.cancelStroke() }
                    Text("Uses a proportional active area so circles stay circular on your Mac.").font(.footnote).foregroundStyle(.secondary)
                    Picker("Finger input", selection: $bridge.fingerInput) {
                        ForEach(FingerInput.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.onChange(of: bridge.fingerInput) { _ in bridge.cancelStroke() }
                    if bridge.fingerInput == .trackpad {
                        HStack { Text("Pointer speed"); Slider(value: $bridge.fingerSpeed, in: 0.5...3, step: 0.1) }
                        Text("One finger moves; tap to click; two-finger tap for secondary click; three fingers drag. Pinch uses your app’s zoom shortcuts.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Touch gestures pause during Pencil contact and briefly after lifting to reject resting fingers.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Drawing apps") {
                    Text("Shortcuts follow the active Mac app. Use Edit Shortcuts in the Mac companion to customize each app’s keys and modifiers.").font(.footnote)
                    Text("Brush, eraser and size buttons use B, E, [ and ]. Zoom uses ⌘+/− and Fit uses ⌘0. Pan holds Space while the Pencil touches. Your Mac app must support these shortcuts.")
                        .font(.footnote)
                    Text("Pressure and tilt are sent as macOS tablet events. Support depends on the drawing app. First-generation Apple Pencil does not provide hover or a double-tap button.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Tablet settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
