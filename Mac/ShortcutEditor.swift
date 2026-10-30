import SwiftUI

struct ShortcutEditor: View {
    @ObservedObject var bridge: MacBridge
    let app: AppContext
    @Environment(\.dismiss) private var dismiss
    private let actions: [(TabletControl.Action, String)] = [
        (.undo, "Undo"), (.redo, "Redo"), (.brush, "Brush"), (.eraser, "Eraser"),
        (.smallerBrush, "Smaller brush"), (.largerBrush, "Larger brush"),
        (.zoomIn, "Zoom in"), (.zoomOut, "Zoom out"), (.fit, "Fit canvas")
    ]
    private let keys: [(String, UInt16)] = [
        ("A",0),("B",11),("C",8),("D",2),("E",14),("F",3),("G",5),("H",4),
        ("I",34),("J",38),("K",40),("L",37),("M",46),("N",45),("O",31),("P",35),
        ("Q",12),("R",15),("S",1),("T",17),("U",32),("V",9),("W",13),("X",7),("Y",16),("Z",6),
        ("0",29),("1",18),("2",19),("3",20),("4",21),("5",23),("6",22),("7",26),("8",28),("9",25),
        ("[",33),("]",30),("= / +",24),("−",27),("Space",49)
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shortcuts for \(app.name)").font(DistyllBrand.display(24))
            Text("These bindings are selected automatically when this Mac app is active.").foregroundStyle(DistyllBrand.muted)
            Form {
                ForEach(actions, id: \.0) { action, title in
                    HStack {
                        Text(title).frame(width: 115, alignment: .leading)
                        Picker("Key", selection: binding(action, \.key)) {
                            ForEach(keys, id: \.1) { symbol, code in Text(symbol).tag(code) }
                        }.labelsHidden().frame(width: 100)
                        Toggle("Cmd", isOn: binding(action, \.command)).accessibilityLabel("Command for \(title)")
                        Toggle("Shift", isOn: binding(action, \.shift)).accessibilityLabel("Shift for \(title)")
                        Toggle("Opt", isOn: binding(action, \.option)).accessibilityLabel("Option for \(title)")
                        Toggle("Ctrl", isOn: binding(action, \.control)).accessibilityLabel("Control for \(title)")
                    }
                }
            }
            HStack {
                Button("Reset to defaults") { bridge.resetShortcuts(app: app.bundleID) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(DistyllButtonStyle(primary: true, compact: true))
            }
        }.padding(24).frame(width: 680).background(DistyllBrand.graphite).distyllAppearance()
    }
    private func binding<Value>(_ action: TabletControl.Action, _ path: WritableKeyPath<ShortcutBinding, Value>) -> Binding<Value> {
        Binding(get: { bridge.shortcut(for: action, app: app.bundleID)![keyPath: path] }, set: { value in
            var shortcut = bridge.shortcut(for: action, app: app.bundleID)!
            shortcut[keyPath: path] = value
            bridge.setShortcut(shortcut, action: action, app: app.bundleID)
        })
    }
}
