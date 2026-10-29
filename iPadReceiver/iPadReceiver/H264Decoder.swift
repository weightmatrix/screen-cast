import Foundation
import UIKit
import Combine
import AVFoundation
import CoreMedia
import VideoToolbox

final class ImageDecoder: ObservableObject {
    @Published var diagText = "等待画面"

    var onImageUpdate: ((UIImage?) -> Void)?
    var onFrameAvailable: (() -> Void)?
    var onNeedsKeyFrame: (() -> Void)?

    private let perf = StreamPerformance("ipad.decode")
    private var h264FormatDesc: CMVideoFormatDescription?
    private var h264ConfigData: Data?
    private var decompressionSession: VTDecompressionSession?
    private var h264Pts = CMTime(value: 0, timescale: 600)
    private let decodeQueue = DispatchQueue(label: "com.witten.touping.decode", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var pendingDecodeCount = 0
    private var waitingForKeyframe = false
    private var maxPendingDecodeFrames = 3
    private var displayFrameStep = 1
    private let frameLock = NSLock()
    private var latestFrame: CIImage?
    private var frameRevision: UInt64 = 0
    private var droppedFrameCount = 0
    private var debugFrameLogCounter = 0
    private var enqueueCount = 0

    init() {
        updateThermalState()
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateThermalState()
        }
    }

    var currentFrame: CIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func frameForDisplay(after revision: UInt64?) -> (image: CIImage?, revision: UInt64)? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard revision != frameRevision else { return nil }
        return (latestFrame, frameRevision)
    }

    func setH264Serialized(_ payload: Data) {
        guard payload.count >= 5 else { return }
        let fdLen = Int(payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        let fdData = payload.copySlice(4, fdLen)
        guard !fdData.isEmpty else { return }
        if fdData == h264ConfigData, decompressionSession != nil {
            return
        }
        guard let desc = StreamFormat.deserialize(fdData) else {
            DispatchQueue.main.async { [weak self] in self?.diagText = "FD反序列化失败" }
            return
        }
        decodeQueue.sync {}
        if let s = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            decompressionSession = nil
        }
        let status = createDecompressionSession(desc)
        if status != noErr {
            DispatchQueue.main.async { [weak self] in self?.diagText = "VTDS:\(status)" }
            return
        }
        h264FormatDesc = desc
        h264ConfigData = fdData
        h264Pts = CMTime(value: 0, timescale: 600)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        ConnectionDiag.shared.log("黑屏·config fd=\(fdData.count) dims=\(dims.width)x\(dims.height)")
        DispatchQueue.main.async { [weak self] in
            self?.diagText = "H264 OK \(dims.width)x\(dims.height)"
        }
    }

    func decodeFrame(_ data: Data) {
        decodeH264(data)
    }

    private func decodeH264(_ annexBData: Data) {
        guard let desc = h264FormatDesc, let session = decompressionSession else { return }
        let isKeyframe = Self.isKeyframeAnnexB(annexBData)
        let avcc = Self.annexBToAVCC(annexBData)
        guard !avcc.isEmpty else {
            ConnectionDiag.shared.log("黑屏·annexBToAVCC empty")
            return
        }

        pendingLock.lock()
        if !isKeyframe, waitingForKeyframe || pendingDecodeCount >= maxPendingDecodeFrames {
            perf.record("dropBusy")
            waitingForKeyframe = true
            droppedFrameCount += 1
            let dropped = droppedFrameCount
            pendingLock.unlock()
            onNeedsKeyFrame?()
            if dropped % 60 == 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.diagText = "解码繁忙，已丢 \(dropped) 帧"
                }
            }
            return
        }
        if isKeyframe {
            waitingForKeyframe = false
        }
        pendingDecodeCount += 1
        pendingLock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.feedH264(data: avcc, formatDesc: desc, session: session)
        }
    }

    static func isKeyframeAnnexB(_ data: Data) -> Bool {
        let n = data.count
        var i = 0
        while i + 3 <= n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if i + 3 < n, (data[i + 3] & 0x1F) == 5 { return true }
            }
            if i + 4 <= n, data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                if i + 4 < n, (data[i + 4] & 0x1F) == 5 { return true }
            }
            i += 1
        }
        return false
    }

    static func annexBToAVCC(_ data: Data) -> Data {
        let n = data.count
        guard n > 4 else { return Data() }
        var output = Data(capacity: n + 32)

        func nalTypeAt(_ i: Int) -> Int { Int(data[i]) & 0x1F }

        func isStartCode(at j: Int) -> Int {
            if j + 4 <= n, data[j] == 0, data[j + 1] == 0, data[j + 2] == 0, data[j + 3] == 1 { return 4 }
            if j + 3 <= n, data[j] == 0, data[j + 1] == 0, data[j + 2] == 1 { return 3 }
            return 0
        }

        func nextStartCode(from i: Int) -> Int? {
            var j = i
            while j + 3 <= n {
                if isStartCode(at: j) > 0 { return j }
                j += 1
            }
            return nil
        }

        var start = nextStartCode(from: 0) ?? 0
        while let end = nextStartCode(from: start + 4) {
            let nalStart = start + isStartCode(at: start)
            if end > nalStart {
                let nalLength = end - nalStart
                var len = UInt32(nalLength).bigEndian
                withUnsafeBytes(of: &len) { output.append(contentsOf: $0) }
                output.append(data[nalStart..<end])
            }
            start = end
        }
        let lastNalStart = start + isStartCode(at: start)
        if lastNalStart < n {
            let nalLength = n - lastNalStart
            var len = UInt32(nalLength).bigEndian
            withUnsafeBytes(of: &len) { output.append(contentsOf: $0) }
            output.append(data[lastNalStart..<n])
        }
        return output
    }

    private func feedH264(data: Data, formatDesc: CMVideoFormatDescription, session: VTDecompressionSession) {
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &blockBuffer)
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else {
            ConnectionDiag.shared.log("黑屏·CMBlockBuffer失败 \(bbStatus)")
            finishPendingDecode()
            return
        }

        _ = data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!,
                blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: h264Pts, decodeTimeStamp: h264Pts)
        var sizes = [data.count]
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else {
            ConnectionDiag.shared.log("黑屏·CMSampleBuffer失败")
            finishPendingDecode()
            return
        }

        h264Pts = CMTimeAdd(h264Pts, CMTime(value: 1, timescale: 60))

        let decodeStart = ProcessInfo.processInfo.systemUptime
        perf.record("submitted", bytes: data.count)
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
            flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.perf.record("decoded", milliseconds: (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000)
                self.presentDecodedFrame(imageBuffer)
            } else if status != noErr {
                self.pendingLock.lock()
                self.waitingForKeyframe = true
                self.pendingLock.unlock()
                ConnectionDiag.shared.log("黑屏·解码err:\(status)")
                DispatchQueue.main.async { [weak self] in self?.diagText = "解码err:\(status)" }
            }
            self.finishPendingDecode()
        }
    }

    private func presentDecodedFrame(_ imageBuffer: CVPixelBuffer) {
        debugFrameLogCounter += 1
        let shouldLog = debugFrameLogCounter <= 3 || debugFrameLogCounter % 30 == 0
        if shouldLog {
            ConnectionDiag.shared.log("黑屏·decoded#\(debugFrameLogCounter) buffer=\(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer)) luma=\(sampleLuma(imageBuffer))")
        }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let size = ciImage.extent.size
        frameLock.lock()
        enqueueCount += 1
        let frameNumber = enqueueCount
        if frameNumber == 1 || frameNumber % displayFrameStep == 0 {
            latestFrame = ciImage
            frameRevision &+= 1
        }
        frameLock.unlock()
        if frameNumber == 1 || frameNumber % 60 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.diagText = "H264 帧:\(frameNumber) \(Int(size.width))x\(Int(size.height))"
            }
        }
    }

    private func sampleLuma(_ imageBuffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return "noY" }
        let width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        guard width > 0, height > 0, bytesPerRow >= width else { return "badY" }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, width / 16)
        let stepY = max(1, height / 16)
        var sum = 0
        var count = 0
        var minV = 255
        var maxV = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let value = Int(ptr[y * bytesPerRow + x])
                sum += value
                count += 1
                minV = min(minV, value)
                maxV = max(maxV, value)
                x += stepX
            }
            y += stepY
        }
        guard count > 0 else { return "noSample" }
        return "avg=\(sum / count) min=\(minV) max=\(maxV)"
    }

    private func finishPendingDecode() {
        pendingLock.lock()
        pendingDecodeCount = max(0, pendingDecodeCount - 1)
        pendingLock.unlock()
    }

    private func updateThermalState() {
        var pendingLimit = 3
        var displayStep = 1
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            pendingLimit = 1
            displayStep = 6
            ConnectionDiag.shared.log("热状态 critical")
        case .serious:
            pendingLimit = 2
            displayStep = 2
            ConnectionDiag.shared.log("热状态 serious")
        case .fair:
            pendingLimit = 3
            displayStep = 1
        case .nominal:
            pendingLimit = 3
            displayStep = 1
        @unknown default:
            pendingLimit = 3
            displayStep = 1
        }
        pendingLock.lock()
        maxPendingDecodeFrames = pendingLimit
        pendingLock.unlock()
        frameLock.lock()
        displayFrameStep = displayStep
        frameLock.unlock()
    }

    private func createDecompressionSession(_ desc: CMVideoFormatDescription) -> OSStatus {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, let session else { return status }
        decompressionSession = session
        return noErr
    }


    func reset() {
        decodeQueue.sync {}
        if let s = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            decompressionSession = nil
        }
        h264FormatDesc = nil
        h264ConfigData = nil
        enqueueCount = 0
        debugFrameLogCounter = 0
        h264Pts = CMTime(value: 0, timescale: 600)
        pendingLock.lock()
        pendingDecodeCount = 0
        waitingForKeyframe = false
        droppedFrameCount = 0
        pendingLock.unlock()
        frameLock.lock()
        latestFrame = nil
        frameRevision &+= 1
        enqueueCount = 0
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onImageUpdate?(nil)
            self?.diagText = "等待画面"
        }
    }
}
