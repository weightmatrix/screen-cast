import AppKit

// Decode every ICNS representation, not just the Finder/Xcode preview image.
@main enum AppIconAssetsCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let decoded = FileManager.default.temporaryDirectory.appendingPathComponent("touping-icon-check-\(UUID().uuidString).iconset")
        defer { try? FileManager.default.removeItem(at: decoded) }
        let tool = Process(); tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        tool.arguments = ["-c", "iconset", root.appendingPathComponent("MacCaster/MacCaster/AppIcon-Fold.icns").path, "-o", decoded.path]
        try tool.run(); tool.waitUntilExit(); precondition(tool.terminationStatus == 0)
        let master = NSBitmapImageRep(data: try Data(contentsOf: root.appendingPathComponent("MacCaster/MacCaster/MacIcon-1024.png")))!
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                let bitmap = NSBitmapImageRep(data: try Data(contentsOf: decoded.appendingPathComponent(name)))!
                precondition(bitmap.pixelsWide == size * scale && bitmap.pixelsHigh == size * scale, name)
                precondition(bitmap.hasAlpha && bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01, "Mac icon needs transparent margins: \(name)")
                precondition(bitmap.colorAt(x: size * scale / 2, y: size * scale / 2)!.alphaComponent > 0.99)
                if size * scale == 1024 {
                    // iconutil can re-encode PNG metadata; compare decoded colors instead of compressed bytes.
                    for y in stride(from: 0, to: 1024, by: 16) {
                        for x in stride(from: 0, to: 1024, by: 16) {
                            let a = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            let b = master.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            precondition(abs(a.alphaComponent - b.alphaComponent) < 0.01)
                            if a.alphaComponent > 0.99 {
                                precondition(abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01, "ICNS contains different artwork")
                            }
                        }
                    }
                }
            }
        }
        let source = try Data(contentsOf: root.appendingPathComponent("Design/BrandIcons/投屏-approved.png"))
        let ios = try Data(contentsOf: root.appendingPathComponent("iPadReceiver/iPadReceiver/Assets.xcassets/AppIcon.appiconset/李知本·投屏.png"))
        precondition(source == ios)
        for name in ["Design/BrandIcons/投屏-approved.png", "icons/iPadReceiver-1024.png", "icons/iPadReceiver-180.png"] {
            let image = NSBitmapImageRep(data: try Data(contentsOf: root.appendingPathComponent(name)))!
            precondition(!image.hasAlpha, "iOS artwork must be opaque")
        }
        print("PASS all 10 ICNS sizes, transparent macOS margins, decoded master consistency, opaque iOS exports and shared source")
    }
}
