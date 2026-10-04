import AppKit
import Foundation

// Run from the project root: swift Tools/GenerateFlatLogo.swift
// The source is kept as code so every icon size uses the same flat geometry.
private let blue = NSColor(srgbRed: CGFloat(0x17) / 255, green: CGFloat(0x48) / 255,
                           blue: CGFloat(0xA5) / 255, alpha: 1)
private let mint = NSColor(srgbRed: CGFloat(0x20) / 255, green: CGFloat(0xDD) / 255,
                           blue: CGFloat(0xB0) / 255, alpha: 1)
private let white = NSColor.white

private func icon(size: Int, macOS: Bool) -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size,
                                pixelsHigh: size, bitsPerSample: 8,
                                samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setShouldAntialias(true)
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    blue.setFill()
    let tile = macOS
        ? NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948),
                       xRadius: 216, yRadius: 216)
        : NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    tile.fill()

    func drawLink(mirrored: Bool) {
        let path = NSBezierPath()
        path.lineWidth = 104
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: mirrored ? 1024 - x : x, y: y)
        }
        path.move(to: point(428, 674))
        path.curve(to: point(292, 729),
                   controlPoint1: point(397, 708), controlPoint2: point(342, 735))
        path.curve(to: point(188, 626),
                   controlPoint1: point(231, 720), controlPoint2: point(190, 680))
        path.curve(to: point(188, 398),
                   controlPoint1: point(151, 559), controlPoint2: point(151, 465))
        path.curve(to: point(292, 295),
                   controlPoint1: point(190, 344), controlPoint2: point(231, 304))
        path.curve(to: point(428, 350),
                   controlPoint1: point(342, 289), controlPoint2: point(397, 316))
        path.stroke()
    }

    white.setStroke()
    drawLink(mirrored: false)
    drawLink(mirrored: true)

    mint.setFill()
    NSBezierPath(roundedRect: NSRect(x: 399, y: 468, width: 226, height: 88),
                 xRadius: 44, yRadius: 44).fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return image.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let mac = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let ios = root.appendingPathComponent("iOS/Assets.xcassets/AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try icon(size: size, macOS: true)
        .write(to: mac.appendingPathComponent("icon_\(size)x\(size).png"))
}
let master = icon(size: 1024, macOS: false)
try master.write(to: root.appendingPathComponent("Resources/logo-source.png"))
try master.write(to: ios.appendingPathComponent("icon.png"))
