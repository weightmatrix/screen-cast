import Foundation
import ReplayKit
import CoreImage
import VideoToolbox

/// Unchanged, supported ReplayKit buffers go straight to VideoToolbox.
/// Conversion remains available for rotation/scaling; at most two frames are in flight.
final class ReplayVideoEncoder {
    var onOutput: ((Data, Bool, Data?) -> Void)?
    var onFailure: ((String) -> Void)?
    var onResolution: ((String) -> Void)?
    #if DEBUG
    var onEncodedForVerification: ((CMSampleBuffer) -> Void)?
    #endif
    private let perf = StreamPerformance("ipad.captureEncode")
    private let queue = DispatchQueue(label: "broadcast.encoder", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var dimensions = CGSize.zero
    private var lastPTS = CMTime.invalid
    private var lastSourceDescription = ""
    private var needsKeyFrame = true
    private var pending = 0
    private var generation = 0
    private var paused = false
    private var directInputRejected = false
    private let bitrate: Int
    private var internetLimit: Int?
    private var effectiveBitrate: Int { min(bitrate, internetLimit ?? bitrate) }
    func setInternetBitrateLimit(_ limit: Int?) {
        queue.async {
            self.internetLimit = limit
            if limit == nil { self.framePacer.reset(upper: self.fps) }
            if let session = self.session {
                let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: self.effectiveBitrate as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: self.encodingFPS as CFNumber)
                PerformanceDisk.shared.write("ipad.adaptive applied=\(self.effectiveBitrate) status=\(status)")
            }
        }
    }
    private var framePacer = EncoderFramePacer()
    private var encodingFPS: Int { min(fps, framePacer.target) }
    private func observeFrame(drop: Bool) {
        let old = encodingFPS
        let next = framePacer.observe(drop: drop, now: ProcessInfo.processInfo.systemUptime, upper: fps, enabled: internetLimit != nil)
        if old != next, let session {
            let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: next as CFNumber)
            PerformanceDisk.shared.write("ipad.adaptiveFPS target=\(next) status=\(status)")
        }
    }
    private let fps: Int
    private let maximumDimension: Int

    init(bitrate: Int, fps: Int, maximumDimension: Int = 1600) {
        self.bitrate = BroadcastSettings.clampedBitrate(bitrate)
        self.fps = fps
        self.maximumDimension = BroadcastSettings.resolutionLimit(maximumDimension)
        PerformanceDisk.shared.write("ipad.encoder requestedLimit=\(self.maximumDimension) fps=\(fps) bitrate=\(self.bitrate)")
    }

    func requestKeyFrame() { queue.async { self.needsKeyFrame = true } }
    func setPaused(_ value: Bool) { queue.sync { paused = value; needsKeyFrame = true } }
    func stop() {
        queue.sync {
            generation += 1
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil; pool = nil; pending = 0
        }
    }

    func append(_ sample: CMSampleBuffer) {
        let arrived = ProcessInfo.processInfo.systemUptime
        queue.sync {
            perf.interval("captureInterval", at: arrived)
            perf.record("capture", milliseconds: (ProcessInfo.processInfo.systemUptime - arrived) * 1000)
            guard !paused else { return }
            guard pending < 2 else { perf.record("dropBusy"); return }
            guard let input = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric else { return }
            perf.interval("sourcePTSInterval", at: CMTimeGetSeconds(pts))
            if lastPTS.isNumeric, CMTimeCompare(pts, lastPTS) >= 0,
               CMTimeGetSeconds(CMTimeSubtract(pts, lastPTS)) < 0.95 / Double(encodingFPS) { perf.record("dropFPS"); return }
            let orientation = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.int32Value ?? 1
            var image = CIImage(cvPixelBuffer: input)
            image = image.oriented(forExifOrientation: orientation)
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return }
            let scale = maximumDimension == 0 ? 1 : min(1, CGFloat(maximumDimension) / max(extent.width, extent.height))
            let width = max(2, Int(extent.width * scale) / 2 * 2)
            let height = max(2, Int(extent.height * scale) / 2 * 2)
            let sourceDescription = "requestedLimit=\(maximumDimension) input=\(CVPixelBufferGetWidth(input))x\(CVPixelBufferGetHeight(input)) oriented=\(Int(extent.width))x\(Int(extent.height)) output=\(width)x\(height) pixelFormat=\(CVPixelBufferGetPixelFormatType(input))"
            if sourceDescription != lastSourceDescription {
                lastSourceDescription = sourceDescription
                PerformanceDisk.shared.write("ipad.resolution \(sourceDescription)")
                let mode = maximumDimension == 0 ? "原生采集" : "最长边 \(maximumDimension)"
                onResolution?("\(mode)：采集 \(Int(extent.width))×\(Int(extent.height)) → 输出 \(width)×\(height)")
            }
            if dimensions != CGSize(width: width, height: height) {
                guard configure(width: width, height: height) else { return }
            }
            guard let session else { return }
            let format = CVPixelBufferGetPixelFormatType(input)
            let supportedInput = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  kCVPixelFormatType_32BGRA].contains(format)
            let canUseInput = !directInputRejected && orientation == 1 && width == CVPixelBufferGetWidth(input)
                && height == CVPixelBufferGetHeight(input) && supportedInput
            let output: CVPixelBuffer
            if canUseInput {
                output = input
                perf.record("directInput")
            } else {
                guard let pool else { return }
                var converted: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                    [kCVPixelBufferPoolAllocationThresholdKey: 2] as CFDictionary, &converted)
                guard status == kCVReturnSuccess, let converted else { perf.record("dropPool"); return }
                image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
                let convertStart = ProcessInfo.processInfo.systemUptime
                context.render(image, to: converted)
                perf.record("convert", milliseconds: (ProcessInfo.processInfo.systemUptime - convertStart) * 1000)
                output = converted
            }
            let token = generation
            let options = needsKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            pending += 1
            let encodeStart = ProcessInfo.processInfo.systemUptime
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: output,
                presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: Int32(encodingFPS)),
                frameProperties: options, infoFlagsOut: nil) { [weak self] status, flags, encoded in
                guard let self else { return }
                let callbackAt = ProcessInfo.processInfo.systemUptime
                self.perf.interval("encodeCallbackInterval", at: callbackAt)
                self.perf.record("hardwareCallback", milliseconds: (callbackAt - encodeStart) * 1000)
                self.queue.async {
                    guard token == self.generation else { return }
                    self.perf.record("encodeCallbackQueueWait", milliseconds: (ProcessInfo.processInfo.systemUptime - callbackAt) * 1000)
                    self.pending = max(0, self.pending - 1)
                    // A successful callback may report an intentionally dropped frame under rate control.
                    // It is not an input-format rejection and must not force another expensive keyframe.
                    if status == noErr, flags.contains(.frameDropped) || encoded == nil {
                        self.perf.record("dropRateControl")
                        self.observeFrame(drop: true)
                        return
                    }
                    guard status == noErr, let encoded, let (data, key) = StreamFormat.annexB(encoded) else {
                        self.perf.record("encodeStatus_\(status)")
                        self.perf.record("encodeError")
                        if canUseInput { self.directInputRejected = true }
                        self.needsKeyFrame = true
                        return
                    }
                    #if DEBUG
                    self.onEncodedForVerification?(encoded)
                    #endif
                    self.observeFrame(drop: false)
                    let config = key ? CMSampleBufferGetFormatDescription(encoded).flatMap(StreamFormat.serialize) : nil
                    self.perf.record("encoded", milliseconds: (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000, bytes: data.count)
                    if key { self.perf.record("keyframe") }
                    self.onOutput?(data, key, config)
                }
            }
            if result == noErr { needsKeyFrame = false; lastPTS = pts }
            else {
                pending = max(0, pending - 1); needsKeyFrame = true
                perf.record("encodeSubmitError")
                if canUseInput {
                    directInputRejected = true
                    PerformanceDisk.shared.write("ipad.directInput fallback status=\(result)")
                }
            }
        }
    }

    #if DEBUG
    func configuredBitrateForVerification() -> Int? {
        queue.sync { () -> Int? in
            guard let session else { return nil }
            var value: Unmanaged<CFTypeRef>?
            let status = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                              allocator: nil, valueOut: &value)
            let bitrate = (value?.takeRetainedValue() as? NSNumber)?.intValue
            return status == noErr ? bitrate : nil
        }
    }
    #endif

    private func configure(width: Int, height: Int) -> Bool {
        generation += 1
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; pool = nil; pending = 0
        var encoder: VTCompressionSession?
        var lowLatency = true
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &encoder)
        if status != noErr {
            lowLatency = false
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        }
        guard status == noErr, let encoder else {
            onFailure?("无法启动视频编码：\(status)")
            return false
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 1,
            kVTCompressionPropertyKey_AverageBitRate: effectiveBitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: encodingFPS,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps
        ]
        let propertiesStatus = VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary)
        guard propertiesStatus == noErr else {
            VTCompressionSessionInvalidate(encoder)
            onFailure?("无法设置视频编码参数：\(propertiesStatus)")
            return false
        }
        PerformanceDisk.shared.write("ipad.rateControl lowLatency=\(lowLatency) target=\(bitrate) hardLimit=false")
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(encoder)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(encoder)
            onFailure?("无法准备视频编码：\(prepareStatus)")
            return false
        }
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            VTCompressionSessionInvalidate(encoder)
            onFailure?("无法分配投屏画面缓冲区")
            return false
        }
        session = encoder
        PerformanceDisk.shared.write("ipad.config size=\(width)x\(height) fps=\(fps) bitrate=\(bitrate) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        dimensions = CGSize(width: width, height: height)
        needsKeyFrame = true
        return true
    }
}
