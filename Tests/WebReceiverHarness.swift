import Foundation
import CoreImage

/// Synthetic native H.264 source for browser interoperability; never captures a screen.
@main enum WebReceiverHarness {
    @MainActor static func main() async throws {
        precondition(BrowserReceiverServer.isLocalAddress("192.168.42.17"))
        precondition(BrowserReceiverServer.isLocalAddress("127.0.0.1"))
        precondition(!BrowserReceiverServer.isLocalAddress("8.8.8.8"))
        precondition(!BrowserReceiverServer.isLocalAddress("172.32.0.1"))
        let source = NativeScreenSource(); source.configure(fps: 15, dimension: 640)
        let addresses = ProcessInfo.processInfo.environment["TOUPING_TEST_LAN_IP"].map { [$0] } ?? []
        let server = BrowserReceiverServer(port: 20319, code: { "61328407" }, addresses: { addresses }) {
            NativeVideoPeer(source: source, internet: false, bitrate: 8_000_000, fps: 15)
        }
        server.reserveSlot = { SenderConnectionBudget.reserve($0, internet: false) }
        server.releaseSlot = { SenderConnectionBudget.release($0) }
        server.onReady = { print("BrowserHarness LAN ready=\($0)"); fflush(stdout) }
        server.onChanged = { print("BrowserHarness connected=\(server.connectedCount)"); fflush(stdout) }
        server.start()
        let room = NativeVideoRoom(code: "61328407", source: source, bitrate: 8_000_000, fps: 15)
        if ProcessInfo.processInfo.arguments.contains("--internet") {
            room.onApprovalRequested = { room.respondToApproval(accept: true) } // Synthetic fixture only.
            room.onRegistered = { print("BrowserHarness WAN ready"); fflush(stdout) }
            room.onConnected = { print("BrowserHarness WAN connected"); fflush(stdout) }
            room.onError = { print("BrowserHarness WAN error=\($0)"); fflush(stdout) }
            room.start()
        }
        defer { server.stop(); room.stop() }
        let context = CIContext(options: [.cacheIntermediates: false])
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { fatalError("No test buffer") }
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        for (color, rect) in zip([CIColor.red, .green, .blue, .yellow],
            [CGRect(x: 0,y: 240,width: 320,height: 240), CGRect(x: 320,y: 240,width: 320,height: 240),
             CGRect(x: 0,y: 0,width: 320,height: 240), CGRect(x: 320,y: 0,width: 320,height: 240)]) {
            image = CIImage(color: color).cropped(to: rect).composited(over: image)
        }
        context.render(image, to: pixel)
        for _ in 0..<9000 {
            source.append(pixel)
            try await Task.sleep(nanoseconds: 66_666_667)
        }
    }
}
