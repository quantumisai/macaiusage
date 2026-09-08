import AppKit
import Foundation

// Draw the icon from vectors so the repository needs no binary source assets.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/generate-icon.swift <output.iconset>")
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
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
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create icon bitmap.")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setAllowsAntialiasing(true)

        let background = NSBezierPath(
            roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
            xRadius: 198,
            yRadius: 198
        )
        NSColor(calibratedRed: 0.055, green: 0.105, blue: 0.125, alpha: 1).setFill()
        background.fill()

        let center = CGPoint(x: 512, y: 512)
        context.setLineWidth(94)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor(calibratedRed: 0.16, green: 0.25, blue: 0.27, alpha: 1).cgColor)
        context.addArc(center: center, radius: 248, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()

        context.setStrokeColor(NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.73, alpha: 1).cgColor)
        context.addArc(center: center, radius: 248, startAngle: -.pi / 6, endAngle: 1.5 * .pi, clockwise: false)
        context.strokePath()

        context.setFillColor(NSColor(calibratedRed: 0.88, green: 0.97, blue: 0.96, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 471, y: 471, width: 82, height: 82))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode icon bitmap.")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
