import AppKit
import Foundation

// Original product mark: an input surface and a single orange pen.
// This is not the personal M/A monogram, and uses no SF Symbols artwork.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func render(size: Int, mac: Bool, to url: URL) throws {
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    color(0x1C1E22).setFill()
    let inset: CGFloat = mac ? 64 : 0
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset),
                 xRadius: mac ? 180 : 0, yRadius: mac ? 180 : 0).fill()
    NSColor.white.setStroke()
    let plate = NSBezierPath(roundedRect: NSRect(x: 214, y: 270, width: 596, height: 470), xRadius: 58, yRadius: 58)
    plate.lineWidth = 22; plate.stroke()
    // A graphite clearance channel separates the pen from the plate boundary.
    let channel = NSBezierPath()
    channel.move(to: NSPoint(x: 370, y: 305)); channel.line(to: NSPoint(x: 730, y: 665))
    color(0x1C1E22).setStroke(); channel.lineWidth = 100; channel.lineCapStyle = .round; channel.stroke()
    let pen = NSBezierPath()
    let points = [NSPoint(x: 340, y: 260), NSPoint(x: 410, y: 280), NSPoint(x: 760, y: 630),
                  NSPoint(x: 700, y: 690), NSPoint(x: 350, y: 340)]
    pen.move(to: points[0]); points.dropFirst().forEach { pen.line(to: $0) }; pen.close()
    color(0xFF5A1F).setFill(); pen.fill()
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: 350, y: 340)); seam.line(to: NSPoint(x: 410, y: 280))
    color(0x1C1E22).setStroke(); seam.lineWidth = 10; seam.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
}
func writeCatalog(_ platform: String, images: [[String: String]]) throws {
    let assets = root.appendingPathComponent(platform + "/Assets.xcassets")
    let icon = assets.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
    let info: [String: Any] = ["info": ["author": "xcode", "version": 1], "images": images]
    try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: icon.appendingPathComponent("Contents.json"))
    try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys]).write(to: assets.appendingPathComponent("Contents.json"))
}
try writeCatalog("iPad", images: [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "AppIcon.png"]])
try render(size: 1024, mac: false, to: root.appendingPathComponent("iPad/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
var images: [[String: String]] = []
for logical in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "AppIcon-\(logical)@\(scale)x.png"
        images.append(["idiom": "mac", "size": "\(logical)x\(logical)", "scale": "\(scale)x", "filename": name])
    }
}
try writeCatalog("Mac", images: images)
for logical in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try render(size: logical * scale, mac: true, to: root.appendingPathComponent("Mac/Assets.xcassets/AppIcon.appiconset/AppIcon-\(logical)@\(scale)x.png"))
    }
}
print("Rendered Distyll Pencil Bridge product icons.")
