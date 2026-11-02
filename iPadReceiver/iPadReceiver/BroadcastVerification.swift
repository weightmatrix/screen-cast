#if DEBUG
import Foundation
import CoreImage
import ReplayKit
#if os(iOS)
import UIKit
#endif

@MainActor enum BroadcastVerification {
    static func run() async {
        let encoder = ReplayVideoEncoder(bitrate: 100_000_000, fps: 30)
        let decoder = ImageDecoder()
        var outputs = 0
        var failure: String?
        encoder.onFailure = { text in DispatchQueue.main.async { failure = text } }
        encoder.onOutput = { data, _, configuration in
            DispatchQueue.main.async {
                if let configuration {
                    var payload = Data()
                    payload.append(uint32: configuration.count)
                    payload.append(configuration)
                    decoder.setH264Serialized(payload)
                }
                decoder.decodeFrame(data)
                outputs += 1
            }
        }
        let context = CIContext()
        var pixel: CVPixelBuffer?
        let created = CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard created == kCVReturnSuccess, let pixel else {
            ConnectionDiag.shared.log("SenderCheck FAIL pixel buffer allocation")
            return
        }
        context.render(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)), to: pixel)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        guard let format else { return }
        for orientation in [1, 6] {
            for n in 0..<18 {
                let sequence = (orientation == 1 ? 0 : 30) + n
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 30), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
                    formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample {
                    CMSetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                        value: NSNumber(value: orientation), attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    encoder.append(sample)
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let expected = orientation == 1 ? CGSize(width: 640, height: 480) : CGSize(width: 480, height: 640)
            let passed = decoder.currentFrame?.extent.size == expected && failure == nil
            ConnectionDiag.shared.log("SenderCheck \(passed ? "PASS" : "FAIL") encode -> shared H264 format -> decode orientation=\(orientation) frames=\(outputs)")
        }
        let highBitrate = encoder.configuredBitrateForVerification() == 100_000_000
        ConnectionDiag.shared.log("SenderCheck \(highBitrate ? "PASS" : "FAIL") 100 Mbps applied to hardware encoder")
        let bounds = BroadcastSettings.clampedBitrate(0) == 8_000_000 && BroadcastSettings.clampedBitrate(101_000_000) == 100_000_000
            && BroadcastSettings.clampedBitrate(42_000_000) == 42_000_000
        ConnectionDiag.shared.log("SenderCheck \(bounds ? "PASS" : "FAIL") bitrate range and intermediate values")
        for limit: Int? in [8_000_000, 4_000_000, nil] {
            encoder.setInternetBitrateLimit(limit)
            let expected = limit ?? 100_000_000
            let actual = encoder.configuredBitrateForVerification()
            ConnectionDiag.shared.log("SenderCheck \(actual == expected ? "PASS" : "FAIL") adaptive encoder property expected=\(expected) actual=\(actual ?? -1)")
        }
        encoder.stop()
        if let image = decoder.currentFrame {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            ConnectionDiag.shared.log("SenderCheck \(pixel[0] > 40 ? "PASS" : "FAIL") decoded image is non-black")
        }
        await verifyResolutions()
        await verifyReplayKitPixelFormats()
        if ProcessInfo.processInfo.arguments.contains("--verify-complex-encoding") {
            await verifyComplexEncoding()
        }
        let storage = BroadcastSettings.store
        let ready = storage.set("ready", forKey: "verificationState") && storage.string(forKey: "verificationState") == "ready"
        ConnectionDiag.shared.log("SenderCheck \(ready ? "PASS" : "FAIL") signed shared keychain settings")
    }
    private static func verifyResolutions() async {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2732, 2048, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { return }
        CIContext().render(CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 2732, height: 2048)), to: pixel)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        guard let format else { return }
        for (limit, expected) in [(1600, CGSize(width: 1600, height: 1198)),
                                   (1920, CGSize(width: 1920, height: 1438)),
                                   (0, CGSize(width: 2732, height: 2048))] {
            let encoder = ReplayVideoEncoder(bitrate: 40_000_000, fps: 30, maximumDimension: limit)
            let decoder = ImageDecoder()
            encoder.onOutput = { data, _, config in
                DispatchQueue.main.async {
                    if let config {
                        var payload = Data()
                        payload.append(uint32: config.count)
                        payload.append(config)
                        decoder.setH264Serialized(payload)
                    }
                    decoder.decodeFrame(data)
                }
            }
            for n in 0..<8 {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: CMTime(value: Int64(n), timescale: 30), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
                    formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample { encoder.append(sample) }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let passed = decoder.currentFrame?.extent.size == expected
            ConnectionDiag.shared.log("SenderCheck \(passed ? "PASS" : "FAIL") resolution limit=\(limit) expected=\(expected)")
            encoder.stop()
        }
    }

    private static func verifyReplayKitPixelFormats() async {
        for pixelFormat in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1440, pixelFormat,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
            guard let pixel else { continue }
            CVPixelBufferLockBaseAddress(pixel, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) {
                    base.initializeMemory(as: UInt8.self, repeating: plane == 0 ? 160 : 128,
                        count: CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
            guard let format else { continue }
            let encoder = ReplayVideoEncoder(bitrate: 100_000_000, fps: 60, maximumDimension: 0)
            let decoder = ImageDecoder()
            encoder.onOutput = { data, _, config in
                DispatchQueue.main.async {
                    if let config {
                        var payload = Data()
                        payload.append(uint32: config.count); payload.append(config)
                        decoder.setH264Serialized(payload)
                    }
                    decoder.decodeFrame(data)
                }
            }
            for n in 0..<16 {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                    presentationTimeStamp: CMTime(value: Int64(n), timescale: 60), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
                    formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                if let sample { encoder.append(sample) }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            var rgba = [UInt8](repeating: 0, count: 4)
            if let image = decoder.currentFrame {
                CIContext().render(image, toBitmap: &rgba, rowBytes: 4,
                    bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let passed = decoder.currentFrame?.extent.size == CGSize(width: 1920, height: 1440) && rgba[0] > 40
            ConnectionDiag.shared.log("SenderCheck \(passed ? "PASS" : "FAIL") ReplayKit direct pixelFormat=\(pixelFormat) 1920x1440 decoded non-black")
            encoder.stop()
        }
    }

    private static func verifyComplexEncoding() async {
        var pixels: [CVPixelBuffer] = []
        for _ in 0..<2 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1440, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<2 {
                if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                    let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
                    if plane == 0 { arc4random_buf(base, count) }
                    else { base.initializeMemory(as: UInt8.self, repeating: 128, count: count) }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            pixels.append(buffer)
        }
        let encoder = ReplayVideoEncoder(bitrate: 100_000_000, fps: 60, maximumDimension: 0)
        if ProcessInfo.processInfo.arguments.contains("--verify-adaptive-encoder") { encoder.setInternetBitrateLimit(8_000_000) }
        var encoded: [(Double, Int)] = []
        encoder.onEncodedForVerification = { sample in
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let size = CMSampleBufferGetTotalSampleSize(sample)
            DispatchQueue.main.async { encoded.append((pts, size)) }
        }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels[0], formatDescriptionOut: &format)
        guard let format else { return }
        let begin = ProcessInfo.processInfo.systemUptime
        let frameCount = ProcessInfo.processInfo.arguments.contains("--verify-adaptive-encoder") ? 600 : 150
        for n in 0..<frameCount {
            let wait = begin + Double(n) / 60 - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                presentationTimeStamp: CMTime(value: Int64(n), timescale: 60), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels[n % 2],
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
            if let sample { encoder.append(sample) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ordered = encoded.sorted { $0.0 < $1.0 }
        var maxBytes = 0
        for end in ordered {
            let bytes = ordered.filter { $0.0 > end.0 - 1 + 0.000001 && $0.0 <= end.0 }.reduce(0) { $0 + $1.1 }
            maxBytes = max(maxBytes, bytes)
        }
        let maxMbps = Double(maxBytes) * 8 / 1_000_000
        let passed = ordered.count >= 30
        ConnectionDiag.shared.log("SenderCheck \(passed ? "PASS" : "FAIL") noisy 1920x1440 60fps encoding frames=\(ordered.count) observedMaxOneSecondMbps=\(String(format: "%.2f", maxMbps))")
        encoder.stop()
    }

}
#endif

#if DEBUG
@MainActor enum NativeRoutesVerification {
    static func run() async {
        #if os(iOS)
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        #endif
        let code = MatchingCode.generate()
        let server = CastingServer(port: 19318, accessCode: code)
        server.configureNative(bitrate: 8_000_000, fps: 30)
        server.start()
        defer { server.stop() }
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { return }
        let context = CIContext()
        context.render(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), to: pixel)
        var registered = false
        server.onInternetStatus = { text in if text.contains("匹配就绪") { registered = true } }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for mode in ["localIP", "localCode", "internetIP", "internetCode"] {
            #if os(iOS)
            let appState = UIApplication.shared.applicationState.rawValue
            PerformanceDisk.shared.write("NativeRoutes BEGIN mode=\(mode) appState=\(appState)")
            guard UIApplication.shared.applicationState == .active else {
                PerformanceDisk.shared.write("NativeRoutes SKIP foreground required")
                return
            }
            #endif
            if mode == "internetIP" { server.setInternetMatchingEnabled(false); server.setInternetEnabled(true) }
            if mode == "internetCode" {
                server.setInternetMatchingEnabled(true)
                for _ in 0..<100 { if registered { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            let client = StreamClient()
            if mode == "localIP" { client.connect(host: "127.0.0.1", port: 19318, code: code) }
            if mode == "localCode" { client.discoveryLookup = { _ in ("127.0.0.1", 19318) }; client.connectWithCode(code) }
            if mode == "internetIP" { client.connectInternetIP(host: "127.0.0.1", port: 20318, code: code) }
            if mode == "internetCode" { client.connectInternetCode(code) }
            for _ in 0..<240 {
                server.nativeSource.append(pixel)
                try? await Task.sleep(nanoseconds: 33_333_333)
                if case .failed = client.status { break }
            }
            let image = client.decoder.currentFrame
            var sample = [UInt8](repeating: 0, count: 4)
            if let image { context.render(image, toBitmap: &sample, rowBytes: 4, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            let passed = client.frameCount >= 10 && image?.extent.size == CGSize(width: 1280, height: 720) && sample[0] > 150 && sample[1] < 80
            NSLog("NativeRoutes %@ mode=%@ frames=%ld size=%@ pixel=%@ status=%@", passed ? "PASS" : "FAIL", mode, client.frameCount, String(describing: image?.extent.size), String(describing: sample), String(describing: client.status))
            PerformanceDisk.shared.write("NativeRoutes \(passed ? "PASS" : "FAIL") mode=\(mode) frames=\(client.frameCount) size=\(String(describing: image?.extent.size))")
            if mode == "localIP" {
                for _ in 0..<90 { server.nativeSource.append(pixel, orientation: 6); try? await Task.sleep(nanoseconds: 33_333_333) }
                let rotated = client.decoder.currentFrame?.extent.size
                NSLog("NativeRotation %@ size=%@", rotated == CGSize(width: 720, height: 1280) ? "PASS" : "FAIL", String(describing: rotated))
            }
            client.disconnect()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
#endif
