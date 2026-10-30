import SwiftUI
import UIKit

final class PencilSurface: UIView, UIGestureRecognizerDelegate {
    var onSample: ((PencilSample) -> Void)?
    var onSamples: (([PencilSample]) -> Void)?
    var onGesture: ((TabletControl) -> Void)?
    var mode = InputMode.draw
    var enabled = false
    var pressureFeel = PressureFeel.natural
    var displayAspect = 16.0 / 9.0
    var preserveProportions = true
    var gesturesEnabled = true
    var trackpadEnabled = true
    var fingerSpeed = 1.5
    var generation = 0
    var accentCursor = true
    private struct Dot { let point: CGPoint; let pressure: CGFloat }
    private var active: UITouch?
    private var activeMode = InputMode.draw
    private var trail: [Dot] = []
    private var strokeOrigin = CGPoint.zero
    private var strokeMoved = false
    private var previousSize = CGSize.zero
    private var lastPencilTime = -Double.infinity
    private var pressure: Double = 0
    private var pan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var fingerPan: UIPanGestureRecognizer!
    private var fingerDrag: UIPanGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var secondaryTap: UITapGestureRecognizer!
    private var fingerRecognizers: [UIGestureRecognizer] { [pan, pinch, fingerPan, fingerDrag, tap, secondaryTap].compactMap { $0 } }
    private var lastZoomTime = -Double.infinity

    var activeArea: CGRect {
        guard preserveProportions else { return bounds.insetBy(dx: 12, dy: 12) }
        let fitted = TabletMapping.area(width: max(0, bounds.width - 24), height: max(0, bounds.height - 24), aspect: displayAspect)
        return CGRect(x: fitted.x + 12, y: fitted.y + 12, width: fitted.width, height: fitted.height)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DistyllBrand.ui(DistyllBrand.graphiteHex)
        isMultipleTouchEnabled = true
        contentMode = .redraw
        pan = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:)))
        fingerPan = UIPanGestureRecognizer(target: self, action: #selector(point(_:)))
        fingerPan.minimumNumberOfTouches = 1; fingerPan.maximumNumberOfTouches = 1
        fingerDrag = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        fingerDrag.minimumNumberOfTouches = 3; fingerDrag.maximumNumberOfTouches = 3
        tap = UITapGestureRecognizer(target: self, action: #selector(click(_:)))
        secondaryTap = UITapGestureRecognizer(target: self, action: #selector(secondaryClick(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        tap.require(toFail: secondaryTap)
        for recognizer in fingerRecognizers {
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var parent = superview
        while let view = parent {
            if let scroll = view as? UIScrollView {
                scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            }
            parent = view.superview
        }
    }
    func cancel() {
        let wasActive = active != nil
        if active != nil { onSample?(PencilSample(phase: .cancel, x: 0.5, y: 0.5, pressure: 0, mode: activeMode)) }
        active = nil; pressure = 0
        trail.removeAll(keepingCapacity: true)
        setNeedsDisplay()
        if wasActive { finishContact() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { cancel(); previousSize = bounds.size }
    }
    private func trackMovement(_ touch: UITouch) {
        let area = activeArea
        guard area.width > 0, area.height > 0 else { return }
        let p = touch.preciseLocation(in: self)
        if hypot((p.x - strokeOrigin.x) / area.width, (p.y - strokeOrigin.y) / area.height) > 0.012 { strokeMoved = true }
    }
    private func capture(_ touch: UITouch, _ phase: InputPhase) -> PencilSample {
        let p = touch.preciseLocation(in: self), area = activeArea
        if phase == .down { strokeOrigin = p; strokeMoved = false; trail.removeAll(keepingCapacity: true) }
        else { trackMovement(touch) }
        let raw = touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : 0
        pressure = phase == .up ? 0 : pressureFeel.apply(raw)
        let altitude = Double(touch.altitudeAngle), azimuth = Double(touch.azimuthAngle(in: self))
        let tiltX = atan2(cos(altitude) * cos(azimuth), sin(altitude)) / (.pi / 2)
        let tiltY = atan2(cos(altitude) * sin(azimuth), sin(altitude)) / (.pi / 2)
        let sample = PencilSample(phase: phase,
            x: Double(min(1, max(0, (p.x - area.minX) / max(1, area.width)))),
            y: Double(min(1, max(0, (p.y - area.minY) / max(1, area.height)))),
            pressure: pressure, mode: activeMode, strokeMoved: strokeMoved, tiltX: tiltX, tiltY: tiltY)
        trail.append(Dot(point: CGPoint(x: min(area.maxX, max(area.minX, p.x)), y: min(area.maxY, max(area.minY, p.y))), pressure: CGFloat(pressure)))
        if trail.count > 256 { trail.removeFirst(trail.count - 256) }
        setNeedsDisplay()
        return sample
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, active == nil, let pencil = touches.first(where: { $0.type == .pencil }),
              activeArea.contains(pencil.preciseLocation(in: self)) else { return }
        active = pencil; activeMode = mode
        lastPencilTime = ProcessInfo.processInfo.systemUptime
        fingerRecognizers.forEach { $0.isEnabled = false }
        let sample = capture(pencil, .down)
        onSample?(sample)
        AudioFeedback.shared.play(.pencil)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, let active, touches.contains(active) else { return }
        let history = event?.coalescedTouches(for: active) ?? [active]
        for touch in history { trackMovement(touch) }
        let delivered = activeMode == .pointer ? [history.last ?? active] : Array(history.suffix(16))
        let samples = delivered.map { capture($0, .move) }
        if let onSamples { onSamples(samples) } else { samples.forEach { onSample?($0) } }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        let sample = capture(active, .up)
        onSample?(sample)
        self.active = nil
        finishContact()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        cancel(); finishContact()
    }
    private func finishContact() {
        lastPencilTime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.active == nil, ProcessInfo.processInfo.systemUptime - self.lastPencilTime >= 0.34 else { return }
            self.fingerRecognizers.forEach { $0.isEnabled = true }
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if !trackpadEnabled, [fingerPan, fingerDrag, tap, secondaryTap].contains(where: { $0 === gestureRecognizer }) { return false }
        return enabled && gesturesEnabled && active == nil && ProcessInfo.processInfo.systemUptime - lastPencilTime > 0.3
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    @objc private func point(_ recognizer: UIPanGestureRecognizer) { relative(recognizer, dragging: false) }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) { relative(recognizer, dragging: true) }
    private func relative(_ recognizer: UIPanGestureRecognizer, dragging: Bool) {
        // Always deliver the end, including cancellation caused by a new Pencil contact.
        if recognizer.state == .cancelled || recognizer.state == .failed {
            onGesture?(TabletControl(action: dragging ? .dragEnd : .trackpadEnd)); return
        }
        guard enabled, gesturesEnabled, trackpadEnabled, active == nil else { return }
        if recognizer.state == .began {
            onGesture?(TabletControl(action: dragging ? .dragBegin : .trackpadBegin))
            if dragging { AudioFeedback.shared.play(.click) }
        }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        if delta != .zero { onGesture?(TabletControl(action: .relativeMove, dx: Double(delta.x) * fingerSpeed, dy: Double(delta.y) * fingerSpeed)) }
        if recognizer.state == .ended { onGesture?(TabletControl(action: dragging ? .dragEnd : .trackpadEnd)) }
    }
    @objc private func click(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended, active == nil, trackpadEnabled {
            onGesture?(TabletControl(action: .click))
            AudioFeedback.shared.play(.click)
        }
    }
    @objc private func secondaryClick(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended, active == nil, gesturesEnabled {
            onGesture?(TabletControl(action: .secondaryClick))
            AudioFeedback.shared.play(.click)
        }
    }
    @objc private func scroll(_ recognizer: UIPanGestureRecognizer) {
        guard enabled, gesturesEnabled, active == nil, pinch.state != .began, pinch.state != .changed else { recognizer.setTranslation(.zero, in: self); return }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        if recognizer.state == .changed {
            onGesture?(TabletControl(action: .scroll, dx: Double(-delta.x), dy: Double(delta.y)))
        }
    }
    @objc private func zoom(_ recognizer: UIPinchGestureRecognizer) {
        guard enabled, gesturesEnabled, active == nil, recognizer.state == .changed else { return }
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastZoomTime > 0.1 else { return }
        if recognizer.scale > 1.12 || recognizer.scale < 0.89 {
            onGesture?(TabletControl(action: recognizer.scale > 1 ? .zoomIn : .zoomOut))
            recognizer.scale = 1; lastZoomTime = time
        }
    }
    override func draw(_ rect: CGRect) {
        let area = activeArea
        DistyllBrand.ui(DistyllBrand.surfaceHex).setFill()
        UIBezierPath(roundedRect: area, cornerRadius: 16).fill()
        DistyllBrand.ui(DistyllBrand.lineHex).setStroke()
        let outline = UIBezierPath(roundedRect: area, cornerRadius: 16)
        outline.lineWidth = 1 / UIScreen.main.scale; outline.stroke()
        let grid = UIBezierPath()
        let inset = min(area.width, area.height) * 0.07
        for y in stride(from: area.minY + inset, to: max(area.minY + inset, area.maxY - max(40, inset)), by: 10) {
            grid.move(to: CGPoint(x: area.minX + inset, y: y)); grid.addLine(to: CGPoint(x: area.maxX - inset, y: y))
        }
        UIColor.white.withAlphaComponent(0.045).setStroke(); grid.lineWidth = 1 / UIScreen.main.scale; grid.stroke()
        UIColor.white.withAlphaComponent(0.8).setStroke()
        for pair in zip(trail, trail.dropFirst()) {
            let segment = UIBezierPath(); segment.move(to: pair.0.point); segment.addLine(to: pair.1.point)
            segment.lineWidth = activeMode == .draw ? 1 + pair.1.pressure * 5 : 1
            segment.lineCapStyle = .round; segment.stroke()
        }
        if let last = trail.last {
            (accentCursor ? DistyllBrand.ui(DistyllBrand.orangeHex) : UIColor.white).setFill()
            UIBezierPath(ovalIn: CGRect(x: last.point.x - 3, y: last.point.y - 3, width: 6, height: 6)).fill()
        }
        let label = "TIP \(Int(pressure * 100))%"
        label.draw(at: CGPoint(x: area.minX + 14, y: area.maxY - 28), withAttributes: [.font: DistyllBrand.uiMono(11), .foregroundColor: DistyllBrand.ui(DistyllBrand.mutedHex)])
    }
}

struct Canvas: UIViewRepresentable {
    @ObservedObject var bridge: TabletBridge
    func makeUIView(context: Context) -> PencilSurface {
        let view = PencilSurface()
        view.onSample = { [weak bridge] in bridge?.send($0) }
        view.onSamples = { [weak bridge] in bridge?.send($0) }
        view.onGesture = { [weak bridge] in bridge?.gesture($0) }
        return view
    }
    func updateUIView(_ view: PencilSurface, context: Context) {
        let aspect = bridge.display?.aspect ?? 16 / 9
        if view.mode != bridge.mode || !bridge.connected || view.generation != bridge.resetGeneration ||
           view.displayAspect != aspect || view.preserveProportions != bridge.preserveProportions { view.cancel() }
        view.generation = bridge.resetGeneration; view.mode = bridge.mode
        view.enabled = bridge.connected; view.pressureFeel = bridge.pressureFeel
        view.displayAspect = aspect; view.preserveProportions = bridge.preserveProportions
        view.gesturesEnabled = bridge.fingerInput != .off
        view.trackpadEnabled = bridge.fingerInput == .trackpad
        view.fingerSpeed = bridge.fingerSpeed
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: PencilSurface, coordinator: ()) { view.cancel() }
}

struct PenTestPad: UIViewRepresentable {
    let feel: PressureFeel
    func makeUIView(context: Context) -> PencilSurface {
        let view = PencilSurface(); view.enabled = true; view.preserveProportions = false
        view.gesturesEnabled = false
        view.accentCursor = false
        return view
    }
    func updateUIView(_ view: PencilSurface, context: Context) { view.pressureFeel = feel }
    static func dismantleUIView(_ view: PencilSurface, coordinator: ()) { view.cancel() }
}
