import AppKit

@main
struct DrawingDemoChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = DrawingDemoModel()
        let canvas = DemoCanvasView(model: model)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.layout()
        func snapshot() -> Data {
            let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])!
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let blank = snapshot()
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 100)))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 220, y: 100)))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 240, y: 100)))
        let stroke = snapshot()
        precondition(stroke != blank && model.strokeCount == 1, "Mouse stroke must draw on the canvas")
        canvas.undoStroke()
        precondition(snapshot() == blank && model.strokeCount == 0, "Undo must restore the blank canvas")
        canvas.redoStroke()
        precondition(snapshot() == stroke && model.strokeCount == 1, "Redo must restore the exact drawing")
        model.eraser = true; model.brushSize = 40
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 150, y: 100)))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 150, y: 100)))
        precondition(snapshot() != stroke && model.strokeCount == 2, "Eraser must change existing pixels")
        canvas.undoStroke()
        precondition(snapshot() == stroke, "Erasing must be undoable")
        canvas.clear()
        precondition(snapshot() == blank && model.strokeCount == 0, "Clear must remove all drawing")
        canvas.redoStroke()
        precondition(snapshot() == blank, "Clear must also discard redo history")
        let sample = PencilSample(phase: .down, x: 0.5, y: 0.5, pressure: 0.72,
                                 mode: .draw, tiltX: 0.25, tiltY: -0.4)
        let cg = PenEvents.mouse(type: .leftMouseDown, point: .zero, source: nil, number: 1, sample: sample)!
        model.read(NSEvent(cgEvent: cg)!, force: true)
        precondition(model.tablet && abs(model.pressure - 0.72) < 0.01, "Demo must recognize real AppKit tablet pressure")
        precondition(abs(model.tilt.x - 0.25) < 0.01 && abs(model.tilt.y + 0.4) < 0.01, "Demo must read tablet tilt")
        model.read(event(.mouseMoved, .zero), force: true)
        precondition(!model.tablet && model.pressure == 0 && model.tilt == .zero, "Mouse readouts must not claim tablet data")
        print("10 drawing demo checks passed")
    }
}
