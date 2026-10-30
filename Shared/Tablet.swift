import Foundation
import CoreGraphics

struct DisplayInfo: Codable, Equatable {
    var name: String
    var width: Double
    var height: Double
    var valid: Bool { !name.isEmpty && name.count <= 200 && width.isFinite && height.isFinite && (1...32768).contains(width) && (1...32768).contains(height) }
    var aspect: Double { width / height }
}

enum PressureFeel: String, CaseIterable {
    case light = "Light", natural = "Natural", firm = "Firm"
    var exponent: Double {
        switch self { case .light: return 0.65; case .natural: return 1; case .firm: return 1.6 }
    }
    func apply(_ pressure: Double) -> Double {
        guard pressure.isFinite else { return 0 }
        return pow(min(1, max(0, pressure)), exponent)
    }
}

enum FingerInput: String, CaseIterable {
    case trackpad = "Trackpad", gestures = "Gestures only", off = "Off"
}

struct TabletControl: Codable {
    enum Action: String, Codable {
        case undo, redo, brush, eraser, smallerBrush, largerBrush, zoomIn, zoomOut, fit, nextDisplay, scroll
        case trackpadBegin, relativeMove, trackpadEnd, click, secondaryClick, dragBegin, dragEnd
    }
    var action: Action
    var dx: Double = 0
    var dy: Double = 0
    var valid: Bool { dx.isFinite && dy.isFinite && abs(dx) <= 2000 && abs(dy) <= 2000 }
}

struct AppContext: Codable, Identifiable {
    var name: String
    var bundleID: String
    var id: String { bundleID }
    var valid: Bool { !name.isEmpty && name.count <= 200 && bundleID.count <= 255 }
}

struct ShortcutBinding: Codable, Equatable {
    var key: UInt16
    var command = false
    var shift = false
    var option = false
    var control = false
    var valid: Bool { key <= 127 }
}

struct FingerPointerState {
    private(set) var point: CGPoint?
    private(set) var held = false
    mutating func begin(at point: CGPoint, dragging: Bool) -> [PointerAction] {
        var actions = reset()
        self.point = point; held = dragging
        if dragging { actions.append(.down(point.x, point.y)) }
        return actions
    }
    mutating func move(to point: CGPoint) -> [PointerAction] {
        guard self.point != nil else { return [] }
        self.point = point
        return [held ? .drag(point.x, point.y) : .move(point.x, point.y)]
    }
    mutating func reset() -> [PointerAction] {
        defer { point = nil; held = false }
        if held, let point { return [.up(point.x, point.y)] }
        return []
    }
}

// Retain proportions: a circle on the active area stays a circle on the display.
enum TabletMapping {
    static func area(width: Double, height: Double, aspect: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0, aspect.isFinite, aspect > 0 else { return (0, 0, 0, 0) }
        let w = min(width, height * aspect), h = min(height, width / aspect)
        return ((width - w) / 2, (height - h) / 2, w, h)
    }
}
