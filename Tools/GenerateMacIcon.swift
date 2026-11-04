import AppKit

// Reproducible native icon artwork. Run from the repository root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let staging = FileManager.default.temporaryDirectory.appendingPathComponent("touping-icon-\(UUID().uuidString)")
let iconset = staging.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: staging) }

func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    let approved = root.appendingPathComponent("Design/BrandIcons/投屏-approved.png")
    if let image = NSImage(contentsOf: approved) {
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(calibratedWhite: 0.11, alpha: 1), ending: NSColor(calibratedWhite: 0.035, alpha: 1))!
        .draw(in: tile, angle: -70)
    NSColor.white.withAlphaComponent(0.10).setStroke(); tile.lineWidth = 2; tile.stroke()

    // Rounded AirPlay-inspired upward triangle: the third shape in the brand family.
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 478, y: 854))
    triangle.addQuadCurve(to: CGPoint(x: 546, y: 854), control: CGPoint(x: 512, y: 918))
    triangle.addLine(to: CGPoint(x: 875, y: 249))
    triangle.addQuadCurve(to: CGPoint(x: 839, y: 190), control: CGPoint(x: 910, y: 190))
    triangle.addLine(to: CGPoint(x: 185, y: 190))
    triangle.addQuadCurve(to: CGPoint(x: 149, y: 249), control: CGPoint(x: 114, y: 190))
    triangle.closeSubpath()
    context.saveGState()
    context.addPath(triangle); context.setLineWidth(44); context.setLineJoin(.round)
    context.replacePathWithStrokedPath(); context.clip()
    let colors: [NSColor] = [.systemCyan, .systemBlue, .systemPurple, .systemPink, .systemOrange, .systemYellow, .systemGreen]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: 175, y: 840), end: CGPoint(x: 820, y: 190), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    func text(_ value: String, size: CGFloat, y: CGFloat, weight: NSFont.Weight) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedRed: 1, green: 0.80, blue: 0.34, alpha: 1)]
        let string = NSAttributedString(string: value, attributes: attributes)
        string.draw(at: CGPoint(x: (1024 - string.size().width) / 2, y: y))
    }
    text("李知本", size: 140, y: 365, weight: .semibold)
    text("投屏", size: 78, y: 268, weight: .medium)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let master = render(1024)
for name in ["MacCaster/MacCaster/MacIcon-1024.png", "icons/MacCaster-1024.png"] {
    try master.write(to: root.appendingPathComponent(name))
}
try render(180).write(to: root.appendingPathComponent("icons/MacCaster-180.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("MacCaster/MacCaster/AppIcon.icns").path]
try process.run(); process.waitUntilExit()
precondition(process.terminationStatus == 0)
print("Generated triangle brand icon, PNG sizes and ICNS")
