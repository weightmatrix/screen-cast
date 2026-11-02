import CoreImage
import Metal

@main enum DisplayOrientationCheck {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let context = CIContext(mtlDevice: device)
        var original = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        for (color, rect) in zip([CIColor.red, .green, .blue, .yellow],
            [CGRect(x: 0,y: 240,width: 320,height: 240), CGRect(x: 320,y: 240,width: 320,height: 240),
             CGRect(x: 0,y: 0,width: 320,height: 240), CGRect(x: 320,y: 0,width: 320,height: 240)]) {
            original = CIImage(color: color).cropped(to: rect).composited(over: original)
        }
        for orientation in [1,6,3,8] {
            let image = original.oriented(forExifOrientation: Int32(orientation))
            let w = Int(image.extent.width), h = Int(image.extent.height)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            let texture = device.makeTexture(descriptor: descriptor)!, command = queue.makeCommandBuffer()!
            context.render(ScreenDisplay.imageForDrawable(image, bounds: image.extent), to: texture,
                           commandBuffer: command, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            for (x,y) in [(40,40),(w-40,40),(40,h-40),(w-40,h-40)] {
                var actual = [UInt8](repeating: 0, count: 4), expected = actual
                texture.getBytes(&actual, bytesPerRow: 4, from: MTLRegionMake2D(x,y,1,1), mipmapLevel: 0)
                // Compare storage coordinates consistently. A readback's row 0
                // must not be declared the visible top of an MTKView.
                context.render(image, toBitmap: &expected, rowBytes: 4, bounds: CGRect(x: x,y: y,width: 1,height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                precondition(zip(actual,expected).allSatisfy { abs(Int($0.0)-Int($0.1)) < 5 }, "Display introduced a mirror: \(orientation) at \(x),\(y)")
            }
            print("Display PASS exif=\(orientation) no extra mirror in GPU storage; presentation requires device verification")
        }
    }
}
