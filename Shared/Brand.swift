import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Distyll's Toolpath palette, with tonal surfaces from the Notch application guide.
enum DistyllBrand {
    static let graphiteHex: UInt32 = 0x1C1E22
    static let surfaceHex: UInt32 = 0x24262B
    static let recessedHex: UInt32 = 0x2B2E34
    static let lineHex: UInt32 = 0x36393F
    static let mutedHex: UInt32 = 0x9AA3AE
    static let orangeHex: UInt32 = 0xFF5A1F
    static let graphite = color(graphiteHex)
    static let surface = color(surfaceHex)
    static let recessed = color(recessedHex)
    static let line = color(lineHex)
    static let muted = color(mutedHex)
    static let ink = Color.white
    static let orange = color(orangeHex)
    static let buildPlate = color(0xEDEFF2)
    static let bodyInk = color(0x3A3F47)
    static let blue = color(0x0E63B3)
    static let fonts = ["SpaceGrotesk-Bold", "Inter-Regular", "Inter-SemiBold", "IBMPlexMono-Regular", "IBMPlexMono-Medium"]

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    static func registerFonts(in bundle: Bundle = .main) {
        for name in fonts {
            if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
    private static func available(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: name, size: 14) != nil
        #else
        return NSFont(name: name, size: 14) != nil
        #endif
    }
    static func display(_ size: CGFloat) -> Font {
        available("SpaceGrotesk-Bold") ? .custom("SpaceGrotesk-Bold", size: size, relativeTo: .title) : .system(size: size, weight: .bold)
    }
    static func body(_ size: CGFloat = 15, strong: Bool = false) -> Font {
        let name = strong ? "Inter-SemiBold" : "Inter-Regular"
        return available(name) ? .custom(name, size: size, relativeTo: .body) : .system(size: size, weight: strong ? .semibold : .regular)
    }
    static func mono(_ size: CGFloat = 12, strong: Bool = false) -> Font {
        let name = strong ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return available(name) ? .custom(name, size: size, relativeTo: .caption) : .system(size: size, weight: strong ? .medium : .regular, design: .monospaced)
    }
    #if canImport(UIKit)
    static func ui(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static func uiMono(_ size: CGFloat) -> UIFont {
        UIFont(name: "IBMPlexMono-Regular", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
    #endif
}

struct DistyllProductMark: View {
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(DistyllBrand.surface)
            RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(DistyllBrand.line, lineWidth: 1)
            RoundedRectangle(cornerRadius: size * 0.055)
                .stroke(DistyllBrand.ink, lineWidth: max(1, size * 0.022))
                .frame(width: size * 0.58, height: size * 0.46)
            Path { path in
                path.move(to: CGPoint(x: size * 0.37, y: size * 0.70))
                path.addLine(to: CGPoint(x: size * 0.73, y: size * 0.34))
            }.stroke(DistyllBrand.surface, style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round))
            Path { path in
                let points: [CGPoint] = [.init(x: 0.34, y: 0.74), .init(x: 0.41, y: 0.72),
                    .init(x: 0.76, y: 0.37), .init(x: 0.70, y: 0.31), .init(x: 0.35, y: 0.66)]
                path.move(to: CGPoint(x: points[0].x * size, y: points[0].y * size))
                for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x * size, y: point.y * size)) }
                path.closeSubpath()
            }.fill(DistyllBrand.ink)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DistyllLayerLines: View {
    var body: some View {
        SwiftUI.Canvas { context, size in
            let inset = size.width * 0.07
            for y in stride(from: 1.0, to: size.height, by: 10) {
                context.fill(Path(CGRect(x: inset, y: y, width: size.width - 2 * inset, height: 1)), with: .color(.white.opacity(0.045)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DistyllButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DistyllBrand.body(compact ? 13 : 15, strong: true))
            .foregroundStyle(primary ? DistyllBrand.graphite : DistyllBrand.ink)
            .padding(.horizontal, compact ? 12 : 18)
            .frame(minHeight: compact ? 44 : 48)
            .background(primary ? DistyllBrand.orange : DistyllBrand.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(primary ? .clear : DistyllBrand.line, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
    }
}

extension View {
    func distyllPanel(radius: CGFloat = 16, recessed: Bool = false) -> some View {
        background(recessed ? DistyllBrand.recessed : DistyllBrand.surface,
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DistyllBrand.line, lineWidth: 1))
    }
    func distyllAppearance() -> some View {
        font(DistyllBrand.body()).lineSpacing(5).foregroundStyle(DistyllBrand.ink)
            .tint(DistyllBrand.ink).preferredColorScheme(.dark)
    }
}
