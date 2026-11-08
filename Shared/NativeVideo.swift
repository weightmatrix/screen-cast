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
    private let lock = NSLock()
    private let encoders = NSHashTable<AppleScreenEncoder>.weakObjects()
    func requestKeyFrame() {
        lock.lock(); let active = encoders.allObjects; lock.unlock()
        active.forEach { $0.requestKeyFrame() }
    }
    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenH264Formats.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        let encoder = AppleScreenEncoder(info)
        lock.lock(); encoders.add(encoder); lock.unlock()
        return encoder
    }
}
/// Public WebRTC encoder adapter: hardware VideoToolbox realtime H264, native RTP output.
/// No encoded video is sent through the application data channel.
private final class AppleScreenEncoder: NSObject, RTCVideoEncoder {
    private final class Ticket {
        let frame: RTCVideoFrame
        let started = ProcessInfo.processInfo.systemUptime
        let qp: Int?
        let budget: Int
        init(_ frame: RTCVideoFrame, qp: Int?, budget: Int) { self.frame = frame; self.qp = qp; self.budget = budget }
    }
    private let codec: RTCVideoCodecInfo
    private var session: VTCompressionSession?
    private var callback: RTCVideoEncoderCallback?
    private let lock = NSLock()
    private var pending = 0
    private var framePacer = EncoderFramePacer()
    private var quantizer = ScreenFrameQuantizer()
    private var allowManual = true
    private var manualQP = false
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
    func requestKeyFrame() { lock.lock(); keyNeeded = true; lock.unlock() }
    func implementationName() -> String { "AppleScreenVideoToolbox" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    func setCallback(_ callback: RTCVideoEncoderCallback?) { lock.lock(); self.callback = callback; lock.unlock() }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        _ = release()
        width = Int(settings.width); height = Int(settings.height)
        rate = max(1, settings.startBitrate); fps = max(1, settings.maxFramerate)
        lock.lock(); framePacer.reset(upper: Int(fps)); pacingFPS = Int(fps); pacingUpper = Int(fps); lock.unlock()
        nextEncodedNS = nil; scheduledFPS = 0; quantizer = ScreenFrameQuantizer()
        let attemptManual = allowManual && codec.parameters["profile-level-id"]?.hasPrefix("64") == true
        // Normal realtime rate control recovers without the low-latency mode's
        // prolonged frame starvation. Keep the hardware-only low-latency path on
        // older iOS, where the explicit hardware requirement is unavailable.
        var lowLatency = true
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        if #available(iOS 17.4, *) {
            specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            lowLatency = false
            if attemptManual {
                specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
                lowLatency = true
            }
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
            if attemptManual { allowManual = false; return startEncode(with: settings, numberOfCores: numberOfCores) }
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
                if attemptManual { allowManual = false; return startEncode(with: settings, numberOfCores: numberOfCores) }
                _ = release(); return -1
            }
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7200 as CFNumber)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 240 as CFNumber)
        if attemptManual {
            var support: Unmanaged<CFTypeRef>?
            let supportStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_SupportsBaseFrameQP, allocator: nil, valueOut: &support)
            let supported = (support?.takeRetainedValue() as? NSNumber)?.boolValue == true
            guard supportStatus == noErr, supported else {
                allowManual = false
                return startEncode(with: settings, numberOfCores: numberOfCores)
            }
            manualQP = true
        }
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
        PerformanceDisk.shared.write("native.encoder ready=\(width)x\(height) lowLatencyRequested=\(lowLatency) manualQP=\(manualQP) hardware=\(String(describing: hardwareValue)) hardwareStatus=\(hardwareStatus) profile=\(profile)")
        return 0
    }
    func release() -> Int {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil; pool = nil; appliedRate = 0; appliedFPS = 0; manualQP = false
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
        if manualQP {
            // BaseFrameQP controls every frame; Apple documents average/data limits as ignored in this mode.
            appliedRate = rate; appliedFPS = effectiveFPS
            return 0
        }
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
        // WebRTC already adapts input cadence. Allow half a frame of timestamp
        // jitter so this ceiling does not discard its irregular recovery frames.
        if let next = nextEncodedNS, frame.timeStampNs < next - interval / 2 {
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
        let frameQP: Int? = manualQP ? quantizer.qp : nil
        let frameBudget = max(256, Int(rate) * 1000 / 8 / max(1, pacingFPS))
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
        lock.lock(); let needsKey = keyNeeded; lock.unlock()
        let force = needsKey || frameTypes.contains { $0.intValue == Int(RTCFrameType.videoFrameKey.rawValue) }
        var properties: [CFString: Any] = [:]
        if force { lock.lock(); keyNeeded = true; lock.unlock(); properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if let frameQP { properties[kVTEncodeFrameOptionKey_BaseFrameQP] = frameQP }
        let ticket = Unmanaged.passRetained(Ticket(frame, qp: frameQP, budget: frameBudget)).toOpaque()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: input,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000), duration: .invalid,
            frameProperties: properties as CFDictionary,
            sourceFrameRefcon: ticket, infoFlagsOut: nil)
        if status != noErr {
            Unmanaged<Ticket>.fromOpaque(ticket).release()
            lock.lock(); pending -= 1; keyNeeded = true; lock.unlock()
            PerformanceDisk.shared.write("native.encoder submit status=\(status)"); return -1
        }
        return 0
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
        if let qp = ticket.qp {
            lock.lock(); let previousQP = quantizer.qp
            quantizer.observe(bytes: data.count, budget: ticket.budget, usedQP: qp, key: key)
            let nextQP = quantizer.qp; lock.unlock()
            if previousQP > 28 && nextQP <= 28 {
                PerformanceDisk.shared.write("native.encoder qualityRefined qp=\(nextQP) bytes=\(data.count) budget=\(ticket.budget)")
            }
        }
        let encoded = RTCEncodedImage()
        encoded.buffer = data; encoded.encodedWidth = Int32(width); encoded.encodedHeight = Int32(height)
        encoded.timeStamp = UInt32(bitPattern: ticket.frame.timeStamp)
        encoded.captureTimeMs = ticket.frame.timeStampNs / 1_000_000
        encoded.rotation = ticket.frame.rotation; encoded.frameType = key ? .videoFrameKey : .videoFrameDelta
        encoded.contentType = .screenshare; encoded.flags = 255; encoded.qp = NSNumber(value: ticket.qp ?? -1)
        let info = RTCCodecSpecificInfoH264(); info.packetizationMode = .nonInterleaved
        let accepted = callback(encoded, info)
        if key && accepted { lock.lock(); keyNeeded = false; lock.unlock(); perf.record("keyframe") }
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
    static let initialize: Void = {
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
    let audio: NativeAudioInput
    let audioDevice: NativeAudioDevice
    let factory: RTCPeerConnectionFactory
    private let encoderFactory = ScreenH264EncoderFactory()
    func requestKeyFrame() { encoderFactory.requestKeyFrame() }
    let source: RTCVideoSource
    init() {
        _ = NativeVideo.initialize
        let audio = NativeAudioInput(), device: NativeAudioDevice
        self.audio = audio
        device = NativeAudioDevice(input: audio); audioDevice = device
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: ScreenH264DecoderFactory(), audioDevice: device)
        source = factory.videoSource(forScreenCast: true)
    }
    func factory(audioDevice: NativeAudioDevice) -> RTCPeerConnectionFactory {
        RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: ScreenH264DecoderFactory(), audioDevice: audioDevice)
    }
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
        append(pixel, time: pts.isFinite ? pts : ProcessInfo.processInfo.systemUptime,
               orientation: ReplaySampleOrientation.correction(orientation))
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
    let diagnosticID = UUID().uuidString
    private var id: String { String(diagnosticID.prefix(8)) }
    private var remoteDevice = "接收设备"
    var onDiagnostic: ((PeerDiagnostic) -> Void)?
    private let sending: Bool
    private let internet: Bool
    private var budget = NativeVideoBudget()
    private var previousPackets: (count: Double, delay: Double, lost: Double, bytes: Double, time: Double)?
    private var remoteLost = 0.0
    private var selectedPath = ""
    private var mediaCounters: [String: Double] = [:]
    private var firstFrameWork: DispatchWorkItem?
    private var disconnectedWork: DispatchWorkItem?
    var onConnected: (() -> Void)?
    var onSendingFPS: ((Double) -> Void)?
    var onReceiveTiming: ((ReceiveTiming) -> Void)?
    private var receiveTimingSampler = ReceiveTimingSampler()
    var onError: ((String) -> Void)?
    private var peer: RTCPeerConnection?
    private weak var captureSource: NativeScreenSource?
    private var mediaFactory: RTCPeerConnectionFactory?
    private var audioDevice: NativeAudioDevice?
    private var audioTrack: RTCAudioTrack?
    #if DEBUG
    var onVerificationAudio: (([Int16], [Float]) -> Void)? {
        get { audioDevice?.onVerificationPCM }
        set { audioDevice?.onVerificationPCM = newValue }
    }
    #endif
    #if DEBUG
    var onVerificationRoomMessage: (([String: Any]) -> Void)?
    func roomAudioVerificationSummary() -> String { audioDevice?.verificationSummary() ?? "missing audio device" }
    func configureRoomVerification(microphone: NativeAudioInput? = nil) {
        audioDevice?.verificationMicrophone = microphone; audioDevice?.verificationMuteHardware = true
    }
    func sendRoomVerification(_ packet: [String: Any]) -> Bool {
        guard let channel = conversation, channel.readyState == .open, channel.bufferedAmount < 32768,
              let data = try? JSONSerialization.data(withJSONObject: packet), data.count <= 4096 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    #endif
    func receiveAudio(page: Bool, microphone: Bool) { audioDevice?.receive(page: page, microphone: microphone) }
    #if os(macOS)
    func recordPlayback(_ handler: ((UnsafeBufferPointer<Float>, Double) -> Void)?) {
        audioDevice?.recordPlayback(handler)
    }
    #endif
    private let roomPacketLock = NSLock()
    private var roomPacketTimes: [Double] = []
    private var conversation: RTCDataChannel?
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
    let directAudit: DirectConnectionAudit?
    init(source: NativeScreenSource? = nil, internet: Bool, bitrate: Int = 100_000_000, fps: Int = 60, auditDirect: Bool = false, auditSessionID: String? = nil) {
        self.bitrate = bitrate; self.fps = fps; self.internet = internet; sending = source != nil
        directAudit = auditDirect ? DirectConnectionAudit(sessionID: auditSessionID, sending: source != nil) : nil
        super.init()
        captureSource = source
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = internet ? [RTCIceServer(urlStrings: [InternetSettings.stunURL, "stun:stun.cloudflare.com:3478"])] : []
        config.iceTransportPolicy = .all
        config.candidateNetworkPolicy = .all
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        _ = NativeVideo.initialize
        let audio = NativeAudioDevice(input: source?.audio, roomPeer: diagnosticID, hosting: source != nil)
        audioDevice = audio
        let factory = source?.factory(audioDevice: audio) ?? RTCPeerConnectionFactory(encoderFactory: ScreenH264EncoderFactory(), decoderFactory: ScreenH264DecoderFactory(), audioDevice: audio)
        mediaFactory = factory
        peer = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        let audioOptions = RTCRtpTransceiverInit(); audioOptions.direction = .sendRecv
        do {
            let constraints = RTCMediaConstraints(mandatoryConstraints: ["googEchoCancellation":"false", "googAutoGainControl":"false", "googNoiseSuppression":"false"], optionalConstraints: nil)
            let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "page-left-mic-right-v1")
            audioTrack = track
            if source != nil { _ = peer?.addTransceiver(with: track, init: audioOptions) }
        }
        let control = RTCDataChannelConfiguration()
        control.isNegotiated = true; control.channelId = 0
        control.isOrdered = false; control.maxRetransmits = 0
        diagnostics = peer?.dataChannel(forLabel: "native-video-stats-v1", configuration: control)
        diagnostics?.delegate = self
        let chat = RTCDataChannelConfiguration(); chat.isNegotiated = true; chat.channelId = 1; chat.isOrdered = true
        conversation = peer?.dataChannel(forLabel: "touping-room-text-v1", configuration: chat)
        conversation?.delegate = self
        RoomSession.shared.attach(diagnosticID, host: sending) { [weak self] packet in
            guard let self, !self.closed, let channel = self.conversation, channel.readyState == .open,
                  channel.bufferedAmount < 32768, let data = try? JSONSerialization.data(withJSONObject: packet), data.count <= 4096 else { return false }
            return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
        if let source {
            let track = factory.videoTrack(with: source.source, trackId: UUID().uuidString)
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
    private static func audioSDP(_ source: String) -> String {
        var lines = source.components(separatedBy: "\r\n")
        let opus = lines.first { $0.hasPrefix("a=rtpmap:") && $0.lowercased().contains("opus/48000") }?.dropFirst(9).split(separator: " ").first.map(String.init)
        if let opus {
            let prefix = "a=fmtp:\(opus) "
            if let i = lines.firstIndex(where: { $0.hasPrefix(prefix) }) {
                let retained = lines[i].dropFirst(prefix.count).split(separator: ";").filter {
                    let key = $0.trimmingCharacters(in: .whitespaces).split(separator: "=").first.map(String.init) ?? ""
                    return !["stereo", "sprop-stereo", "usedtx", "maxaveragebitrate"].contains(key)
                }
                lines[i] = prefix + retained.joined(separator: ";") + ";stereo=1;sprop-stereo=1;usedtx=0;maxaveragebitrate=128000"
            }
        }
        if !lines.contains("a=x-touping-audio:split-v1") { lines.insert("a=x-touping-audio:split-v1", at: min(4, lines.count)) }
        return lines.joined(separator: "\r\n")
    }
    func offer() { armTimeout(); description(offer: true) }
    private func description(offer: Bool) {
        let completion: (RTCSessionDescription?, Error?) -> Void = { [weak self] sdp, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                guard let original = sdp, error == nil else { self.fail("无法创建视频协商"); return }
                let sdp = RTCSessionDescription(type: original.type, sdp: Self.audioSDP(original.sdp))
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
                  sdp.contains("m=video"), (!sdp.contains("m=audio") || sdp.contains("a=x-touping-audio:split-v1")) else {
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
                    if offer {
                        if !self.sending, let track = self.audioTrack,
                           let transceiver = self.peer?.transceivers.first(where: { $0.mediaType == .audio && $0.mid != nil }) {
                            transceiver.sender.track = track
                            var directionError: NSError?
                            transceiver.setDirection(.sendRecv, error: &directionError)
                            if directionError != nil { self.fail("无法启用双向音频轨道"); return }
                        }
                        self.description(offer: false)
                    }
                }
            }
        case "candidate":
            guard let sdp = object["candidate"] as? String, sdp.utf8.count <= 2048,
                  !sdp.contains(" typ relay"), let line = object["line"] as? Int32 else { return }
            if internet { PerformanceDisk.shared.write("native.iceCandidate id=\(id) remote \(Self.candidateSummary(sdp))") }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line, sdpMid: object["mid"] as? String)
            if remoteSet { peer?.add(candidate, completionHandler: { _ in }) }
            else if candidates.count < 64 { candidates.append(candidate) }
        default: break
        }
    }
    func stop() {
        directAudit?.record("ended")
        guard !closed else { return }; closed = true
        timeout?.cancel(); statsWork?.cancel(); firstFrameWork?.cancel(); disconnectedWork?.cancel()
        renderLock.lock(); renderClosed = true; imageHandler = nil; renderLock.unlock()
        remoteTrack?.remove(self); remoteTrack = nil
        RoomSession.shared.detach(diagnosticID)
        conversation?.delegate = nil; conversation?.close(); conversation = nil
        diagnostics?.delegate = nil; diagnostics?.close(); diagnostics = nil
        peer?.delegate = nil; peer?.close(); peer = nil; sender = nil
        candidates.removeAll(); audioTrack = nil; audioDevice = nil; mediaFactory = nil; onImage = nil
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
                let keys = Set(["targetBitrate", "encoderImplementation", "decoderImplementation", "mimeType", "framesEncoded", "framesDecoded", "framesPerSecond", "frameWidth", "frameHeight", "bytesSent", "bytesReceived", "packetsSent", "packetsReceived", "packetsLost", "totalPacketSendDelay", "totalEncodeTime", "totalDecodeTime", "freezeCount", "totalFreezesDuration", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay", "availableOutgoingBitrate", "currentRoundTripTime", "fractionLost", "kind", "retransmittedPacketsSent", "nackCount", "pliCount"])
                let selected = report.statistics.values.first { $0.type == "transport" }?.values["selectedCandidatePairId"] as? String
                observer(report.statistics.values.filter { (["outbound-rtp", "inbound-rtp", "remote-inbound-rtp"].contains($0.type) && ($0.values["kind"] as? String == "video" || $0.values["mediaType"] as? String == "video")) || $0.id == selected }.map { stat in
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
                for stat in report.statistics.values where stat.type == "inbound-rtp" && (stat.values["kind"] as? String == "video" || stat.values["mediaType"] as? String == "video") {
                    let allowed = ["framesDecoded", "framesPerSecond", "frameWidth", "frameHeight", "bytesReceived", "packetsLost", "jitter", "totalDecodeTime", "freezeCount", "totalFreezesDuration", "jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferTargetDelay", "nackCount", "pliCount"]
                    var values: [String: Any] = ["v":1, "device": HostIdentity.description]
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
            if !self.sending {
                let inbound = report.statistics.values.first {
                    $0.type == "inbound-rtp" && ($0.values["kind"] as? String == "video" || $0.values["mediaType"] as? String == "video")
                }
                let rtt = (pair?.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                let jitter = (inbound?.values["jitterBufferDelay"] as? NSNumber)?.doubleValue
                let emitted = (inbound?.values["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue
                let decode = (inbound?.values["totalDecodeTime"] as? NSNumber)?.doubleValue
                let decoded = (inbound?.values["framesDecoded"] as? NSNumber)?.doubleValue
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.onReceiveTiming?(self.receiveTimingSampler.sample(rtt: rtt, jitter: jitter, emitted: emitted, decode: decode, decoded: decoded))
                }
            }
            if let pair {
                func endpoint(_ key: String) -> String {
                    guard let cid = pair.values[key] as? String, let candidate = report.statistics[cid] else { return "—" }
                    let address = (candidate.values["address"] as? String) ?? (candidate.values["ip"] as? String) ?? "隐藏地址"
                    let port = (candidate.values["port"] as? NSNumber)?.stringValue ?? "—"
                    let proto = (candidate.values["protocol"] as? String) ?? "UDP"
                    return "\(address.contains(":") ? "[" + address + "]" : address):\(port) \(proto)"
                }
                let rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                let local = endpoint("localCandidateId"), remote = endpoint("remoteCandidateId")
                let lc = (pair.values["localCandidateId"] as? String).flatMap { report.statistics[$0] }?.values ?? [:]
                let rc = (pair.values["remoteCandidateId"] as? String).flatMap { report.statistics[$0] }?.values ?? [:]
                let interface = MediaPath.interface(local: lc, remote: rc)
                let route = MediaPath.route(local: lc, remote: rc, interface: interface)
                let interfaceText = MediaPath.interfaceText(interface, candidate: lc)
                var counters: [String: Double] = [:], flowing: [String] = []
                for stat in report.statistics.values where stat.type == "outbound-rtp" || stat.type == "inbound-rtp" {
                    guard let kind = (stat.values["kind"] ?? stat.values["mediaType"]) as? String, ["video", "audio"].contains(kind) else { continue }
                    let outbound = stat.type == "outbound-rtp"
                    let count = (stat.values[outbound ? "bytesSent" : "bytesReceived"] as? NSNumber)?.doubleValue ?? 0
                    counters[stat.id] = count
                    guard count > (self.mediaCounters[stat.id] ?? 0) else { continue }
                    let codec = (stat.values["codecId"] as? String).flatMap { report.statistics[$0]?.values["mimeType"] as? String } ?? kind
                    let label = (outbound ? "发送" : "接收") + (kind == "video" ? "画面" : "声音") + "（" + String(codec.prefix(32)) + "）"
                    if !flowing.contains(label) { flowing.append(label) }
                }
                for stat in report.statistics.values where stat.type == "data-channel" {
                    guard let label = stat.values["label"] as? String, ["touping-room-text-v1", "native-video-stats-v1"].contains(label) else { continue }
                    for (key, direction) in [("bytesSent", "发送"), ("bytesReceived", "接收")] {
                        let id = stat.id + key, count = (stat.values[key] as? NSNumber)?.doubleValue ?? 0
                        counters[id] = count
                        if count > (self.mediaCounters[id] ?? 0) {
                            let text = direction + (label == "touping-room-text-v1" ? "文字/控制" : "诊断数据")
                            if !flowing.contains(text) { flowing.append(text) }
                        }
                    }
                }
                self.mediaCounters = counters
                let signals = flowing.isEmpty ? "本次采样无新增可统计数据" : flowing.sorted().joined(separator: "、")
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.onDiagnostic?(PeerDiagnostic(id: self.diagnosticID, device: self.remoteDevice,
                        route: route, localEndpoint: local, remoteEndpoint: remote,
                        rttMS: rtt.flatMap { $0.isFinite && $0 >= 0 ? $0 * 1000 : nil }, networkInterface: interfaceText, signals: signals))
                }
            }
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
            for stat in report.statistics.values where stat.type == "outbound-rtp" && (stat.values["kind"] as? String == "video" || stat.values["mediaType"] as? String == "video") {
                if let count = stat.values["packetsSent"] as? NSNumber, let delay = stat.values["totalPacketSendDelay"] as? NSNumber {
                    let packets = count.doubleValue, totalDelay = delay.doubleValue
                    let mediaBytes = max(0, ((stat.values["bytesSent"] as? NSNumber)?.doubleValue ?? 0) -
                                         ((stat.values["retransmittedBytesSent"] as? NSNumber)?.doubleValue ?? 0))
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed, self.internet else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        defer { self.previousPackets = (packets, totalDelay, self.remoteLost, mediaBytes, now) }
                        guard let previous = self.previousPackets, packets > previous.count, totalDelay >= previous.delay, mediaBytes >= previous.bytes, now > previous.time else { return }
                        let wait = (totalDelay - previous.delay) / (packets - previous.count)
                        let loss = max(0, self.remoteLost - previous.lost) / (packets - previous.count)
                        let old = self.budget.limit
                        let utilization = (mediaBytes - previous.bytes) * 8 / (now - previous.time) / Double(max(1, old))
                        let next = self.budget.sample(upper: self.bitrate, available: available, sendWait: wait, loss: loss, utilization: utilization)
                        PerformanceDisk.shared.write("native.budget id=\(self.id) encoderLimit=\(next) bweAvailable=\(Int(available)) bweMax=\(self.bitrate) waitMS=\(Int(wait * 1000)) loss=\(loss) utilization=\(utilization)")
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
                self.disconnectedWork?.cancel(); self.disconnectedWork = nil
                guard !self.connected else { return }; self.connected = true
                self.directAudit?.record("connected")
                self.timeout?.cancel(); self.captureSource?.requestKeyFrame(); self.applyQuality(); self.stats(); self.onConnected?()
                self.renderLock.lock(); let hasFrames = self.frames > 0; self.renderLock.unlock()
                if !self.sending && !hasFrames {
                    let work = DispatchWorkItem { [weak self] in self?.fail("已直连但未收到可解码画面，请检查发送端编码状态") }
                    self.firstFrameWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
                }
                PerformanceDisk.shared.write("native.connected media=SRTP codec=H264 videoDataChannel=false diagnosticsChannel=true")
            }
            if newState == .failed { self.fail("视频直连失败，当前网络可能无法穿透；未使用视频中继") }
            if newState == .disconnected, self.disconnectedWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.fail("网络连接中断") }
                self.disconnectedWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            }
        }
    }
    private static func candidateSummary(_ candidate: String) -> String {
        let fields = candidate.split(separator: " ").map(String.init)
        let value = fields.firstIndex(of: "typ").flatMap { $0 + 1 < fields.count ? fields[$0 + 1] : nil } ?? "unknown"
        let type = ["host", "srflx", "prflx", "relay"].contains(value) ? value : "unknown"
        let address = fields.count > 4 ? fields[4] : ""
        let family = address.hasSuffix(".local") ? "mdns" : address.contains(":") ? "ipv6" : "ipv4"
        return "type=\(type) family=\(family)"
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if internet { PerformanceDisk.shared.write("native.iceGather id=\(id) state=\(newState.rawValue)") }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !candidate.sdp.contains(" typ relay") else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, !self.connected else { return }
            if self.internet { PerformanceDisk.shared.write("native.iceCandidate id=\(self.id) local \(Self.candidateSummary(candidate.sdp))") }
            self.sendSignal?(["type":"candidate", "candidate":candidate.sdp, "mid":candidate.sdpMid as Any? ?? NSNull(), "line":candidate.sdpMLineIndex])
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self, weak dataChannel] in
            guard let self, let dataChannel, self.conversation === dataChannel, dataChannel.readyState == .open else { return }
            RoomSession.shared.opened(self.diagnosticID)
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 4096 else { return }
        if conversation === dataChannel {
            roomPacketLock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            roomPacketTimes = roomPacketTimes.filter { now - $0 < 10 }
            let allowed = roomPacketTimes.count < (sending ? 32 : 160)
            if allowed { roomPacketTimes.append(now) }; roomPacketLock.unlock()
            guard allowed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, let object = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else { return }
                #if DEBUG
                self.onVerificationRoomMessage?(object)
                #endif
                RoomSession.shared.receive(object, from: self.diagnosticID)
            }; return
        }
        guard buffer.data.count <= 2048 else { return }
        DispatchQueue.main.async { [weak self, weak dataChannel] in
            guard let self, !self.closed, self.diagnostics === dataChannel,
                  ProcessInfo.processInfo.systemUptime - self.lastRemoteStat >= 1,
                  let object = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any], object["v"] as? Int == 1 else { return }
            self.lastRemoteStat = ProcessInfo.processInfo.systemUptime
            if let name = object["device"] as? String { self.remoteDevice = String(name.filter { !$0.isNewline }.prefix(80)) }
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
/// One lightweight registration, many independent applicants and native media peers.
final class NativeVideoHost: @unchecked Sendable {
    var onRegistered: (() -> Void)?
    var onRequest: ((String, String, String, String) -> Void)?
    var onPeerCreated: ((String, NativeVideoPeer) -> Void)?
    var onChanged: (() -> Void)?
    var onEnded: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let code: String
    private let password: String
    private let makePeer: () -> NativeVideoPeer
    private var peers: [String: NativeVideoPeer] = [:]
    private var connected = Set<String>()
    private var pending = Set<String>()
    private var accepted = Set<String>()
    private var audits: [String: DirectConnectionAudit] = [:]
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var retry: DispatchWorkItem?
    private var stopped = false
    private var bytes = 0
    var videos: [NativeVideoPeer] { Array(peers.values) }
    var connectedCount: Int { connected.count }
    init(code: String, password: String, makePeer: @escaping () -> NativeVideoPeer) {
        self.code = code; self.password = password; self.makePeer = makePeer
    }
    func start() {
        guard !stopped, socket == nil, AdmissionCredentials.validPassword(password) else { return }
        bytes = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 610; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); self.session = session
        let socket = session.webSocketTask(with: InternetSettings.signalingURL); self.socket = socket
        socket.maximumMessageSize = 16384; socket.resume()
        send(["role":"sender", "protocol":2, "room":InternetSettings.room(code),
              "verifier":AdmissionCredentials.verifier(password: password, invitation: code), "device":DeviceAuditMetadata.value])
        read(socket)
    }
    func respond(_ id: String, accept: Bool) {
        guard pending.contains(id), !accepted.contains(id) else { return }
        if accept { accepted.insert(id) }
        else { pending.remove(id); onEnded?(id) }
        send(["type":accept ? "approve" : "reject", "id":id])
    }
    func disconnect(_ diagnosticID: String) {
        guard let id = peers.first(where: { $0.value.diagnosticID == diagnosticID })?.key else { return }
        send(["type":"leave", "id":id]); remove(id)
    }
    private func remove(_ id: String) {
        pending.remove(id); accepted.remove(id); connected.remove(id)
        peers.removeValue(forKey: id)?.stop(); audits.removeValue(forKey: id)?.record("ended")
        onEnded?(id); onChanged?()
    }
    func stop() {
        stopped = true; retry?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        for id in Set(peers.keys).union(pending).union(accepted) { remove(id) }
    }
    private func lost(_ old: URLSessionWebSocketTask) {
        guard socket === old, !stopped else { return }
        socket = nil; session?.invalidateAndCancel(); session = nil
        for id in Set(peers.keys).union(pending).union(accepted) where !connected.contains(id) { remove(id) }
        onError?("公网邀请暂时断开，正在重新登记；已连接画面保持直传")
        let work = DispatchWorkItem { [weak self] in self?.start() }; retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    private func send(_ packet: [String: Any]) {
        guard !stopped, let socket, let data = NativeVideo.packet(packet) else { return }
        bytes += data.count
        guard bytes <= 2 * 1024 * 1024 else { lost(socket); return }
        Task { [weak self] in
            do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
            catch { DispatchQueue.main.async { self?.lost(socket) } }
        }
    }
    private func read(_ socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            do {
                let message = try await socket.receive()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.socket === socket, !self.stopped else { return }
                    let data: Data
                    switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: self.lost(socket); return }
                    self.bytes += data.count
                    guard self.bytes <= 2 * 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.lost(socket); return }
                    let id = object["id"] as? String ?? ""
                    switch object["type"] as? String {
                    case "waiting": self.onRegistered?()
                    case "request":
                        guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                              let text = object["application"] as? String, let application = AdmissionCredentials.application(text),
                              let ip = object["ip"] as? String, ip.utf8.count <= 64, self.pending.count < 64 else { self.send(["type":"reject","id":id]); break }
                        self.pending.insert(id); self.onRequest?(id, application, ip, RoomSession.name(object["nickname"] as? String ?? "", fallback: "访客"))
                    case "approved":
                        guard self.accepted.contains(id), self.peers[id] == nil else { break }
                        self.pending.remove(id)
                        let peer = self.makePeer(); self.peers[id] = peer
                        self.audits[id] = DirectConnectionAudit(sessionID: id, sending: true, route: "internet_code")
                        peer.sendSignal = { [weak self] packet in var object = packet; object["id"] = id; self?.send(object) }
                        peer.onConnected = { [weak self, weak peer] in
                            guard let self, let peer, self.peers[id] === peer else { return }
                            self.connected.insert(id); self.audits[id]?.record("connected")
                            self.send(["type":"done", "id":id]); self.onChanged?()
                        }
                        peer.onError = { [weak self] _ in self?.remove(id) }
                        self.onPeerCreated?(id, peer); peer.offer()
                    case "left": if !self.connected.contains(id) { self.remove(id) }
                    case "error":
                        self.onError?(object["message"] as? String ?? "公网邀请失败")
                    default: self.peers[id]?.receive(object)
                    }
                    if self.socket === socket { self.read(socket) }
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.lost(socket) } }
        }
    }
}

final class NativeVideoRoom: @unchecked Sendable {
    let video: NativeVideoPeer
    var onWaitingApproval: (() -> Void)?
    var onApproved: (() -> Void)?
    var onRegistered: (() -> Void)?
    private var lifecycleAudit: DirectConnectionAudit?
    private var roomTimeout: DispatchWorkItem?
    var onConnected: (() -> Void)?
    var onError: ((String) -> Void)?
    private let code: String
    private let sending: Bool
    private let password: String
    private let application: String
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var bytes = 0
    private var closed = false
    private var connected = false
    init(code: String, password: String = "", application: String = "", source: NativeScreenSource? = nil, bitrate: Int = 100_000_000, fps: Int = 60) {
        self.password = password; self.application = application
        self.code = code; sending = source != nil
        video = NativeVideoPeer(source: source, internet: true, bitrate: bitrate, fps: fps)
    }
    func start() {
        guard !sending, MatchingCode.isValid(code), AdmissionCredentials.validPassword(password), AdmissionCredentials.application(application) != nil else { fail("请填写连接密码和1至200字申请文字"); return }
        video.sendSignal = { [weak self] in self?.send($0) }
        video.onError = { [weak self] in self?.fail($0) }
        video.onConnected = { [weak self] in
            guard let self else { return }; self.connected = true
            self.lifecycleAudit?.record("connected"); self.roomTimeout?.cancel()
            self.send(["type":"done"]); self.onConnected?()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 610; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); self.session = session
        let socket = session.webSocketTask(with: InternetSettings.signalingURL); self.socket = socket
        socket.maximumMessageSize = 16384; socket.resume()
        send(["role":sending ? "sender" : "receiver", "room":InternetSettings.room(code), "device": DeviceAuditMetadata.value, "protocol": 2])
        if !sending { armConnectionTimeout() }
        read(socket)
    }
    private func armConnectionTimeout() {
        roomTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.fail("接入申请或连接超时，请重试") }
        roomTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 340, execute: timeout)
    }
    func stop() {
        guard !closed else { return }; closed = true
        roomTimeout?.cancel(); lifecycleAudit?.record("ended")
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
                    case "challenge":
                        guard let nonce = object["nonce"] as? String, nonce.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { self.fail("无效连接验证"); return }
                        self.send(["type":"apply", "proof":AdmissionCredentials.proof(verifier: AdmissionCredentials.verifier(password: self.password, invitation: self.code), nonce: nonce), "application":self.application, "nickname":RoomSession.shared.nickname])
                    case "waiting": self.onRegistered?()
                    case "waiting_approval": self.onWaitingApproval?()
                    case "approved":
                        self.onApproved?()
                        if let id = object["session_id"] as? String {
                            self.lifecycleAudit = DirectConnectionAudit(sessionID: id, sending: self.sending, route: "internet_code")
                        }
                        if self.sending { self.video.offer() }
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

#if DEBUG
/// Exercises real Opus/SRTP, stereo bus isolation and live receive/source mutes.
@MainActor enum NativeAudioVerification {
    static func run() async {
        let source = NativeScreenSource()
        let sender = NativeVideoPeer(source: source, internet: false)
        let receiver = NativeVideoPeer(internet: false)
        sender.configureRoomVerification(); receiver.configureRoomVerification()
        sender.sendSignal = { [weak receiver] in receiver?.receive($0) }
        receiver.sendSignal = { [weak sender] in sender?.receive($0) }
        defer { sender.stop(); receiver.stop() }
        sender.onError = { NSLog("NativeAudio FAIL sender=%@", $0) }
        receiver.onError = { NSLog("NativeAudio FAIL receiver=%@", $0) }
        sender.offer()
        let lock = NSLock()
        var captured: [Float] = []
        receiver.onVerificationAudio = { _, mixed in lock.lock(); captured.append(contentsOf: mixed); lock.unlock() }
        func sample(_ values: [Int16], offset: Int, pageFormat: Bool = false) -> CMSampleBuffer? {
            let rate: Int32 = pageFormat ? 44100 : 48000
            let replay = pageFormat && ProcessInfo.processInfo.arguments.contains("--verify-replaykit-audio")
            let packed = pageFormat && ProcessInfo.processInfo.arguments.contains("--verify-packed-audio")
            let stride = replay ? 4 : (packed ? 6 : (pageFormat ? 8 : 2))
            let bytes: Data
            if replay {
                bytes = Data(values.flatMap { value -> [UInt8] in
                    let raw = UInt16(bitPattern: value)
                    return [UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
                })
            } else if packed {
                bytes = Data(values.flatMap { value -> [UInt8] in
                    let raw = UInt32(bitPattern: Int32(value) << 8)
                    let sample = [UInt8(truncatingIfNeeded: raw >> 16), UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
                    return sample + sample
                })
            } else { bytes = pageFormat ? values.flatMap { [Float($0) / 32768, Float($0) / 32768] }.withUnsafeBytes { Data($0) } : values.withUnsafeBytes { Data($0) } }
            var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: (packed || replay ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian : (pageFormat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)) | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(stride), mFramesPerPacket: 1, mBytesPerFrame: UInt32(stride), mChannelsPerFrame: pageFormat ? 2 : 1, mBitsPerChannel: replay ? 16 : (packed ? 24 : (pageFormat ? 32 : 16)), mReserved: 0)
            var format: CMAudioFormatDescription?, block: CMBlockBuffer?, result: CMSampleBuffer?
            guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
                    blockBufferOut: &block) == noErr, let block, let format else { return nil }
            bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                presentationTimeStamp: CMTime(value: Int64(offset), timescale: rate), decodeTimeStamp: .invalid)
            var size = stride
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: values.count,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &result) == noErr else { return nil }
            return result
        }
        var offset = 0, pageOffset = 0
        let clock = ProcessInfo.processInfo.systemUptime
        for (name, receivePage, receiveMic, sendPage, sendMic) in [
            ("both", true, true, true, true), ("page", true, false, true, true),
            ("mic", false, true, true, true), ("muted", false, false, true, true),
            ("sourcePageOff", true, true, false, true), ("sourceMicOff", true, true, true, false)
        ] {
            receiver.receiveAudio(page: receivePage, microphone: receiveMic)
            source.audio.configure(page: sendPage, microphone: sendMic)
            for tick in 0..<120 {
                let elapsed = ProcessInfo.processInfo.systemUptime - clock
                while pageOffset + 1024 <= Int(elapsed * 44100) {
                    let page = (0..<1024).map { Int16(6000 * sin(2 * .pi * 440 * Double(pageOffset + $0) / 44100)) }
                    if let p = sample(page, offset: pageOffset, pageFormat: true) { source.audio.append(p, microphone: false) }
                    pageOffset += 1024
                }
                while offset + 480 <= Int(elapsed * 48000) {
                let mic = (0..<480).map { Int16(6000 * sin(2 * .pi * 880 * Double(offset + $0) / 48000)) }
                if let m = sample(mic, offset: offset) { source.audio.append(m, microphone: true) }
                offset += 480
                }
                if tick == 70 { lock.lock(); captured.removeAll(); lock.unlock() }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            lock.lock(); let samples = captured; lock.unlock()
            func amplitude(_ hz: Double) -> Double {
                guard !samples.isEmpty else { return 0 }
                var total = 0.0, blocks = 0
                for start in stride(from: 0, to: samples.count - 479, by: 480) {
                    var real = 0.0, imag = 0.0
                    for i in 0..<480 { let angle = 2 * .pi * hz * Double(i) / 48000; real += Double(samples[start + i]) * cos(angle); imag += Double(samples[start + i]) * sin(angle) }
                    total += 2 * hypot(real, imag) / 480; blocks += 1
                }
                return total / Double(max(1, blocks))
            }
            let p = amplitude(440), m = amplitude(880)
            let maxStep = zip(samples.dropFirst(), samples).map { abs($0 - $1) }.max() ?? 0
            let passed = samples.count > 4800 && maxStep < 0.08 && ((receivePage && sendPage) ? p > 0.03 : p < 0.02) && ((receiveMic && sendMic) ? m > 0.03 : m < 0.02)
            NSLog("NativeAudio %@ mode=%@ samples=%ld page=%.4f mic=%.4f maxStep=%.4f", passed ? "PASS" : "FAIL", name, samples.count, p, m, maxStep)
        }
    }
}
#endif
