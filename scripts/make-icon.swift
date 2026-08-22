import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make-icon.swift <output.icns>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MetaShieldIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetURL) }

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "MetaShieldIcon", code: 1)
    }

    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MetaShieldIcon", code: 2)
    }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 220, yRadius: 220)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.29, green: 0.12, blue: 0.78, alpha: 1)
    ])!.draw(in: tile, angle: -55)

    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 830))
    shield.curve(to: NSPoint(x: 255, y: 705), controlPoint1: NSPoint(x: 430, y: 790), controlPoint2: NSPoint(x: 340, y: 748))
    shield.line(to: NSPoint(x: 255, y: 492))
    shield.curve(to: NSPoint(x: 512, y: 186), controlPoint1: NSPoint(x: 255, y: 335), controlPoint2: NSPoint(x: 362, y: 236))
    shield.curve(to: NSPoint(x: 769, y: 492), controlPoint1: NSPoint(x: 662, y: 236), controlPoint2: NSPoint(x: 769, y: 335))
    shield.line(to: NSPoint(x: 769, y: 705))
    shield.curve(to: NSPoint(x: 512, y: 830), controlPoint1: NSPoint(x: 684, y: 748), controlPoint2: NSPoint(x: 594, y: 790))
    shield.close()
    NSColor.white.withAlphaComponent(0.96).setFill()
    shield.fill()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: 362, y: 500))
    check.line(to: NSPoint(x: 470, y: 390))
    check.line(to: NSPoint(x: 674, y: 615))
    check.lineWidth = 66
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor(calibratedRed: 0.17, green: 0.28, blue: 0.82, alpha: 1).setStroke()
    check.stroke()

    let sparkle = NSBezierPath()
    sparkle.move(to: NSPoint(x: 740, y: 860))
    sparkle.curve(to: NSPoint(x: 785, y: 815), controlPoint1: NSPoint(x: 748, y: 835), controlPoint2: NSPoint(x: 760, y: 823))
    sparkle.curve(to: NSPoint(x: 830, y: 860), controlPoint1: NSPoint(x: 810, y: 823), controlPoint2: NSPoint(x: 822, y: 835))
    sparkle.curve(to: NSPoint(x: 785, y: 905), controlPoint1: NSPoint(x: 822, y: 885), controlPoint2: NSPoint(x: 810, y: 897))
    sparkle.curve(to: NSPoint(x: 740, y: 860), controlPoint1: NSPoint(x: 760, y: 897), controlPoint2: NSPoint(x: 748, y: 885))
    sparkle.close()
    NSColor.white.setFill()
    sparkle.fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MetaShieldIcon", code: 3)
    }
    return png
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, pixels) in entries {
    try drawIcon(pixels: pixels).write(to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
