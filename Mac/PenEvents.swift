import AppKit
import CoreGraphics

enum PenEvents {
    static let deviceID: Int64 = 1
    static func mouse(type: CGEventType, point: CGPoint, source: CGEventSource?, number: Int64,
                      sample: PencilSample? = nil, clickCount: Int64 = 1) -> CGEvent? {
        let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
        event.setIntegerValueField(.mouseEventNumber, value: number)
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        if let sample, sample.mode == .draw {
            let contact = type == .leftMouseDown || type == .leftMouseDragged
            let pressure = contact ? sample.pressure : 0
            event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
            event.setIntegerValueField(.tabletEventPointX, value: Int64(sample.x * 65535))
            event.setIntegerValueField(.tabletEventPointY, value: Int64(sample.y * 65535))
            event.setIntegerValueField(.tabletEventPointButtons, value: contact ? 1 : 0)
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: sample.tiltX ?? 0)
            event.setDoubleValueField(.tabletEventTiltY, value: sample.tiltY ?? 0)
        }
        return event
    }
    static func proximity(enter: Bool, point: CGPoint, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(source: source) else { return nil }
        event.type = .tabletProximity
        event.location = point
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: 1) // NX_TABLET_POINTER_PEN
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7) // device, X/Y, buttons, tilt X/Y, pressure
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        return event
    }
    static func keys(for action: TabletControl.Action) -> (CGKeyCode, CGEventFlags)? {
        switch action {
        case .undo: return (6, .maskCommand)
        case .redo: return (6, [.maskCommand, .maskShift])
        case .brush: return (11, [])
        case .eraser: return (14, [])
        case .smallerBrush: return (33, [])
        case .largerBrush: return (30, [])
        case .zoomIn: return (24, .maskCommand)
        case .zoomOut: return (27, .maskCommand)
        case .fit: return (29, .maskCommand)
        default: return nil
        }
    }
    static func defaultBinding(for action: TabletControl.Action) -> ShortcutBinding? {
        guard let (key, flags) = keys(for: action) else { return nil }
        return ShortcutBinding(key: key, command: flags.contains(.maskCommand), shift: flags.contains(.maskShift),
                               option: flags.contains(.maskAlternate), control: flags.contains(.maskControl))
    }
    static func flags(for binding: ShortcutBinding) -> CGEventFlags {
        var flags: CGEventFlags = []
        if binding.command { flags.insert(.maskCommand) }
        if binding.shift { flags.insert(.maskShift) }
        if binding.option { flags.insert(.maskAlternate) }
        if binding.control { flags.insert(.maskControl) }
        return flags
    }
}
