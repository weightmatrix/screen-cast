import Foundation
import CoreImage

/// Separate CLI process, port and random code. Never publishes to the user's room.
private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = [0, 0]
    private var errors: [String] = []
    private var processingSeen = [false, false]
    private var lastTimings = [ReceiveTiming(), ReceiveTiming()]
    func timingSnapshot() -> [ReceiveTiming] { lock.lock(); defer { lock.unlock() }; return lastTimings }
    func timing(_ index: Int, _ timing: ReceiveTiming) {
        lock.lock(); defer { lock.unlock() }
        lastTimings[index] = timing
        if let ms = timing.processingMS, ms.isFinite, ms >= 0 { processingSeen[index] = true }
    }
    func timingsReady() -> Bool { lock.lock(); defer { lock.unlock() }; return processingSeen.allSatisfy { $0 } }
    func frame(_ index: Int) { lock.lock(); frames[index] += 1; lock.unlock() }
    func failed(_ text: String) { lock.lock(); errors.append(text); lock.unlock() }
    func snapshot() -> ([Int], [String]) { lock.lock(); defer { lock.unlock() }; return (frames, errors) }
}
@main @MainActor enum NativeMultiReceiverCheck {
    static func main() async {
        let code = MatchingCode.generate()
        let server = CastingServer(port: 19328, accessCode: code)
        let counts = Counts()
        var registrations = 0, viewers = 0
        server.onInternetStatus = { if $0.contains("匹配就绪") { registrations += 1 } }
        server.onClientCountChanged = { viewers = $0 }
        server.configureNative(bitrate: 8_000_000, fps: 30)
        server.start(); server.setInternetEnabled(true)
        let first = NativeVideoRoom(code: code), second = NativeVideoRoom(code: code)
        first.video.onImage = { _ in counts.frame(0) }; second.video.onImage = { _ in counts.frame(1) }
        first.video.onReceiveTiming = { counts.timing(0, $0) }; second.video.onReceiveTiming = { counts.timing(1, $0) }
        first.onError = { counts.failed("first: " + $0) }; second.onError = { counts.failed("second: " + $0) }
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard status == kCVReturnSuccess, let pixel else { exit(1) }
        CIContext().render(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)), to: pixel)
        func pump(_ condition: () -> Bool, seconds: Int = 15) async -> Bool {
            for _ in 0..<(seconds * 30) {
                if condition() { return true }
                if !counts.snapshot().1.isEmpty { return false }
                server.nativeSource.append(pixel)
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
            return condition()
        }
        var passed = await pump({ registrations >= 1 })
        if passed { first.start(); passed = await pump({ counts.snapshot().0[0] >= 30 }) }
        let before = counts.snapshot().0[0]
        if passed { passed = await pump({ registrations >= 2 }) }
        if passed { second.start(); passed = await pump({ counts.snapshot().0[1] >= 60 }) }
        if passed { passed = await pump({ counts.timingsReady() }) }
        let final = counts.snapshot()
        passed = passed && final.0[0] > before + 30 && viewers == 2 && final.1.isEmpty
        let connectedCount = viewers
        server.setInternetMatchingEnabled(false)
        passed = passed && viewers == 0
        let timings = counts.timingSnapshot()
        print("Timing RTT=\(timings.map { ReceiveTiming.text($0.networkRTTMS) }) processing=\(timings.map { ReceiveTiming.text($0.processingMS) })")
        print("NativeMultiReceiver \(passed ? "PASS" : "FAIL") frames=\(final.0) viewers=\(connectedCount) afterStop=\(viewers) timings=\(counts.timingsReady()) registrations=\(registrations) errors=\(final.1)")
        first.stop(); second.stop(); server.stop()
        exit(passed ? 0 : 1)
    }
}
