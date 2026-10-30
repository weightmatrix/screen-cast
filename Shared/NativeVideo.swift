import Foundation
import CoreMedia
import CoreImage
import Network
import WebRTC
import ReplayKit
import VideoToolbox

// Negotiate a screen-sharing H264 level rather than
// the SDK factory's default level 3.1 (which only permits ~3fps at 4K).
private enum ScreenH264Formats {
    static let codecs = ["640c34", "42e034"].map {
        RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": $0,
            "level-asymmetry-allowed": "1", "packetization-mode": "1"])
    }
}
private final class ScreenH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenH264Formats.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        AppleScreenEncoder(info)
    }
}
/// Public WebRTC encoder adapter: hardware VideoToolbox realtime H264, native RTP output.
/// No encoded video is sent through the application data channel.
private final class AppleScreenEncoder: NSObject, RTCVideoEncoder {
    private final class Ticket {
        let frame: RTCVideoFrame
        let started = ProcessInfo.processInfo.systemUptime
        init(_ frame: RTCVideoFrame) { self.frame = frame }
    }
    private let codec: RTCVideoCodecInfo
    private var session: VTCompressionSession?
    private var callback: RTCVideoEncoderCallback?
    private let lock = NSLock()
    private var pending = 0
    private var framePacer = EncoderFramePacer()
    private var pacingFPS = 60
    private var pacingUpper = 60
    private var nextEncodedNS: Int64?
    private var scheduledFPS = 0
    private var width = 0, height = 0
    private var rate: UInt32 = 8_000, fps: UInt32 = 60
    private var appliedRate: UInt32 = 0, appliedFPS: UInt32 = 0
    private var pool: CVPixelBufferPool?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let perf = StreamPerformance("native.encoder")
    private var keyNeeded = true
    init(_ codec: RTCVideoCodecInfo) { self.codec = codec; super.init() }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { true }
    func implementationName() -> String { "AppleScreenVideoToolbox" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    func setCallback(_ callback: RTCVideoEncoderCallback?) { lock.lock(); self.callback = callback; lock.unlock() }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        _ = release()
        width = Int(settings.width); height = Int(settings.height)
        rate = max(1, settings.startBitrate); fps = max(1, settings.maxFramerate)
        lock.lock(); framePacer.reset(upper: Int(fps)); pacingFPS = Int(fps); pacingUpper = Int(fps); lock.unlock()
        nextEncodedNS = nil; scheduledFPS = 0
        // Normal realtime rate control recovers without the low-latency mode's
        // prolonged frame starvation. Keep the hardware-only low-latency path on
        // older iOS, where the explicit hardware requirement is unavailable.
        var lowLatency = true
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        if #available(iOS 17.4, *) {
            specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            lowLatency = false
        }
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: { opaque, frameRef, status, flags, sample in
                guard let opaque, let frameRef else { return }
                let owner = Unmanaged<AppleScreenEncoder>.fromOpaque(opaque).takeUnretainedValue()
                let ticket = Unmanaged<Ticket>.fromOpaque(frameRef).takeRetainedValue()
                owner.output(ticket, status: status, flags: flags, sample: sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else {
            PerformanceDisk.shared.write("native.encoder create status=\(status)"); return -1
        }
        let profile = codec.parameters["profile-level-id"]?.hasPrefix("42") == true
            ? kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
        let required: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, profile)
        ]
        for (key, value) in required {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else {
                PerformanceDisk.shared.write("native.encoder property=\(key) status=\(result)")
                _ = release(); return -1
            }
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7200 as CFNumber)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 240 as CFNumber)
        let result = setBitrate(rate, framerate: fps)
        guard result == 0, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { _ = release(); return -1 }
        pool = VTCompressionSessionGetPixelBufferPool(session)
        keyNeeded = true
        var hardware: Unmanaged<CFTypeRef>?
        var hardwareStatus: OSStatus = kVTPropertyNotSupportedErr
        if #available(iOS 17.4, *) {
            hardwareStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hardware)
        }
        let hardwareValue = hardware?.takeRetainedValue()
        PerformanceDisk.shared.write("native.encoder ready=\(width)x\(height) lowLatencyRequested=\(lowLatency) hardware=\(String(describing: hardwareValue)) hardwareStatus=\(hardwareStatus) profile=\(profile)")
        return 0
    }
    func release() -> Int {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil; pool = nil; appliedRate = 0; appliedFPS = 0
        return 0
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        rate = max(1, bitrateKbit); fps = max(1, framerate)
        guard let session else { return 0 }
        // A source becoming idle must not permanently lower the recovery ceiling.
        lock.lock(); pacingUpper = max(pacingUpper, Int(fps)); let inputLimitFPS = pacingFPS
        let effectiveFPS = UInt32(min(Int(fps), inputLimitFPS)); lock.unlock()
        guard appliedRate != rate || appliedFPS != effectiveFPS else { return 0 }
        #if DEBUG
        if appliedFPS != effectiveFPS {
            PerformanceDisk.shared.write("native.encoder rateApply rateKbit=\(rate) expectedFPS=\(effectiveFPS) inputLimitFPS=\(inputLimitFPS)")
        }
        #endif
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (Int(rate) * 1000) as CFNumber)
        let frameStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: Int(effectiveFPS) as CFNumber)
        // Bound one-second output to 1.5x the current target, as in the native SDK.
        var burstStatus: OSStatus = noErr
        if #available(iOS 17.4, *) {
            burstStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                value: [Double(rate) * 1000 / 8 * 1.5, 1.0] as CFArray)
        }
        if status == noErr && frameStatus == noErr && burstStatus == noErr { appliedRate = rate; appliedFPS = effectiveFPS; return 0 }
        PerformanceDisk.shared.write("native.encoder rate status=\(status) fpsStatus=\(frameStatus) burstStatus=\(burstStatus)")
        return -1
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        guard let session, let native = frame.buffer as? RTCCVPixelBuffer else { return -1 }
        _ = setBitrate(rate, framerate: fps)
        lock.lock()
        let interval = Int64(1_000_000_000 / max(1, pacingFPS))
        if scheduledFPS != pacingFPS { nextEncodedNS = nil; scheduledFPS = pacingFPS }
        if let next = nextEncodedNS, frame.timeStampNs < next - 500_000 {
            lock.unlock(); perf.record("dropPaced"); return 0
        }
        guard pending < 2 else {
            let old = pacingFPS
            pacingFPS = framePacer.observe(drop: true, now: ProcessInfo.processInfo.systemUptime, upper: pacingUpper, enabled: true)
            let next = pacingFPS
            lock.unlock(); perf.record("dropBusy")
            if old != next { PerformanceDisk.shared.write("native.encoderFPS target=\(next) previous=\(old) reason=busy") }
            return 0
        }
        pending += 1
        if let next = nextEncodedNS, frame.timeStampNs < next + interval { nextEncodedNS = next + interval }
        else { nextEncodedNS = frame.timeStampNs + interval }
        lock.unlock()
        let input: CVPixelBuffer
        if CVPixelBufferGetWidth(native.pixelBuffer) == width && CVPixelBufferGetHeight(native.pixelBuffer) == height && !native.requiresCropping() {
            input = native.pixelBuffer
        } else {
            var output: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
                lock.lock(); pending -= 1; lock.unlock(); return -1
            }
            let image = CIImage(cvPixelBuffer: native.pixelBuffer)
            let rect = CGRect(x: Int(native.cropX), y: CVPixelBufferGetHeight(native.pixelBuffer) - Int(native.cropY + native.cropHeight),
                              width: Int(native.cropWidth), height: Int(native.cropHeight))
            let cropped = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            context.render(cropped.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)), to: output)
            input = output; perf.record("converted")
        }
        let force = keyNeeded || frameTypes.contains { $0.intValue == Int(RTCFrameType.videoFrameKey.rawValue) }
        let ticket = Unmanaged.passRetained(Ticket(frame)).toOpaque()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: input,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000), duration: .invalid,
            frameProperties: force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            sourceFrameRefcon: ticket, infoFlagsOut: nil)
        if status != noErr {
            Unmanaged<Ticket>.fromOpaque(ticket).release()
            lock.lock(); pending -= 1; lock.unlock(); keyNeeded = true
            PerformanceDisk.shared.write("native.encoder submit status=\(status)"); return -1
        }
        keyNeeded = false; return 0
    }
    private func output(_ ticket: Ticket, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        lock.lock(); pending -= 1; let callback = callback
        let oldFPS = pacingFPS
        pacingFPS = framePacer.observe(drop: status != noErr || flags.contains(.frameDropped), now: ProcessInfo.processInfo.systemUptime,
                                       upper: pacingUpper, enabled: true)
        let newFPS = pacingFPS
        lock.unlock()
        if oldFPS != newFPS { PerformanceDisk.shared.write("native.encoderFPS target=\(newFPS) previous=\(oldFPS)") }
        perf.record("encode", milliseconds: (ProcessInfo.processInfo.systemUptime - ticket.started) * 1000)
        guard status == noErr else { perf.record("error\(status)"); return }
        guard !flags.contains(.frameDropped) else { perf.record("dropVT"); return }
        guard let sample else { perf.record("noSample"); return }
        perf.record("output")
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample), let callback else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var data = Data(); let start: [UInt8] = [0, 0, 0, 1]
        if key {
            var count = 0, length: Int32 = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length) == noErr else { return }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?, size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
                data.append(contentsOf: start); data.append(pointer, count: size)
            }
        }
        var pointer: UnsafeMutablePointer<Int8>?, size = 0, contiguous = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &size, dataPointerOut: &pointer) == noErr,
              let pointer, contiguous == size else { return }
        var offset = 0
        while offset + 4 <= size {
            let length = pointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: 4) {
                Int($0[0]) << 24 | Int($0[1]) << 16 | Int($0[2]) << 8 | Int($0[3])
            }
            offset += 4
            guard length > 0, length <= size - offset else { return }
            data.append(contentsOf: start)
            data.append(UnsafeRawPointer(pointer.advanced(by: offset)).assumingMemoryBound(to: UInt8.self), count: length)
            offset += length
        }
        guard offset == size, !data.isEmpty else { return }
        #if DEBUG
        if data.count >= 131072 {
            PerformanceDisk.shared.write("native.encoder largeFrame bytes=\(data.count) key=\(key) sourceNS=\(ticket.frame.timeStampNs)")
        }
        #endif
        let encoded = RTCEncodedImage()
        encoded.buffer = data; encoded.encodedWidth = Int32(width); encoded.encodedHeight = Int32(height)
        encoded.timeStamp = UInt32(bitPattern: ticket.frame.timeStamp)
        encoded.captureTimeMs = ticket.frame.timeStampNs / 1_000_000
        encoded.rotation = ticket.frame.rotation; encoded.frameType = key ? .videoFrameKey : .videoFrameDelta
        encoded.contentType = .screenshare; encoded.flags = 255; encoded.qp = -1
        let info = RTCCodecSpecificInfoH264(); info.packetizationMode = .nonInterleaved
        _ = callback(encoded, info)
    }
}

private final class ScreenH264DecoderFactory: NSObject, RTCVideoDecoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenH264Formats.codecs }
    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? { RTCVideoDecoderH264() }
}

/// A single native media engine for all four discovery/signaling methods.
enum NativeVideo {
    private static let logger: RTCCallbackLogger = {
        let logger = RTCCallbackLogger(); logger.severity = .warning
        logger.start { PerformanceDisk.shared.write("native.sdk \($0.prefix(1200))") }
        return logger
    }()
    static let factory: RTCPeerConnectionFactory = {
        // These parameters are verified against the pinned M156 binary/source.
        // Apply before creating any WebRTC object. The ObjC factory does not yet expose per-factory trials.
        RTCInitFieldTrialDictionary([
            "WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:100",
            "WebRTC-ForceSendPlayoutDelay": "min_ms:0,max_ms:100",
            "WebRTC-Video-Pacing": "factor:1.1,max_delay:60ms"
        ])
        _ = logger
        RTCInitializeSSL()
        RTCSetMinDebugLogLevel(.error)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-native-capture") { RTCSetMinDebugLogLevel(.info) }
        #endif
        return RTCPeerConnectionFactory(encoderFactory: ScreenH264EncoderFactory(),
                                        decoderFactory: ScreenH264DecoderFactory())
    }()
    static func packet(_ object: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 16384 else { return nil }
        return data
    }
    static func send(_ object: [String: Any], over connection: NWConnection) {
        guard let data = packet(object) else { return }
        var length = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }; packet.append(UInt8(20)); packet.append(data)
        connection.send(content: packet, completion: .idempotent)
    }
}

/// Capture once; each PeerConnection has its own encoder and congestion controller.
final class NativeScreenSource: @unchecked Sendable {
    let source = NativeVideo.factory.videoSource(forScreenCast: true)
    private lazy var capturer = RTCVideoCapturer(delegate: source)
    private let queue = DispatchQueue(label: "casting.native.capture", qos: .userInteractive)
    private let slot = DispatchSemaphore(value: 1)
    private var shape = ""
    private var lastTimestamp = -Double.infinity
    private let perf = StreamPerformance("native.capture")
    private var fps = 60
    private var dimension = 0
    private var paused = false
    var onResolution: ((String) -> Void)?
    func configure(fps: Int, dimension: Int = 0) {
        queue.async { self.fps = fps; self.dimension = dimension; self.shape = "" }
    }
    func setPaused(_ value: Bool) { queue.async { self.paused = value } }
    func append(_ sample: CMSampleBuffer) {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let orientation = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.intValue ?? 1
        append(pixel, time: pts.isFinite ? pts : ProcessInfo.processInfo.systemUptime, orientation: orientation)
    }
    func append(_ pixel: CVPixelBuffer, time: Double = ProcessInfo.processInfo.systemUptime, orientation: Int = 1) {
        let arrived = ProcessInfo.processInfo.systemUptime
        guard slot.wait(timeout: .now()) == .success else { perf.record("dropBusy"); return }
        queue.async {
            defer { self.slot.signal() }
            guard !self.paused, time.isFinite, time > self.lastTimestamp else { return }
            self.lastTimestamp = time
            self.perf.interval("sourceInterval", at: time)
            self.perf.record("queueWait", milliseconds: (ProcessInfo.processInfo.systemUptime - arrived) * 1000)
            let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel)
            let scale = self.dimension == 0 ? 1 : min(1, Double(self.dimension) / Double(max(w, h)))
            let outW = max(2, Int(Double(w) * scale) / 2 * 2), outH = max(2, Int(Double(h) * scale) / 2 * 2)
            let shape = "\(w)x\(h)->\(outW)x\(outH)@\(self.fps) rotation=\(orientation) pixelFormat=\(CVPixelBufferGetPixelFormatType(pixel))"
            if shape != self.shape {
                self.shape = shape
                self.source.adaptOutputFormat(toWidth: Int32(outW), height: Int32(outH), fps: Int32(self.fps))
                PerformanceDisk.shared.write("native.capture \(shape)")
                self.onResolution?("系统采集 \(w)×\(h) · 输出上限 \(outW)×\(outH)")
            }
            let rotation: RTCVideoRotation = orientation == 6 ? ._90 : orientation == 8 ? ._270 : orientation == 3 ? ._180 : ._0
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: rotation,
                                      timeStampNs: Int64(time * 1_000_000_000))
            self.source.capturer(self.capturer, didCapture: frame)
        }
    }
}

final class NativeVideoPeer: NSObject, RTCPeerConnectionDelegate, RTCVideoRenderer, RTCDataChannelDelegate, @unchecked Sendable {
    var sendSignal: (([String: Any]) -> Void)?
    private let renderLock = NSLock()
    private var imageHandler: ((CIImage) -> Void)?
    private var renderClosed = false
    var onImage: ((CIImage) -> Void)? {
        get { renderLock.lock(); defer { renderLock.unlock() }; return imageHandler }
        set { renderLock.lock(); imageHandler = newValue; renderLock.unlock() }
    }
    private let id = String(UUID().uuidString.prefix(8))
    private let sending: Bool
    private let internet: Bool
    private var budget = NativeVideoBudget()
    private var previousPackets: (count: Double, delay: Double, lost: Double)?
    private var remoteLost = 0.0
    private var selectedPath = ""
    private var firstFrameWork: DispatchWorkItem?
    var onConnected: (() -> Void)?
    var onSendingFPS: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    private var peer: RTCPeerConnection?
    private var diagnostics: RTCDataChannel?
    private var lastRemoteStat = 0.0
    private var remoteTrack: RTCVideoTrack?
    private var sender: RTCRtpSender?
    private var candidates: [RTCIceCandidate] = []
    private var remoteSet = false
    private var closed = false
    private var connected = false
    private var frames = 0
    private let receivePerf = StreamPerformance("native.receive")
    private var statsWork: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var bitrate: Int
    private var fps: Int
    init(source: NativeScreenSource? = nil, internet: Bool, bitrate: Int = 100_000_000, fps: Int = 60) {
        self.bitrate = bitrate; self.fps = fps; self.internet = internet; sending = source != nil
        super.init()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = internet ? [RTCIceServer(urlStrings: [InternetSettings.stunURL, "stun:stun.cloudflare.com:3478"])] : []
        config.iceTransportPolicy = .all
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer = NativeVideo.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        let control = RTCDataChannelConfiguration()
        control.isNegotiated = true; control.channelId = 0
        control.isOrdered = false; control.maxRetransmits = 0
        diagnostics = peer?.dataChannel(forLabel: "native-video-stats-v1", configuration: control)
        diagnostics?.delegate = self
        if let source {
            let track = NativeVideo.factory.videoTrack(with: source.source, trackId: UUID().uuidString)
            let options = RTCRtpTransceiverInit(); options.direction = .sendOnly
            let transceiver = peer?.addTransceiver(with: track, init: options)
            sender = transceiver?.sender
            applyQuality()
            _ = peer?.setBweMinBitrateBps(nil, currentBitrateBps: NSNumber(value: min(bitrate, 8_000_000)), maxBitrateBps: NSNumber(value: bitrate))
        } else {
            let options = RTCRtpTransceiverInit(); options.direction = .recvOnly
            _ = peer?.addTransceiver(of: .video, init: options)
        }
    }
    private func armTimeout() {
        guard timeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.fail("视频协商超时，请更新两端并检查网络可达性") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: work)
    }
    func quality(bitrate: Int, fps: Int) { self.bitrate = bitrate; self.fps = fps; applyQuality() }
    private func applyQuality() {
        guard let peer, let sender else { return }
        budget.clamp(upper: bitrate)
        let encoderLimit = internet ? budget.limit : bitrate
        let params = sender.parameters
        params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: encoderLimit)
            encoding.maxFramerate = NSNumber(value: fps)
        }
        sender.parameters = params
        _ = peer.setBweMinBitrateBps(nil, currentBitrateBps: nil, maxBitrateBps: NSNumber(value: bitrate))
    }
    func offer() { armTimeout(); description(offer: true) }
    private func description(offer: Bool) {
        let completion: (RTCSessionDescription?, Error?) -> Void = { [weak self] sdp, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                guard let sdp, error == nil else { self.fail("无法创建视频协商"); return }
                self.peer?.setLocalDescription(sdp) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, !self.closed else { return }
                        guard error == nil else { self.fail("无法设置视频协商"); return }
                        self.sendSignal?(["type": offer ? "offer" : "answer", "sdp": sdp.sdp])
                    }
                }
            }
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        if offer { peer?.offer(for: constraints, completionHandler: completion) }
        else { peer?.answer(for: constraints, completionHandler: completion) }
    }
    func receive(_ object: [String: Any]) {
        guard !closed else { return }
        switch object["type"] as? String {
        case "offer", "answer":
            armTimeout()
            guard let sdp = object["sdp"] as? String, sdp.utf8.count <= 12288,
                  sdp.contains("m=video"), !sdp.contains("m=audio") else {
                fail("对端未使用原生视频协议，请更新两端"); return
            }
            let offer = object["type"] as? String == "offer"
            peer?.setRemoteDescription(RTCSessionDescription(type: offer ? .offer : .answer, sdp: sdp)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.closed else { return }
                    guard error == nil else { self.fail("无法接受视频协商"); return }
                    self.remoteSet = true
                    for candidate in self.candidates { self.peer?.add(candidate, completionHandler: { _ in }) }
                    self.candidates.removeAll()
                    if offer { self.description(offer: false) }
                }
            }
        case "candidate":
            guard let sdp = object["candidate"] as? String, sdp.utf8.count <= 2048,
                  !sdp.contains(" typ relay"), let line = object["line"] as? Int32 else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line, sdpMid: object["mid"] as? String)
            if remoteSet { peer?.add(candidate, completionHandler: { _ in }) }
            else if candidates.count < 64 { candidates.append(candidate) }
        default: break
        }
    }
    func stop() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); statsWork?.cancel(); firstFrameWork?.cancel()
        renderLock.lock(); renderClosed = true; imageHandler = nil; renderLock.unlock()
        remoteTrack?.remove(self); remoteTrack = nil
        diagnostics?.delegate = nil; diagnostics?.close(); diagnostics = nil
        peer?.delegate = nil; peer?.close(); peer = nil; sender = nil
        candidates.removeAll(); onImage = nil
    }
    private func fail(_ message: String) { guard !closed else { return }; stop(); onError?(message) }
    #if DEBUG
    // Configure before negotiation. Used only by the local benchmark; nil in normal use.
    var onVerificationStats: (([[String: Any]]) -> Void)?
    func snapshotForVerification() {
        guard !closed else { return }
        peer?.statistics { [weak self] report in
            guard let self, !self.closed else { return }
            if let observer = self.onVerificationStats {
                let keys = Set(["targetBitrate", "encoderImplementation", "decoderImplementation", "mimeType", "framesEncoded", "framesDecoded", "framesPerSecond", "frameWidth", "frameHeight", "bytesSent", "bytesReceived", "packetsSent", "packetsReceived", "packetsLost", "totalPacketSendDelay", "totalEncodeTime", "totalDecodeTime", "freezeCount", "totalFreezesDuration", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay", "availableOutgoingBitrate", "currentRoundTripTime", "fractionLost", "retransmittedPacketsSent", "nackCount", "pliCount"])
                let selected = report.statistics.values.first { $0.type == "transport" }?.values["selectedCandidatePairId"] as? String
                observer(report.statistics.values.filter { ["outbound-rtp", "inbound-rtp", "remote-inbound-rtp"].contains($0.type) || $0.id == selected }.map { stat in
                    ["type": stat.type, "values": stat.values.filter { keys.contains($0.key) }]
                })
            }
        }
    }
    #endif
    private func stats() {
        guard !closed else { return }
        peer?.statistics { [weak self] report in
            guard let self, !self.closed else { return }
            if !self.sending {
                for stat in report.statistics.values where stat.type == "inbound-rtp" {
                    let allowed = ["framesDecoded", "framesPerSecond", "frameWidth", "frameHeight", "bytesReceived", "packetsLost", "jitter", "totalDecodeTime", "freezeCount", "totalFreezesDuration", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay", "nackCount", "pliCount"]
                    var values: [String: Any] = ["v":1]
                    for key in allowed { if let value = stat.values[key] { values[key] = value } }
                    if let data = NativeVideo.packet(values), data.count <= 2048 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.closed, let channel = self.diagnostics, channel.readyState == .open, channel.bufferedAmount < 4096 else { return }
                            _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
                        }
                    }
                }
            }
            let transport = report.statistics.values.first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }
            let pathID = transport?.values["selectedCandidatePairId"] as? String
            let pair = pathID.flatMap { report.statistics[$0] }
            let available = (pair?.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue ?? 0
            if let pathID, let pair {
                let local = (pair.values["localCandidateId"] as? String).flatMap { report.statistics[$0] }
                let remote = (pair.values["remoteCandidateId"] as? String).flatMap { report.statistics[$0] }
                let detail = "localType=\((local?.values["candidateType"] as? String) ?? "unknown") remoteType=\((remote?.values["candidateType"] as? String) ?? "unknown") protocol=\((remote?.values["protocol"] as? String) ?? "unknown")"
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.selectedPath != pathID else { return }
                    self.selectedPath = pathID
                    PerformanceDisk.shared.write("native.path id=\(self.id) pair=\(pathID) \(detail)")
                }
            }
            for stat in report.statistics.values where stat.type == "outbound-rtp" {
                if let count = stat.values["packetsSent"] as? NSNumber, let delay = stat.values["totalPacketSendDelay"] as? NSNumber {
                    let packets = count.doubleValue, totalDelay = delay.doubleValue
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed, self.internet else { return }
                        defer { self.previousPackets = (packets, totalDelay, self.remoteLost) }
                        guard let previous = self.previousPackets, packets > previous.count, totalDelay >= previous.delay else { return }
                        let wait = (totalDelay - previous.delay) / (packets - previous.count)
                        let loss = max(0, self.remoteLost - previous.lost) / (packets - previous.count)
                        let old = self.budget.limit
                        let next = self.budget.sample(upper: self.bitrate, available: available, sendWait: wait, loss: loss)
                        PerformanceDisk.shared.write("native.budget id=\(self.id) encoderLimit=\(next) bweAvailable=\(Int(available)) bweMax=\(self.bitrate) waitMS=\(Int(wait * 1000)) loss=\(loss)")
                        if old != next { self.applyQuality() }
                    }
                }
                if let fps = stat.values["framesPerSecond"] as? NSNumber {
                    DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onSendingFPS?(fps.doubleValue) }
                }
            }
            for stat in report.statistics.values where ["inbound-rtp", "outbound-rtp", "candidate-pair", "codec"].contains(stat.type) {
                let keys = ["targetBitrate", "totalPacketSendDelay", "packetsSent", "retransmittedPacketsSent", "framesEncoded", "framesDecoded", "framesPerSecond", "frameWidth", "frameHeight", "bytesSent", "bytesReceived", "packetsLost", "jitter", "totalEncodeTime", "totalDecodeTime", "totalFreezesDuration", "freezeCount", "currentRoundTripTime", "availableOutgoingBitrate", "qualityLimitationReason", "mimeType", "encoderImplementation", "decoderImplementation", "state", "nominated", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay", "keyFramesEncoded", "nackCount", "pliCount"]
                let values = keys.compactMap { key in stat.values[key].map { "\(key)=\($0)" } }.joined(separator: " ")
                PerformanceDisk.shared.write("native.stats id=\(self.id) \(stat.type) \(values)")
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.stats() }; statsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
        let orientation: Int32 = frame.rotation == ._90 ? 6 : frame.rotation == ._180 ? 3 : frame.rotation == ._270 ? 8 : 1
        receivePerf.interval("frameInterval")
        let image = CIImage(cvPixelBuffer: buffer.pixelBuffer).oriented(forExifOrientation: orientation)
        renderLock.lock()
        guard !renderClosed else { renderLock.unlock(); return }
        frames += 1
        let first = frames == 1
        let handler = imageHandler
        renderLock.unlock()
        handler?(image)
        if first { DispatchQueue.main.async { [weak self] in self?.firstFrameWork?.cancel() } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            PerformanceDisk.shared.write("native.ice id=\(self.id) state=\(newState.rawValue)")
            if newState == .connected || newState == .completed {
                guard !self.connected else { return }; self.connected = true
                self.timeout?.cancel(); self.applyQuality(); self.stats(); self.onConnected?()
                self.renderLock.lock(); let hasFrames = self.frames > 0; self.renderLock.unlock()
                if !self.sending && !hasFrames {
                    let work = DispatchWorkItem { [weak self] in self?.fail("已直连但未收到可解码画面，请检查发送端编码状态") }
                    self.firstFrameWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
                }
                PerformanceDisk.shared.write("native.connected media=SRTP codec=H264 videoDataChannel=false diagnosticsChannel=true")
            }
            if newState == .failed { self.fail("视频直连失败，当前网络可能无法穿透；未使用视频中继") }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !candidate.sdp.contains(" typ relay") else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, !self.connected else { return }
            self.sendSignal?(["type":"candidate", "candidate":candidate.sdp, "mid":candidate.sdpMid as Any? ?? NSNull(), "line":candidate.sdpMLineIndex])
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 2048 else { return }
        DispatchQueue.main.async { [weak self, weak dataChannel] in
            guard let self, !self.closed, self.diagnostics === dataChannel,
                  ProcessInfo.processInfo.systemUptime - self.lastRemoteStat >= 1,
                  let object = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any], object["v"] as? Int == 1 else { return }
            self.lastRemoteStat = ProcessInfo.processInfo.systemUptime
            self.remoteLost = (object["packetsLost"] as? NSNumber)?.doubleValue ?? self.remoteLost
            let allowed = ["framesDecoded", "framesPerSecond", "frameWidth", "frameHeight", "bytesReceived", "packetsLost", "jitter", "totalDecodeTime", "freezeCount", "totalFreezesDuration", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay", "nackCount", "pliCount"]
            let line = allowed.compactMap { key in (object[key] as? NSNumber).map { "\(key)=\($0)" } }.joined(separator: " ")
            PerformanceDisk.shared.write("native.remote id=\(self.id) \(line)")
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, let track = rtpReceiver.track as? RTCVideoTrack else { return }
            self.remoteTrack = track; track.add(self)
        }
    }
}

/// Signaling only: no byte tunnel, loopback listener, or video data channel.
final class NativeVideoRoom: @unchecked Sendable {
    let video: NativeVideoPeer
    var onRegistered: (() -> Void)?
    var onConnected: (() -> Void)?
    var onError: ((String) -> Void)?
    private let code: String
    private let sending: Bool
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var bytes = 0
    private var closed = false
    private var connected = false
    init(code: String, source: NativeScreenSource? = nil, bitrate: Int = 100_000_000, fps: Int = 60) {
        self.code = code; sending = source != nil
        video = NativeVideoPeer(source: source, internet: true, bitrate: bitrate, fps: fps)
    }
    func start() {
        guard MatchingCode.isValid(code) else { fail("匹配码格式错误"); return }
        video.sendSignal = { [weak self] in self?.send($0) }
        video.onError = { [weak self] in self?.fail($0) }
        video.onConnected = { [weak self] in
            guard let self else { return }; self.connected = true
            self.send(["type":"done"]); self.onConnected?()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 610; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); self.session = session
        let socket = session.webSocketTask(with: InternetSettings.signalingURL); self.socket = socket
        socket.maximumMessageSize = 16384; socket.resume()
        send(["role":sending ? "sender" : "receiver", "room":InternetSettings.room(code)])
        read(socket)
    }
    func stop() {
        guard !closed else { return }; closed = true
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil; video.stop()
    }
    private func fail(_ text: String) { guard !closed else { return }; stop(); onError?(text) }
    private func send(_ object: [String: Any]) {
        guard !closed, let socket, let data = NativeVideo.packet(object) else { return }
        bytes += data.count
        guard bytes <= 65536 else { fail("配对数据超过限制"); return }
        Task { [weak self] in
            do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
            catch { DispatchQueue.main.async { if self?.connected == false { self?.fail("配对发送失败") } } }
        }
    }
    private func read(_ socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            do {
                let message = try await socket.receive()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: return }
                    self.bytes += data.count
                    guard self.bytes <= 65536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.fail("配对响应无效"); return }
                    switch object["type"] as? String {
                    case "waiting": self.onRegistered?()
                    case "peer": if self.sending { self.video.offer() }
                    case "error": self.fail(object["message"] as? String ?? "配对失败")
                    default: self.video.receive(object)
                    }
                    if !self.closed { self.read(socket) }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    if !self.connected { self.fail("配对连接结束，请重试") }
                    else { self.socket = nil; self.session?.invalidateAndCancel(); self.session = nil }
                }
            }
        }
    }
}
