import AppKit
import Foundation

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let t = AffineTransform(scale: CGFloat(size) / 1024); (t as NSAffineTransform).concat()
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 22, y: 22, width: 980, height: 980), xRadius: 224, yRadius: 224).fill()
    NSColor(calibratedRed: 0.75, green: 0.89, blue: 0.70, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 163, y: 440, width: 425, height: 420), xRadius: 45, yRadius: 45).fill()
    NSColor(calibratedRed: 0.88, green: 0.68, blue: 0.43, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 614, y: 440, width: 247, height: 420), xRadius: 45, yRadius: 45).fill()
    NSColor(calibratedRed: 0.57, green: 0.63, blue: 0.79, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 163, y: 164, width: 698, height: 250), xRadius: 45, yRadius: 45).fill()
    let star = NSBezierPath()
    let center = CGPoint(x: 374, y: 649)
    for i in 0..<8 {
        let angle = Double(i) * Double.pi / 4; let radius: Double = i % 2 == 0 ? 116 : 35
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        if i == 0 { star.move(to: point) } else { star.line(to: point) }
    }
    star.close(); NSColor(calibratedRed: 0.17, green: 0.35, blue: 0.24, alpha: 1).setFill(); star.fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name)) }
}
