import Foundation
import Combine
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import CoreImage
import VideoToolbox
import AppKit

final class ScreenStreamer: NSObject, ObservableObject {
    struct AppGroup: Identifiable {
        var id = UUID()
        let application: SCRunningApplication
        let windows: [SCWindow]
        var icon: NSImage? {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return nil
        }
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case streaming(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var appGroups: [AppGroup] = []
    @Published var displays: [SCDisplay] = []
    @Published var currentFPS: Double = 0
    @Published var useH264: Bool { didSet { UserDefaults.standard.set(useH264, forKey: "useH264") } }
    @Published var h264Bitrate: Int {
        didSet {
            UserDefaults.standard.set(h264Bitrate, forKey: "h264Bitrate")
            applyBitrate()
        }
    }

    override init() {
        let ud = UserDefaults.standard
        self.useH264 = ud.object(forKey: "useH264") as? Bool ?? false
        self.h264Bitrate = ud.object(forKey: "h264Bitrate") as? Int ?? 30_000_000
        super.init()
    }

    private var stream: SCStream?
    private let workQueue = DispatchQueue(label: "ScreenStreamer.work", qos: .userInitiated)
    private var framesThisSecond = 0
    private var fpsTimerStart = Date()
    private weak var server: CastingServer?

    private var compressionSession: VTCompressionSession?
    private var needKeyFrame = true
    private var ptsCounter: CMTimeValue = 0

    func bind(server: CastingServer) {
        self.server = server
        server.onNewClient = { [weak self] in
            self?.needKeyFrame = true
        }
    }

    func loadShareableContent() {
        phase = .preparing
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.phase = .failed(error.localizedDescription)
                    return
                }
                guard let content else { self.phase = .failed("无法获取屏幕内容"); return }
                var grouped: [SCRunningApplication: [SCWindow]] = [:]
                for window in content.windows {
                    if let app = window.owningApplication { grouped[app, default: []].append(window) }
                }
                self.appGroups = grouped.map { AppGroup(application: $0.key, windows: $0.value) }
                    .sorted { $0.application.applicationName.localizedStandardCompare($1.application.applicationName) == .orderedAscending }
                self.displays = content.displays
                if self.appGroups.isEmpty {
                    self.phase = .failed("没有找到可投屏的窗口")
                } else {
                    self.phase = .idle
                }
            }
        }
    }

    func start(filter: SCContentFilter, name: String) {
        stopStream()
        let nativeW = filter.contentRect.width * CGFloat(filter.pointPixelScale)
        let nativeH = filter.contentRect.height * CGFloat(filter.pointPixelScale)
        let padRes = server?.remoteScreenSize
        let targetW: Int
        let targetH: Int
        if let padRes {
            let padAspect = CGFloat(padRes.width) / CGFloat(padRes.height)
            let srcAspect = nativeW / nativeH
            if srcAspect > padAspect {
                targetW = padRes.width
                targetH = max(1, Int(CGFloat(padRes.width) / srcAspect))
            } else {
                targetH = padRes.height
                targetW = max(1, Int(CGFloat(padRes.height) * srcAspect))
            }
        } else {
            targetW = Int(nativeW)
            targetH = Int(nativeH)
        }

        let config = SCStreamConfiguration()
        config.width = targetW
        config.height = targetH
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: workQueue)
            try newStream.startCapture()
            stream = newStream
            if useH264 { compressionSession = nil; needKeyFrame = true; ptsCounter = 0 }
            framesThisSecond = 0; fpsTimerStart = Date()
            phase = .streaming(name)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() { stopStream(); phase = .idle }

    private func stopStream() {
        stream?.stopCapture(); stream = nil
        if let s = compressionSession { VTCompressionSessionInvalidate(s); compressionSession = nil }
    }

    private func applyBitrate() {
        guard let s = compressionSession else { return }
        let v = h264Bitrate as CFNumber
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: v)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [h264Bitrate * 3 / 8, 1] as CFArray)
    }

    private func reportFPS() {
        DispatchQueue.main.async {
            self.framesThisSecond += 1
            let now = Date()
            let elapsed = now.timeIntervalSince(self.fpsTimerStart)
            if elapsed >= 1 { self.currentFPS = Double(self.framesThisSecond) / elapsed; self.framesThisSecond = 0; self.fpsTimerStart = now }
        }
    }
}

extension ScreenStreamer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let ib = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if useH264 { encodeH264(ib) } else { encodeJPEG(ib) }
    }
}

extension ScreenStreamer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { if case .streaming = self.phase { self.phase = .failed(error.localizedDescription) } }
    }
}

private let ciCtx = CIContext(options: [.workingColorSpace: NSNull(), .highQualityDownsample: false])
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

extension ScreenStreamer {
    private func encodeJPEG(_ pixelBuffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let d = ciCtx.jpegRepresentation(of: ci, colorSpace: srgb, options: [q: 0.92]), d.count >= 64 else { return }
        server?.sendFrame(d, isKey: true)
        reportFPS()
    }
}

extension ScreenStreamer {
    private func createH264Session(_ w: Int, _ h: Int) -> Bool {
        if compressionSession != nil { return true }
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return false }
        let p: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AverageBitRate: h264Bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [h264Bitrate * 3 / 8, 1] as [Any],
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 120,
        ]
        VTSessionSetProperties(s, propertyDictionary: p as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(s)
        compressionSession = s
        return true
    }

    private func encodeH264(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard createH264Session(w, h), let ses = compressionSession else { return }
        var fp: CFDictionary?
        if needKeyFrame { fp = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary }
        ptsCounter += 600 / 60
        let pts = CMTime(value: ptsCounter, timescale: 600)
        VTCompressionSessionEncodeFrame(ses, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: fp, infoFlagsOut: nil) { [weak self] st, _, sb in
            guard let self, st == noErr, let sb else { return }
            self.workQueue.async { self.handleEncoded(sb) }
        }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard let srv = server, let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        guard let (data, isKey) = h264ToAnnexB(sb) else { return }
        if isKey, let fd = serializeFormatDescription(fmt) {
            srv.sendConfig(codec: 3, parameterSets: [fd])
            needKeyFrame = false
        }
        srv.sendFrame(data, isKey: isKey)
        reportFPS()
    }

    private func h264ToAnnexB(_ sb: CMSampleBuffer) -> (Data, Bool)? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let len = CMBlockBufferGetDataLength(bb)
        var raw = [UInt8](repeating: 0, count: len)
        raw.withUnsafeMutableBytes { p in if let b = p.baseAddress { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: b) } }
        var out = Data(capacity: len + 64)
        var isKey = false; var off = 0
        while off + 4 <= len {
            var sz = 0
            for i in 0..<4 { sz = sz << 8 | Int(raw[off + i]) }
            off += 4
            guard off + sz <= len, sz > 0 else { break }
            if raw[off] & 0x1F == 5 { isKey = true }
            out.append(contentsOf: [0,0,0,1])
            out.append(contentsOf: raw[off..<off+sz])
            off += sz
        }
        return out.isEmpty ? nil : (out, isKey)
    }

    private func serializeFormatDescription(_ fmt: CMFormatDescription) -> Data? {
        var bb: CMBlockBuffer?
        guard CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(allocator: nil, videoFormatDescription: fmt, stringEncoding: 0, flavor: .isoFamily, blockBufferOut: &bb) == noErr, let bb else { return nil }
        let len = CMBlockBufferGetDataLength(bb)
        var d = Data(count: len)
        d.withUnsafeMutableBytes { p in CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
        return d
    }
}
