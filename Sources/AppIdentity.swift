import SwiftUI
import AppKit

// AppKit icons are resolved on the main thread and reused across map tiles and rows.
enum AppIdentity {
    private struct Identity {
        let icon: NSImage
        let color: Color?
        var access: UInt64
    }
    private static var cache: [String: Identity] = [:]
    private static var access: UInt64 = 0
    private static let capacity = 256

    static func icon(for path: String) -> NSImage? { identity(for: path)?.icon }
    static func color(for path: String) -> Color? { identity(for: path)?.color }

    // The outer application owns files and nested helper applications within it.
    static func bundlePath(for path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            parts.append(part)
            if part.count > 4 && part.lowercased().hasSuffix(".app") {
                return "/" + parts.joined(separator: "/")
            }
        }
        return nil
    }

    private static func identity(for path: String) -> Identity? {
        guard Thread.isMainThread, let bundle = bundlePath(for: path) else { return nil }
        access &+= 1
        if var value = cache[bundle] {
            value.access = access; cache[bundle] = value
            return value
        }
        let source = NSWorkspace.shared.icon(forFile: bundle)
        // Retain one small representation rather than all resolutions in the system icon.
        let bitmap = raster(source, edge: 64)
        let icon: NSImage
        if let bitmap {
            icon = NSImage(size: NSSize(width: 32, height: 32)); icon.addRepresentation(bitmap)
        } else { icon = source }
        let value = Identity(icon: icon, color: dominantColor(in: source), access: access)
        if cache.count >= capacity, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[bundle] = value
        return value
    }

    private static func raster(_ image: NSImage, edge: Int) -> NSBitmapImageRep? {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: edge * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        // Icon Services can temporarily fail; keep the original image instead of caching a blank.
        guard let pixels = bitmap.bitmapData,
            stride(from: 3, to: edge * edge * 4, by: 4).contains(where: { pixels[$0] > 0 }) else { return nil }
        return bitmap
    }

    private static func dominantColor(in image: NSImage) -> Color? {
        guard let bitmap = raster(image, edge: 16) else { return nil }
        struct Bin {
            var weight: CGFloat = 0
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
        }
        var bins = [Bin](repeating: Bin(), count: 16)
        for y in 0..<16 {
            for x in 0..<16 {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                pixel.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                // Ignore the transparent surround, white icon plates and monochrome details.
                guard alpha > 0.45, saturation > 0.18, brightness > 0.18 else { continue }
                let index = min(15, Int(hue * 16))
                let weight = alpha * saturation * saturation * brightness
                bins[index].weight += weight
                bins[index].red += pixel.redComponent * weight
                bins[index].green += pixel.greenComponent * weight
                bins[index].blue += pixel.blueComponent * weight
            }
        }
        guard let winner = bins.indices.max(by: { bins[$0].weight < bins[$1].weight }), bins[winner].weight > 0.25 else { return nil }
        let bin = bins[winner]
        let sampled = NSColor(srgbRed: bin.red / bin.weight, green: bin.green / bin.weight,
            blue: bin.blue / bin.weight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        sampled.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Preserve the icon's hue while making the accent readable against either appearance.
        let selectedHue = hue
        let readableSaturation = min(0.85, max(0.45, saturation))
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedHue: selectedHue, saturation: readableSaturation,
                brightness: dark ? 0.82 : 0.62, alpha: 1)
        })
    }
}

struct AppIdentityIcon: View {
    let path: String
    var size: CGFloat = 20
    var fallback: String = "folder"
    var body: some View {
        Group {
            if let icon = AppIdentity.icon(for: path) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: fallback).resizable().scaledToFit().padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
