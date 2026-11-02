import Foundation
import CoreImage
import ReplayKit

@main enum NativeOrientationCheck {
    @MainActor static func main() async throws {
        let source = NativeScreenSource()
        let sender = NativeVideoPeer(source: source, internet: false, bitrate: 8_000_000, fps: 30)
        let receiver = NativeVideoPeer(internet: false)
        sender.sendSignal = { receiver.receive($0) }; receiver.sendSignal = { sender.receive($0) }
        defer { sender.stop(); receiver.stop() }
        let context = CIContext(options: [.cacheIntermediates: false])
        let width = 640, height = 480
        let colors = [CIColor.red, .green, .blue, .yellow]
        let rects = [CGRect(x: 0, y: 240, width: 320, height: 240), CGRect(x: 320, y: 240, width: 320, height: 240),
                     CGRect(x: 0, y: 0, width: 320, height: 240), CGRect(x: 320, y: 0, width: 320, height: 240)]
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        for (color, rect) in zip(colors, rects) { image = CIImage(color: color).cropped(to: rect).composited(over: image) }
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { fatalError("pixel allocation") }
        context.render(image, to: pixel)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        guard let format else { fatalError("sample format") }
        var latest: CIImage?, frames = 0
        receiver.onImage = { value in DispatchQueue.main.async { latest = value; frames += 1 } }
        var errors: [String] = []
        sender.onError = { errors.append($0) }; receiver.onError = { errors.append($0) }
        sender.offer()
        var sequence: Int64 = 0, failures = 0
        func corners(_ value: CIImage) -> [[UInt8]] {
            let e = value.extent
            return [(e.minX + 40, e.maxY - 40), (e.maxX - 40, e.maxY - 40),
                    (e.minX + 40, e.minY + 40), (e.maxX - 40, e.minY + 40)].map { x, y in
                var rgba = [UInt8](repeating: 0, count: 4)
                context.render(value, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                return Array(rgba.prefix(3))
            }
        }
        func colorIdentity(_ rgb: [UInt8]) -> Int {
            guard rgb.count == 3 else { return -1 }
            if rgb[0] > 150 && rgb[1] > 150 && rgb[2] < 100 { return 3 }
            if rgb[0] > 150 && rgb[1] < 100 && rgb[2] < 100 { return 0 }
            if rgb[1] > 150 && rgb[0] < 150 && rgb[2] < 100 { return 1 }
            if rgb[2] > 150 && rgb[0] < 100 && rgb[1] < 100 { return 2 }
            return -1
        }
        for orientation in [1, 6, 3, 8, 1] {
            let before = frames
            for _ in 0..<600 {
                sequence += 1
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: sequence, timescale: 30), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample {
                    CMSetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, value: NSNumber(value: orientation), attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    source.append(sample)
                }
                try await Task.sleep(nanoseconds: 33_333_333)
                if frames >= before + 30 || !errors.isEmpty { break }
            }
            let expected = image.oriented(forExifOrientation: Int32(orientation))
            let wanted = corners(expected), actual = latest.map(corners) ?? []
            // Codec YUV/RGB colorimetry may shift channel values; require the
            // four distinct corner identities in the exact expected positions.
            let passed = errors.isEmpty && frames >= before + 10 && latest?.extent.size == expected.extent.size && actual.count == 4
                && !actual.map(colorIdentity).contains(-1) && actual.map(colorIdentity) == wanted.map(colorIdentity)
            if !passed { failures += 1 }
            print("Orientation \(passed ? "PASS" : "FAIL") exif=\(orientation) corners=\(actual) expected=\(wanted) frames=\(frames - before)")
        }
        if !errors.isEmpty { print("Errors: \(errors)") }
        exit(failures == 0 ? 0 : 1)
    }
}
