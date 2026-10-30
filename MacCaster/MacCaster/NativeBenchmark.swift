#if DEBUG
import AppKit
import CoreImage
import Foundation
import SwiftUI

/// Test-only data collector. Timestamps share this process's monotonic clock.
private final class BenchmarkRecorder: @unchecked Sendable {
    let zero = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private let analysis = DispatchQueue(label: "benchmark.barcode")
    private let slot = DispatchSemaphore(value: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var submissions: [Int: Double] = [:]
    private var frames: [Double] = []
    private var latencies: [[String: Any]] = []
    private var stats: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var errors: [String] = []
    private var measured = 0, invalidMarkers = 0
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - zero }
    func submitted(_ sequence: Int) { lock.lock(); submissions[sequence] = elapsed; lock.unlock() }
    func error(_ value: String) { lock.lock(); errors.append(value); lock.unlock() }
    func statistics(_ values: [[String: Any]], role: String) {
        lock.lock(); stats.append(["t": elapsed, "role": role, "stats": values]); lock.unlock()
    }
    func event(_ text: String) {
        guard ["native.capture ", "native.encoder ", "native.encoderFPS ", "native.budget ", "mac.display ", "gap stage="].contains(where: text.contains) else { return }
        lock.lock(); events.append(["t": elapsed, "event": text]); lock.unlock()
    }
    func frame(_ image: CIImage) {
        let arrival = elapsed
        lock.lock(); frames.append(arrival); let count = frames.count; lock.unlock()
        guard image.extent.size == CGSize(width: 1920, height: 1440) else { error("decoded resolution changed: \(image.extent.size)"); return }
        guard count % 10 == 0, slot.wait(timeout: .now()) == .success else { return }
        analysis.async { [self] in
            defer { slot.signal() }
            // 16-bit sync word followed by a 16-bit frame ID; sample away from block edges.
            var pixels = [UInt8](repeating: 0, count: 384 * 4)
            context.render(image, toBitmap: &pixels, rowBytes: pixels.count,
                           bounds: CGRect(x: 16, y: 32, width: 384, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            var word: UInt32 = 0
            for index in 0..<32 {
                let x = (index * 12 + 6) * 4
                word = (word << 1) | (Int(pixels[x]) + Int(pixels[x + 1]) + Int(pixels[x + 2]) > 384 ? 1 : 0)
            }
            lock.lock(); defer { lock.unlock() }
            measured += 1
            guard word >> 16 == 0xA55A, let submitted = submissions[Int(word & 0xFFFF)], arrival >= submitted else {
                invalidMarkers += 1; return
            }
            latencies.append(["t": arrival, "source_t": submitted, "ms": (arrival - submitted) * 1000, "sequence": word & 0xFFFF])
        }
    }
    func finish() -> [String: Any] {
        analysis.sync {}
        lock.lock(); defer { lock.unlock() }
        if measured > 0 && invalidMarkers > measured / 5 { errors.append("over 20% latency markers invalid") }
        return ["frames": frames, "latencies": latencies, "stats": stats, "events": events,
                "errors": errors, "marker_samples": measured, "invalid_markers": invalidMarkers]
    }
}

@MainActor enum NativeBenchmark {
    static func run(controlURL: URL) async {
        let recorder = BenchmarkRecorder()
        var configuration: [String: Any] = [:]
        var phases: [[String: Any]] = []
        func saveControl() throws {
            try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]).write(to: controlURL, options: .atomic)
        }
        do {
            configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: controlURL)) as? [String: Any] ?? [:]
            guard configuration["schema"] as? Int == 1, let host = configuration["host"] as? String,
                  CastingServer.localIPs.contains(host), let ports = configuration["ports"] as? [Int], ports.count == 2,
                  ports.allSatisfy({ (1024...65535).contains($0) }),
                  let plan = configuration["phases"] as? [[String: Any]],
                  let path = configuration["image"] as? String, let document = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
                throw NSError(domain: "NativeBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid local benchmark configuration"])
            }
            configuration["state"] = "started"; try saveControl()
            let source = NativeScreenSource(); source.configure(fps: 60)
            let sender = NativeVideoPeer(source: source, internet: true, bitrate: 100_000_000, fps: 60)
            let receiver = NativeVideoPeer(internet: true)
            defer { sender.stop(); receiver.stop() }
            sender.onVerificationStats = { recorder.statistics($0, role: "sender") }
            receiver.onVerificationStats = { recorder.statistics($0, role: "receiver") }
            let previousRelay = PerformanceDisk.shared.relay
            PerformanceDisk.shared.relay = { recorder.event($0) }
            defer { PerformanceDisk.shared.relay = previousRelay }
            let decoder = MacReceiverDecoder()
            receiver.onImage = { image in recorder.frame(image); decoder.publishFrame(image) }
            sender.onError = { recorder.error("sender: \($0)") }
            receiver.onError = { recorder.error("receiver: \($0)") }
            var senderReady = false, receiverReady = false
            sender.onConnected = { senderReady = true }; receiver.onConnected = { receiverReady = true }
            var chosen = Set<String>()
            func signal(_ object: [String: Any], side: Int, to peer: NativeVideoPeer) {
                var copy = object
                if object["type"] as? String == "candidate" {
                    guard let candidate = object["candidate"] as? String else { return }
                    var pieces = candidate.split(separator: " ").map(String.init)
                    let name = side == 0 ? "sender" : "receiver"
                    guard pieces.count >= 8, pieces[1] == "1", pieces[2].lowercased() == "udp",
                          pieces[4] == host, pieces[7] == "host", let port = Int(pieces[5]), !chosen.contains(name) else { return }
                    chosen.insert(name)
                    configuration[name] = [host, port]
                    do { try saveControl() } catch { recorder.error("control write: \(error)"); return }
                    pieces[5] = String(ports[side])
                    copy["candidate"] = pieces.joined(separator: " ")
                } else if let sdp = object["sdp"] as? String {
                    var maps = configuration["rtp_maps"] as? [String: [String: String]] ?? [:]
                    var codecs: [String: String] = [:]
                    for line in sdp.components(separatedBy: "\r\n") where line.hasPrefix("a=rtpmap:") {
                        let fields = line.dropFirst(9).split(separator: " ")
                        if fields.count == 2 { codecs[String(fields[0])] = String(fields[1].split(separator: "/")[0]).lowercased() }
                    }
                    maps[String(side)] = codecs; configuration["rtp_maps"] = maps
                    do { try saveControl() } catch { recorder.error("RTP map write: \(error)"); return }
                    // Every media packet must traverse the test link; exclude embedded direct candidates.
                    copy["sdp"] = sdp.components(separatedBy: "\r\n").filter {
                        !$0.hasPrefix("a=candidate:") && $0 != "a=end-of-candidates"
                    }.joined(separator: "\r\n")
                }
                peer.receive(copy)
            }
            sender.sendSignal = { signal($0, side: 0, to: receiver) }
            receiver.sendSignal = { signal($0, side: 1, to: sender) }
            sender.offer()
            for _ in 0..<350 {
                if senderReady && receiverReady { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard senderReady && receiverReady else {
                throw NSError(domain: "NativeBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "UDP impairment path did not connect"])
            }
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 720),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.title = "投屏受控测试 · 合成图文"; window.contentView = NSHostingView(rootView: MacStreamImageView(decoder: decoder))
            window.orderFrontRegardless()
            defer { window.orderOut(nil); decoder.reset() }
            var pool: CVPixelBufferPool?
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1440,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
                throw NSError(domain: "NativeBenchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "pixel pool failed"])
            }
            let context = CIContext(options: [.cacheIntermediates: false])
            let markerSpace = CGColorSpaceCreateDeviceRGB()
            var blackMarker = Data(repeating: 0, count: 416 * 64 * 4)
            for index in stride(from: 3, to: blackMarker.count, by: 4) { blackMarker[index] = 255 }
            var sequence = 0, motionIndex = 0
            var lastSnapshot = -Double.infinity
            var held: CVPixelBuffer?
            func triangle(_ n: Int, _ maximum: Int) -> Int { let p = n % (maximum * 2); return p <= maximum ? p : maximum * 2 - p }
            for specification in plan {
                guard let name = specification["name"] as? String, let seconds = specification["seconds"] as? Int,
                      (1...30).contains(seconds), let mbps = specification["mbps"] as? Int,
                      let motion = specification["motion"] as? Bool else { throw NSError(domain: "NativeBenchmark", code: 4) }
                configuration["phase"] = name
                configuration["profile"] = ["mbps": mbps, "delay_ms": 10, "jitter_ms": 2, "loss": 0, "queue_ms": 150]
                try saveControl()
                let begin = recorder.elapsed, inputFPS = motion ? 60 : 20
                var submitted = 0
                while recorder.elapsed - begin < Double(seconds) {
                    if recorder.elapsed - lastSnapshot >= 1 {
                        lastSnapshot = recorder.elapsed
                        sender.snapshotForVerification(); receiver.snapshotForVerification()
                    }
                    if motion || held == nil {
                        var buffer: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                            recorder.error("frame allocation failed"); break
                        }
                        sequence += 1; motionIndex += 1
                        let x = triangle(motionIndex * 13, 1152), y = triangle(motionIndex * 7, 864)
                        var image = document.cropped(to: CGRect(x: x, y: y, width: 1920, height: 1440))
                            .transformed(by: CGAffineTransform(translationX: -CGFloat(x), y: -CGFloat(y)))
                        let word = UInt32(0xA55A0000) | UInt32(sequence & 0xFFFF)
                        var marker = blackMarker
                        marker.withUnsafeMutableBytes { bytes in
                            guard let base = bytes.baseAddress else { return }
                            for bit in 0..<32 where word & (UInt32(1) << (31 - bit)) != 0 {
                                for row in 16..<48 {
                                    base.advanced(by: (row * 416 + 16 + bit * 12) * 4).initializeMemory(as: UInt8.self, repeating: 255, count: 12 * 4)
                                }
                            }
                        }
                        image = CIImage(bitmapData: marker, bytesPerRow: 416 * 4, size: CGSize(width: 416, height: 64),
                                        format: .RGBA8, colorSpace: markerSpace).composited(over: image)
                        context.render(image, to: buffer)
                        recorder.submitted(sequence)
                        held = buffer
                    }
                    if let held { source.append(held); submitted += 1 }
                    let deadline = begin + Double(submitted) / Double(inputFPS)
                    let wait = deadline - recorder.elapsed
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } else { await Task.yield() }
                }
                phases.append(["name": name, "start": begin, "end": recorder.elapsed, "submitted": submitted, "input_fps": inputFPS,
                               "mbps": mbps, "motion": motion])
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        } catch { recorder.error(String(describing: error)) }
        var report = recorder.finish()
        report["schema"] = 1; report["run"] = configuration["run"] ?? "unknown"
        report["provenance"] = configuration["provenance"] ?? [:]
        report["phases"] = phases
        report["setup"] = ["width": 1920, "height": 1440, "fps_ceiling": 60, "bitrate_ceiling": 100_000_000,
                           "idle_source_fps": 20, "control_interval_seconds": 2, "observation_interval_seconds": 1, "video": "native H264 SRTP", "network": "local UDP impairment", "os": ProcessInfo.processInfo.operatingSystemVersionString] as [String: Any]
        if let variant = configuration["diagnostic_profile"] as? String, variant != "standard" {
            var setup = report["setup"] as? [String: Any] ?? [:]
            setup["diagnostic_profile"] = variant; report["setup"] = setup
        }
        report["limitations"] = ["Not ReplayKit/ScreenCaptureKit capture or a cross-NAT test.",
                                 "Barcode latency is submission-to-decoded-frame, not glass-to-glass latency.",
                                 "RTP statistics are sampled at one second; phase boundary deltas have up to one second uncertainty.",
                                 "Idle repeats an unchanged frame; its barcode age is not a latency score."]
        if let path = configuration["report"] as? String {
            do { try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { NSLog("NativeScenario FAIL report write %@", String(describing: error)) }
        }
        NSLog("NativeScenario DONE phases=%ld", phases.count)
    }
}
#endif
