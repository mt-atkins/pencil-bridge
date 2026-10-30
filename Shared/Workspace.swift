import Foundation
import CoreGraphics

struct WindowTarget: Codable, Equatable, Identifiable {
    var id: UInt32
    var pid: Int32
    var app: String
    var title: String
    var bundleID: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool {
        id > 0 && pid > 0 && !app.isEmpty && app.count <= 80 && title.count <= 100 && bundleID.count <= 255 &&
        [x, y, width, height].allSatisfy(\.isFinite) && abs(x) <= 100_000 && abs(y) <= 100_000 &&
        (1...32768).contains(width) && (1...32768).contains(height)
    }
    func permits(frontPID: Int32?, frontWindow: UInt32?) -> Bool { frontPID == pid && frontWindow == id }
}

struct WorkspaceState: Codable, Equatable {
    var windows: [WindowTarget] = []
    var selected: WindowTarget?
    var locked = false
    var inputAllowed = true
    var previewEnabled = false
    var previewStatus = "Choose a Mac window for its ghost preview."
    var previewService: String?
    var previewSecret: String?
    var forTransport: WorkspaceState {
        var bounded = self
        // Window titles may contain multibyte text. Reserve room for welcome metadata as well.
        while !bounded.windows.isEmpty,
              (try? PacketFramer.encode(Packet(kind: .workspace, workspace: bounded)).count) ?? Int.max > 5000 {
            bounded.windows.removeLast()
        }
        return bounded
    }
    var valid: Bool {
        windows.count <= 12 && windows.allSatisfy(\.valid) && (selected == nil || selected!.valid) &&
        (!locked || selected != nil) && previewStatus.count <= 200 &&
        (previewService == nil || (previewService!.count <= 80 && !previewService!.isEmpty)) &&
        (previewSecret == nil || (previewSecret!.count == 64 && previewSecret!.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }))
    }
}

struct WorkspaceRequest: Codable {
    var windowID: UInt32?
    var clearSelection: Bool? = nil
    var locked: Bool? = nil
    var preview: Bool? = nil
}

struct PreviewFrame: Codable {
    var windowID: UInt32
    var jpeg: Data
    var valid: Bool { windowID > 0 && !jpeg.isEmpty && jpeg.count <= 90_000 }
}
