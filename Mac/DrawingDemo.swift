import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class DrawingDemoModel: ObservableObject {
    @Published var brushSize = 12.0
    @Published var eraser = false
    @Published var pressure = 0.0
    @Published var tilt = CGPoint.zero
    @Published var tablet = false
    @Published var strokeCount = 0
    weak var canvas: DemoCanvasView?
    private var lastReadout = -Double.infinity

    func read(_ event: NSEvent, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastReadout > 1 / 30 else { return }
        lastReadout = now
        tablet = event.type == .tabletPoint || event.subtype == .tabletPoint
        pressure = tablet ? Double(event.pressure) : 0
        tilt = tablet ? event.tilt : .zero
    }
}

struct DrawingDemo: View {
    @StateObject private var model = DrawingDemoModel()
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drawing demo").font(DistyllBrand.display(24))
                    Text("Distyll // Pencil Bridge").font(DistyllBrand.mono(11)).foregroundStyle(DistyllBrand.muted)
                }
                Spacer()
                Button("Undo") { model.canvas?.undoStroke() }
                Button("Redo") { model.canvas?.redoStroke() }
                Button("Save PNG…") { model.canvas?.savePNG() }
                Button("Clear") { model.canvas?.clear() }.buttonStyle(DistyllButtonStyle(primary: true, compact: true))
            }
            HStack {
                Picker("Tool", selection: $model.eraser) {
                    Text("Brush").tag(false)
                    Text("Eraser").tag(true)
                }.pickerStyle(.segmented).frame(width: 180)
                Text("Size").font(DistyllBrand.body(13))
                Slider(value: $model.brushSize, in: 1...60).frame(maxWidth: 220)
                Text("\(Int(model.brushSize)) px").font(DistyllBrand.mono(12)).frame(width: 55)
                Spacer()
                Text("\(model.strokeCount) // strokes").font(DistyllBrand.mono(12))
            }
            DemoCanvas(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DistyllBrand.line, lineWidth: 1))
            HStack {
                Text(model.tablet ? "TABLET" : "MOUSE")
                Text(String(format: "TIP %3.0f%%", model.pressure * 100))
                Text(String(format: "TILT X %+.2f // Y %+.2f", model.tilt.x, model.tilt.y))
                Spacer()
                Text("B brush // E eraser // [ ] size // Cmd Z undo")
            }.font(DistyllBrand.mono(11)).foregroundStyle(DistyllBrand.muted)
            Text("Pair the iPad, choose Pen and enable tablet pressure and tilt on the Mac. Draw inside this canvas. Mouse input uses a fixed brush width.")
                .font(DistyllBrand.body(12)).foregroundStyle(DistyllBrand.muted)
        }.padding(20).background(DistyllBrand.graphite).distyllAppearance()
            .frame(minWidth: 820, minHeight: 560)
    }
}

struct DemoCanvas: NSViewRepresentable {
    @ObservedObject var model: DrawingDemoModel
    func makeNSView(context: Context) -> DemoCanvasView {
        let view = DemoCanvasView(model: model)
        model.canvas = view
        return view
    }
    func updateNSView(_ nsView: DemoCanvasView, context: Context) {}
}

/// Receives ordinary AppKit events, exactly as another drawing app would.
final class DemoCanvasView: NSView {
    struct Point { let position: CGPoint; let width: CGFloat }
    struct Stroke { var points: [Point]; let eraser: Bool }
    private let model: DrawingDemoModel
    private var strokes: [Stroke] = []
    private var redoStrokes: [Stroke] = []
    private var current: Stroke?
    private var bitmap: CGContext?
    private let background = CGColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
    private let ink = CGColor(red: 0.11, green: 0.12, blue: 0.13, alpha: 1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(model: DrawingDemoModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = max(1, Int(bounds.width.rounded(.up)))
        let height = max(1, Int(bounds.height.rounded(.up)))
        if bitmap?.width != width || bitmap?.height != height {
            bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            bitmap?.translateBy(x: 0, y: CGFloat(height))
            bitmap?.scaleBy(x: 1, y: -1)
            rebuild()
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = bitmap?.makeImage(), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        redoStrokes.removeAll()
        current = Stroke(points: [], eraser: model.eraser)
        append(event)
    }
    override func mouseDragged(with event: NSEvent) { if current != nil { append(event) } }
    override func mouseUp(with event: NSEvent) {
        if current != nil { append(event); finishStroke() }
        model.read(event, force: true)
    }
    override func tabletPoint(with event: NSEvent) { model.read(event) }
    override func tabletProximity(with event: NSEvent) {
        if !event.isEnteringProximity { finishStroke(); model.pressure = 0 }
    }
    override func resignFirstResponder() -> Bool { finishStroke(); model.pressure = 0; return true }

    private func append(_ event: NSEvent) {
        guard let eraser = current?.eraser else { return }
        let tablet = event.subtype == .tabletPoint
        let pressure = tablet ? CGFloat(max(0, min(1, event.pressure))) : 1
        let point = Point(position: convert(event.locationInWindow, from: nil),
                          width: max(0.6, model.brushSize * pressure))
        let previous = current?.points.last ?? point
        render(from: previous, to: point, eraser: eraser)
        current?.points.append(point)
        // Bound an exceptionally long uninterrupted stroke without losing its pixels.
        if (current?.points.count ?? 0) >= 20_000 {
            finishStroke()
            current = Stroke(points: [point], eraser: eraser)
        }
        model.read(event)
        needsDisplay = true
    }
    private func render(from start: Point, to end: Point, eraser: Bool) {
        guard let bitmap else { return }
        bitmap.setStrokeColor(eraser ? background : ink)
        bitmap.setFillColor(eraser ? background : ink)
        bitmap.setLineWidth((start.width + end.width) / 2)
        bitmap.setLineCap(.round)
        if start.position == end.position {
            bitmap.fillEllipse(in: CGRect(x: end.position.x - end.width / 2,
                y: end.position.y - end.width / 2, width: end.width, height: end.width))
        } else {
            bitmap.move(to: start.position); bitmap.addLine(to: end.position); bitmap.strokePath()
        }
    }
    private func finishStroke() {
        if let current, !current.points.isEmpty { strokes.append(current) }
        current = nil
        model.strokeCount = strokes.count
    }
    private func rebuild() {
        guard let bitmap else { return }
        bitmap.setFillColor(background)
        bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        for stroke in strokes + [current].compactMap({ $0 }) {
            guard let first = stroke.points.first else { continue }
            render(from: first, to: first, eraser: stroke.eraser)
            for pair in zip(stroke.points, stroke.points.dropFirst()) {
                render(from: pair.0, to: pair.1, eraser: stroke.eraser)
            }
        }
        needsDisplay = true
    }
    func clear() {
        current = nil; strokes.removeAll(); redoStrokes.removeAll(); model.strokeCount = 0
        rebuild()
    }
    func undoStroke() {
        finishStroke()
        if let stroke = strokes.popLast() { redoStrokes.append(stroke) }
        model.strokeCount = strokes.count; rebuild()
    }
    func redoStroke() {
        finishStroke()
        if let stroke = redoStrokes.popLast() { strokes.append(stroke) }
        model.strokeCount = strokes.count; rebuild()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if modifiers.contains(.shift) { redoStroke() } else { undoStroke() }
            return true
        }
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" {
            savePNG(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": model.eraser = false
        case "e": model.eraser = true
        case "[": model.brushSize = max(1, model.brushSize - 2)
        case "]": model.brushSize = min(60, model.brushSize + 2)
        default: super.keyDown(with: event)
        }
    }
    func savePNG() {
        guard let image = bitmap?.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Pencil Bridge drawing.png"
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}
