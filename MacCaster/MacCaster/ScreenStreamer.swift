import Foundation
import Combine
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import CoreImage
import VideoToolbox
import AppKit

final class ScreenStreamer: NSObject, ObservableObject {
    let annotation = AnnotationEngine()
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

    @Published var appGroups: [AppGroup] = []
    @Published var displays: [SCDisplay] = []
    @Published var sessions: [StreamSession] = []
    @Published var defaultUseH264: Bool { didSet { UserDefaults.standard.set(defaultUseH264, forKey: "defaultUseH264") } }
    @Published var defaultBitrate: Int { didSet { UserDefaults.standard.set(defaultBitrate, forKey: "defaultBitrate") } }
    @Published var defaultFPS: Int { didSet { UserDefaults.standard.set(defaultFPS, forKey: "defaultFPS") } }
    @Published var lastCode: String { didSet { UserDefaults.standard.set(lastCode, forKey: "lastCode") } }

    private var usageCounts: [String: Int] = [:]

    private var nextPort: UInt16 = 8318

    override init() {
        let u = UserDefaults.standard
        self.defaultUseH264 = u.object(forKey: "defaultUseH264") as? Bool ?? false
        self.defaultBitrate = u.object(forKey: "defaultBitrate") as? Int ?? 30_000_000
        self.defaultFPS = u.object(forKey: "defaultFPS") as? Int ?? 60
        self.lastCode = u.object(forKey: "lastCode") as? String ?? "1234"
        self.usageCounts = u.object(forKey: "appUsageCounts") as? [String: Int] ?? [:]
        super.init()
        DiscoveryBroadcaster.shared.start()
    }

    private func recordUsage(for app: SCRunningApplication) {
        let bundle = app.bundleIdentifier
        guard !bundle.isEmpty else { return }
        usageCounts[bundle, default: 0] += 1
        UserDefaults.standard.set(usageCounts, forKey: "appUsageCounts")
    }

    func recordUsage(bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return }
        usageCounts[bundleIdentifier, default: 0] += 1
        UserDefaults.standard.set(usageCounts, forKey: "appUsageCounts")
        sortAppGroups()
    }

    private func sortAppGroups() {
        appGroups.sort { a, b in
            let ca = usageCounts[a.application.bundleIdentifier ?? ""] ?? 0
            let cb = usageCounts[b.application.bundleIdentifier ?? ""] ?? 0
            if ca != cb { return ca > cb }
            return a.application.applicationName.localizedStandardCompare(b.application.applicationName) == .orderedAscending
        }
    }

    func loadShareableContent() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, let content else { return }
                var grouped: [SCRunningApplication: [SCWindow]] = [:]
                for window in content.windows {
                    if let app = window.owningApplication { grouped[app, default: []].append(window) }
                }
                self.appGroups = grouped.map { AppGroup(application: $0.key, windows: $0.value) }
                self.displays = content.displays
                self.sortAppGroups()
            }
        }
    }

    func addSession(filter: SCContentFilter, name: String, useH264: Bool, bitrate: Int, fps: Int, showsCursor: Bool, screenOrigin: CGPoint = .zero, code: String = "") {
        let port = nextPort
        nextPort += 1
        let finalCode = uniqueCode(for: code)
        if #available(macOS 15.2, *) {
            for app in filter.includedApplications { recordUsage(for: app) }
        }
        sortAppGroups()
        let session = StreamSession(port: port, filter: filter, name: name, useH264: useH264, bitrate: bitrate, fps: fps, showsCursor: showsCursor, annotationEngine: annotation, screenOrigin: screenOrigin, code: finalCode)
        session.start()
        sessions.append(session)
        refreshBroadcast()
    }

    private func uniqueCode(for requested: String) -> String {
        let base = requested.isEmpty ? "1234" : requested
        let used = Set(sessions.map { $0.code })
        if !used.contains(base) { return base }
        var n = Int(base) ?? 1234
        var candidate = base
        while used.contains(candidate) {
            n += 1
            candidate = String(format: "%04d", n % 10000)
        }
        return candidate
    }

    func canChangeCode(_ session: StreamSession, to newCode: String) -> Bool {
        let used = Set(sessions.filter { $0.id != session.id }.map { $0.code })
        return !used.contains(newCode)
    }

    func removeSession(_ session: StreamSession) {
        session.stop()
        sessions.removeAll { $0.id == session.id }
        refreshBroadcast()
    }

    func refreshBroadcast() {
        DiscoveryBroadcaster.shared.update(entries: sessions.map { ($0.code, $0.port) })
    }
}

final class StreamSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let port: UInt16
    @Published var contentName: String
    @Published var code: String

    @Published var phase: Phase = .idle
    @Published var currentFPS: Double = 0
    @Published var clientCount: Int = 0
    @Published var useH264: Bool
    @Published var bitrate: Int
    @Published var showsCursor: Bool
    @Published var encWidth: Int = 0
    @Published var encHeight: Int = 0
    private var screenOrigin: CGPoint = .zero

    enum Phase: Equatable {
        case idle
        case streaming
        case failed(String)
    }

    private let server: CastingServer
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private let workQueue = DispatchQueue(label: "stream.\(UUID().uuidString.prefix(8))", qos: .userInitiated)
    private var needKeyFrame = true
    private var ptsCounter: CMTimeValue = 0
    private var framesThisSecond = 0
    private var fpsTimerStart = Date()
    private let filter: SCContentFilter
    private let targetFPS: Int
    private var encodeWidth: Int = 0
    private var encodeHeight: Int = 0
    let annotationEngine: AnnotationEngine

    init(port: UInt16, filter: SCContentFilter, name: String, useH264: Bool, bitrate: Int, fps: Int, showsCursor: Bool, annotationEngine: AnnotationEngine, screenOrigin: CGPoint = .zero, code: String = "1234") {
        self.port = port
        self.filter = filter
        self.contentName = name
        self.useH264 = useH264
        self.bitrate = bitrate
        self.targetFPS = fps
        self.showsCursor = showsCursor
        self.annotationEngine = annotationEngine
        self.screenOrigin = screenOrigin
        self.code = code
        self.server = CastingServer(port: port)
        super.init()
    }

    func start() {
        guard stream == nil else { return }
        server.start()
        server.onClientCountChanged = { [weak self] count in
            DispatchQueue.main.async { self?.clientCount = count }
        }
        restartCapture(with: filter)
    }

    func stop() {
        stream?.stopCapture()
        stream = nil
        if let s = compressionSession { VTCompressionSessionInvalidate(s); compressionSession = nil }
        server.stop()
        phase = .idle
    }

    func refresh() {
        stream?.stopCapture()
        stream = nil
        if let s = compressionSession { VTCompressionSessionInvalidate(s); compressionSession = nil }
        compressionSession = nil
        needKeyFrame = true
        ptsCounter = 0
        restartCapture(with: filter)
    }

    func toggleAnnotation() {
        if annotationEngine.isActive {
            DiagLog.log("Stream", "toggleAnnotation: off (port \(port))")
            annotationEngine.hideToolbar()
        } else {
            DiagLog.log("Stream", "toggleAnnotation: on (port \(port))")
            annotationEngine.showToolbar()
        }
    }

    func changeFilter(_ newFilter: SCContentFilter, name: String) {
        stop()
        contentName = name
        let f = newFilter
        if #available(macOS 15.2, *) {
            for app in f.includedApplications { recordUsage(for: app) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.restartCapture(with: f)
        }
    }

    private func restartCapture(with f: SCContentFilter) {
        let nativeW = f.contentRect.width * CGFloat(f.pointPixelScale)
        let nativeH = f.contentRect.height * CGFloat(f.pointPixelScale)
        let padRes = server.maxRemoteResolution
        let targetW: Int, targetH: Int
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(targetFPS))
        config.queueDepth = 4
        config.showsCursor = showsCursor
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        encWidth = targetW
        encHeight = targetH
        server.start()
        do {
            let s = SCStream(filter: f, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: workQueue)
            s.startCapture()
            stream = s
            compressionSession = nil
            needKeyFrame = true
            ptsCounter = 0
            framesThisSecond = 0
            fpsTimerStart = Date()
            phase = .streaming
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func applyBitrate() {
        guard let s = compressionSession else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate * 3 / 8, 1] as CFArray)
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

extension StreamSession: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let ib = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if useH264 { encodeH264(ib) } else { encodeJPEG(ib) }
    }
}

extension StreamSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { if case .streaming = self.phase { self.phase = .failed(error.localizedDescription) } }
    }
}

private let ciCtx = CIContext(options: [.workingColorSpace: NSNull(), .highQualityDownsample: false])
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

extension StreamSession {
    private func encodeJPEG(_ pixelBuffer: CVPixelBuffer) {
        drawAnnotations(on: pixelBuffer)
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let d = ciCtx.jpegRepresentation(of: ci, colorSpace: srgb, options: [q: 0.92]), d.count >= 64 else { return }
        server.sendFrame(d)
        reportFPS()
    }

    private func drawAnnotations(on pixelBuffer: CVPixelBuffer) {
        guard annotationEngine.isActive else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }
        let cr = filter.contentRect
        let ps = CGFloat(filter.pointPixelScale)
        let srcW = cr.width * ps
        let srcH = cr.height * ps
        guard srcW > 0, srcH > 0 else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return }

        let scaleX = CGFloat(w) / srcW
        let scaleY = CGFloat(h) / srcH
        let offsetX = -(cr.origin.x * ps + screenOrigin.x) * scaleX
        let offsetY = -(cr.origin.y * ps + screenOrigin.y) * scaleY
        ctx.translateBy(x: offsetX, y: offsetY)
        ctx.scaleBy(x: scaleX, y: scaleY)

        annotationEngine.drawStrokes(in: ctx, rect: CGRect(x: 0, y: 0, width: srcW, height: srcH))
    }
}

extension StreamSession {
    private func ensureH264Session(_ w: Int, _ h: Int) -> Bool {
        if w != encodeWidth || h != encodeHeight {
            if let s = compressionSession { VTCompressionSessionInvalidate(s); compressionSession = nil }
            encodeWidth = w
            encodeHeight = h
            DispatchQueue.main.async { self.encWidth = w; self.encHeight = h }
        }
        if compressionSession != nil { return true }
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return false }
        let p: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate * 3 / 8, 1] as [Any],
            kVTCompressionPropertyKey_ExpectedFrameRate: targetFPS,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AllowOpenGOP: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(targetFPS / 2, 15),
        ]
        VTSessionSetProperties(s, propertyDictionary: p as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(s)
        compressionSession = s
        return true
    }

    private func encodeH264(_ pb: CVPixelBuffer) {
        drawAnnotations(on: pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard ensureH264Session(w, h), let ses = compressionSession else { return }
        var fp: CFDictionary?
        if needKeyFrame { fp = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary }
        ptsCounter += 600 / CMTimeValue(targetFPS)
        let pts = CMTime(value: ptsCounter, timescale: 600)
        VTCompressionSessionEncodeFrame(ses, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: fp, infoFlagsOut: nil) { [weak self] st, _, sb in
            guard let self, st == noErr, let sb else { return }
            self.workQueue.async { self.handleEncoded(sb) }
        }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        guard let (data, isKey) = h264ToAnnexB(sb) else { return }
        if isKey, let fd = serializeFormatDescription(fmt) {
            server.sendConfig(fd)
            needKeyFrame = false
        }
        server.sendFrame(data)
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
        d.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
        return d
    }
}
