import AppKit
import ImageIO

// Reproducible native icon artwork. Run from the repository root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let staging = FileManager.default.temporaryDirectory.appendingPathComponent("touping-icon-\(UUID().uuidString)")
let iconset = staging.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: staging) }

let approved = root.appendingPathComponent("Design/BrandIcons/投屏-approved.png")
guard let artwork = NSImage(contentsOf: approved), artwork.size.width == 1024, artwork.size.height == 1024 else {
    fatalError("Missing approved 1024×1024 icon; refusing to generate substitute artwork")
}

func render(_ size: Int, macOS: Bool = true) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    // macOS needs its own rounded tile and transparent canvas margin. iOS applies its system mask.
    let inset = macOS ? CGFloat(size) * 100 / 1024 : 0
    let tile = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    if macOS { NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22).addClip() }
    artwork.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    if macOS { return bitmap.representation(using: .png, properties: [:])! }
    // AppKit draws to RGBA; export iOS through an RGBX context so the PNG has no alpha channel.
    let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    opaque.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, opaque.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", staging.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil failed; existing source assets were not replaced. Run with normal system image-encoding access.\n", stderr)
    exit(1)
}
try Data(contentsOf: staging.appendingPathComponent("AppIcon.icns")).write(to: root.appendingPathComponent("MacCaster/MacCaster/AppIcon.icns"), options: .atomic)
let master = render(1024)
for name in ["MacCaster/MacCaster/MacIcon-1024.png", "icons/MacCaster-1024.png"] {
    try master.write(to: root.appendingPathComponent(name))
}
try render(180).write(to: root.appendingPathComponent("icons/MacCaster-180.png"))

for (name, size) in [("icons/iPadReceiver-1024.png", 1024), ("icons/iPadReceiver-180.png", 180)] {
    try render(size, macOS: false).write(to: root.appendingPathComponent(name))
}
// Keep the asset-catalog source byte-identical to the approved opaque master.
try Data(contentsOf: approved).write(to: root.appendingPathComponent("iPadReceiver/iPadReceiver/Assets.xcassets/AppIcon.appiconset/李知本·投屏.png"))
print("Generated approved blue ornamental icon: rounded macOS ICNS/PNG and opaque iOS assets")
