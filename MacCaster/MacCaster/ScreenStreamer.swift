import Foundation
import Combine
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import CoreImage
import VideoToolbox
import AppKit
import SwiftUI
import ApplicationServices

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
    @Published var contentError: String?
    @Published var defaultBitrate: Int { didSet { UserDefaults.standard.set(defaultBitrate, forKey: "defaultBitrate") } }
    @Published var defaultFPS: Int { didSet { UserDefaults.standard.set(defaultFPS, forKey: "defaultFPS") } }
    @Published var lastCode: String { didSet { UserDefaults.standard.set(lastCode, forKey: "lastCode") } }

    private var usageCounts: [String: Int] = [:]

    private var nextPort: UInt16 = 8318
    private var didRequestCapturePermission = false

    override init() {
        let u = UserDefaults.standard
        self.defaultBitrate = u.object(forKey: "defaultBitrate") as? Int ?? 8_000_000
        self.defaultFPS = u.object(forKey: "defaultFPS") as? Int ?? 30
        let savedCode = u.string(forKey: "lastCode")
        self.lastCode = MatchingCode.isValid(savedCode) ? savedCode! : MatchingCode.generate()
        self.usageCounts = u.object(forKey: "appUsageCounts") as? [String: Int] ?? [:]
        super.init()
        u.set(lastCode, forKey: "lastCode")
        DiscoveryBroadcaster.shared.start()
        PermissionDiagnostics.logCurrent()
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
            let ca = usageCounts[a.application.bundleIdentifier] ?? 0
            let cb = usageCounts[b.application.bundleIdentifier] ?? 0
            if ca != cb { return ca > cb }
            return a.application.applicationName.localizedStandardCompare(b.application.applicationName) == .orderedAscending
        }
    }

    func loadShareableContent() {
        if !CGPreflightScreenCaptureAccess(), !didRequestCapturePermission {
            didRequestCapturePermission = true
            _ = CGRequestScreenCaptureAccess()
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let content else {
                    self.contentError = error?.localizedDescription ?? "无法读取屏幕内容，请检查屏幕录制权限。"
                    return
                }
                self.contentError = nil
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

    func addSession(filter: SCContentFilter, name: String, bitrate: Int, fps: Int, showsCursor: Bool, screenOrigin: CGPoint = .zero, code: String = "", touchEnabled: Bool = false) {
        let port = nextAvailablePort()
        let finalCode = uniqueCode(for: code)
        if #available(macOS 15.2, *) {
            for app in filter.includedApplications { recordUsage(for: app) }
        }
        sortAppGroups()
        let session = StreamSession(port: port, filter: filter, name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor, annotationEngine: annotation, screenOrigin: screenOrigin, code: finalCode)
        DiagLog.log("Stream", "addSession port=\(port) code=\(finalCode) name=\(name)")
        session.start()
        sessions.append(session)
        refreshBroadcast()
    }

    func replaceSession(_ session: StreamSession,
                        apps: [SCRunningApplication],
                        windows: [(String, SCWindow)],
                        displays: [(String, SCDisplay)]) {
        let bitrate = session.bitrate
        let fps = session.fps
        let showsCursor = session.showsCursor
        let touchEnabled = session.touchEnabled
        let internetEnabled = session.internetEnabled
        let internetMatchingEnabled = session.internetMatchingEnabled
        let tapAction = session.pencilTapAction
        let squeezeAction = session.pencilSqueezeAction
        let code = session.code
        let previousIDs = Set(sessions.map(\.id))
        removeSession(session)

        if !apps.isEmpty {
            let name = apps.map { $0.applicationName }.joined(separator: " + ")
            if let display = bestDisplay(for: apps) {
                for app in apps { recordUsage(bundleIdentifier: app.bundleIdentifier) }
                addSession(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                           name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor, code: code, touchEnabled: touchEnabled)
            }
        }
        for (name, window) in windows {
            if let app = window.owningApplication { recordUsage(bundleIdentifier: app.bundleIdentifier) }
            addSession(filter: SCContentFilter(desktopIndependentWindow: window),
                       name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor,
                       screenOrigin: window.frame.origin, code: code, touchEnabled: touchEnabled)
        }
        for (name, display) in displays {
            addSession(filter: SCContentFilter(display: display, excludingWindows: []),
                       name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor, code: code, touchEnabled: touchEnabled)
        }
        for replacement in sessions where !previousIDs.contains(replacement.id) {
            replacement.pencilTapAction = tapAction
            replacement.pencilSqueezeAction = squeezeAction
            replacement.internetMatchingEnabled = internetMatchingEnabled
            replacement.internetEnabled = internetEnabled
        }
    }

    private func nextAvailablePort() -> UInt16 {
        var port: UInt16 = 8318
        let used = Set(sessions.map { $0.port })
        while used.contains(port) {
            port &+= 1
        }
        nextPort = port &+ 1
        return port
    }

    private func uniqueCode(for requested: String) -> String {
        let used = Set(sessions.map { $0.code })
        var candidate = MatchingCode.isValid(requested) ? requested : MatchingCode.generate()
        while used.contains(candidate) { candidate = MatchingCode.generate() }
        return candidate
    }

    func canChangeCode(_ session: StreamSession, to newCode: String) -> Bool {
        let used = Set(sessions.filter { $0.id != session.id }.map { $0.code })
        return MatchingCode.isValid(newCode) && !used.contains(newCode)
    }

    func removeSession(_ session: StreamSession) {
        DiagLog.log("Stream", "removeSession port=\(session.port) code=\(session.code) name=\(session.contentName)")
        session.stop()
        sessions.removeAll { $0.id == session.id }
        refreshBroadcast()
    }

    func refreshBroadcast() {
        DiscoveryBroadcaster.shared.update(entries: sessions.map { ($0.code, $0.port) })
    }

    func bestDisplay(for applications: [SCRunningApplication]) -> SCDisplay? {
        let appIDs = Set(applications.map(\.processID))
        let windows = appGroups
            .filter { appIDs.contains($0.application.processID) }
            .flatMap(\.windows)
        return bestDisplay(for: windows)
    }

    private func bestDisplay(for windows: [SCWindow]) -> SCDisplay? {
        displays.max { lhs, rhs in
            let lhsArea = windows.reduce(CGFloat.zero) { $0 + $1.frame.intersection(lhs.frame).area }
            let rhsArea = windows.reduce(CGFloat.zero) { $0 + $1.frame.intersection(rhs.frame).area }
            return lhsArea < rhsArea
        } ?? displays.first
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

#if DEBUG
extension ScreenStreamer {
    @MainActor func verifyCasting() async {
        await verifyNativeCapture()
        await NativeRoutesVerification.run()
    }
}
#endif

final class StreamSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let port: UInt16
    @Published var contentName: String
    @Published var code: String {
        didSet { server.accessCode = code }
    }

    @Published var phase: Phase = .idle
    @Published var currentFPS: Double = 0
    @Published var clientCount: Int = 0
    @Published private(set) var bitrate: Int
    @Published var internetMatchingEnabled = true { didSet { server.setInternetMatchingEnabled(internetMatchingEnabled) } }
    @Published var internetEnabled = false { didSet { server.setInternetEnabled(internetEnabled) } }
    @Published var internetStatus = "广域网已关闭"
    @Published var showsCursor: Bool
    // Remote touch is suspended; retained implementation cannot be enabled.
    let touchEnabled = false
    @Published var pencilTapAction = "doubleClick"
    @Published var pencilSqueezeAction = "rightClick"
    private var remoteTouchOwner: ObjectIdentifier?
    private var remoteTouchPoint = CGPoint.zero
    @Published var encWidth: Int = 0
    @Published var encHeight: Int = 0
    var fps: Int { targetFPS }
    private var screenOrigin: CGPoint = .zero

    enum Phase: Equatable {
        case idle
        case starting
        case streaming
        case failed(String)
    }

    private let server: CastingServer
    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private let workQueue = DispatchQueue(label: "stream.\(UUID().uuidString.prefix(8))", qos: .userInitiated)
    private let perf = StreamPerformance("mac.captureEncode")
    private var pendingEncodedFrames = 0
    private var needKeyFrame = true
    private var ptsCounter: CMTimeValue = 0
    private var framesThisSecond = 0
    private var fpsTimerStart = Date()
    private var filter: SCContentFilter
    @Published private(set) var targetFPS: Int
    private var encodeWidth: Int = 0
    private var encodeHeight: Int = 0
    let annotationEngine: AnnotationEngine
    private var lastContentRect: CGRect = .zero
    private var rectWatchTimer: Timer?
    private var qualityWorkItem: DispatchWorkItem?
    private var qualityRequiresRestart = false
    private var restartWorkItem: DispatchWorkItem?
    private var encodedFrameLogCounter = 0
    private var lastSerializedFormatDescription: Data?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var encodingGeneration = 0
    private var activeCapture: SCStream?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast
    private var keepAliveTimer: DispatchSourceTimer?

    init(port: UInt16, filter: SCContentFilter, name: String, bitrate: Int, fps: Int, showsCursor: Bool, annotationEngine: AnnotationEngine, screenOrigin: CGPoint = .zero, code: String = MatchingCode.generate()) {
        self.port = port
        self.filter = filter
        self.contentName = name
        self.bitrate = bitrate
        self.targetFPS = fps
        self.showsCursor = showsCursor
        self.annotationEngine = annotationEngine
        self.screenOrigin = screenOrigin
        self.code = code
        self.server = CastingServer(port: port, accessCode: code)
        super.init()
        server.onInternetStatus = { [weak self] text in self?.internetStatus = text }
    }

    func start() {
        guard stream == nil else { return }
        DiagLog.log("Stream", "start port \(port)")
        server.configureNative(bitrate: bitrate, fps: targetFPS)
        server.start()
        server.onNativeFPS = { [weak self] fps in self?.currentFPS = fps }
        server.onClientCountChanged = { [weak self] count in
            DispatchQueue.main.async { self?.clientCount = count }
        }
        server.onRemoteResolutionChanged = { [weak self] in
            self?.handleRemoteResolutionChanged()
        }
        server.onNeedsKeyFrame = { [weak self] in
            guard let self else { return }
            self.workQueue.async { [weak self] in self?.needKeyFrame = true }
        }
        refresh()
    }

    func stop() {
        qualityWorkItem?.cancel()
        qualityWorkItem = nil
        releaseRemoteTouch()
        DiagLog.log("Stream", "stop port \(port)")
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stopRectWatch()
        enqueueCaptureChange(restart: false)
        server.stop()
        phase = .idle
    }

    private func startRectWatch() {
        lastContentRect = filter.contentRect
        rectWatchTimer?.invalidate()
        rectWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.phase == .streaming else { return }
            let current = self.filter.contentRect
            let dw = abs(current.width - self.lastContentRect.width)
            let dh = abs(current.height - self.lastContentRect.height)
            if dw > 8 || dh > 8 {
                DiagLog.log("Stream", "contentRect changed \(Int(self.lastContentRect.width))x\(Int(self.lastContentRect.height)) → \(Int(current.width))x\(Int(current.height))")
                self.lastContentRect = current
                self.scheduleRestart(after: 0.3)
            }
        }
        RunLoop.main.add(rectWatchTimer!, forMode: .common)
    }

    private func stopRectWatch() {
        rectWatchTimer?.invalidate()
        rectWatchTimer = nil
    }

    func refresh() {
        DiagLog.log("Stream", "refresh begin port=\(port) phase=\(phase) stream=\(stream != nil) compression=\(compressionSession != nil) serverRunning=\(server.isRunning) filterRect=\(filter.contentRect)")
        restartWorkItem?.cancel()
        stopRectWatch()
        enqueueCaptureChange(restart: true)
    }

    private func enqueueCaptureChange(restart: Bool) {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let previous = lifecycleTask
        if restart { phase = .starting }
        lifecycleTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.lifecycleGeneration else { return }
            if let old = self.stream {
                self.stream = nil
                try? await old.stopCapture()
            }
            self.workQueue.sync {
                self.activeCapture = nil
                self.keepAliveTimer?.cancel()
                self.keepAliveTimer = nil
                self.lastPixelBuffer = nil
                self.encodingGeneration += 1
                self.pendingEncodedFrames = 0
                if let encoder = self.compressionSession { VTCompressionSessionInvalidate(encoder) }
                self.compressionSession = nil
                self.lastSerializedFormatDescription = nil
                self.needKeyFrame = true
                self.ptsCounter = 0
            }
            guard restart, generation == self.lifecycleGeneration else { return }
            await self.restartCapture(with: self.filter, generation: generation)
        }
    }

    func toggleAnnotation() {
        if annotationEngine.isActive {
            DiagLog.log("Stream", "toggleAnnotation: off (port \(port))")
            annotationEngine.hideToolbar()
        } else {
            DiagLog.log("Stream", "toggleAnnotation: on (port \(port))")
            annotationEngine.showToolbar()
        }
        refresh() // Annotation CGContext needs BGRA; ordinary capture feeds NV12 directly.
    }

    func changeFilter(_ newFilter: SCContentFilter, name: String) {
        DiagLog.log("Stream", "changeFilter begin port \(port) -> \(name)")
        restartWorkItem?.cancel()
        // 服务器保持运行，接收端不断连；只重启捕获
        stopRectWatch()
        releaseRemoteTouch()
        contentName = name
        filter = newFilter
        lastContentRect = newFilter.contentRect
        refresh()
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.refresh()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleRemoteResolutionChanged() {
        // Per-peer RTP adaptation replaces global capture resizing.
    }

    @MainActor private func restartCapture(with f: SCContentFilter, generation: Int) async {
        DiagLog.log("Stream", "restartCapture port \(port) contentRect=\(f.contentRect)")
        let nativeW = f.contentRect.width * CGFloat(f.pointPixelScale)
        let nativeH = f.contentRect.height * CGFloat(f.pointPixelScale)
        guard nativeW > 0, nativeH > 0 else {
            let error = "contentRect invalid \(f.contentRect)"
            phase = .failed(error)
            DiagLog.log("Stream", "restartCapture invalid port \(port): \(error)")
            return
        }
        // Receiver size must not shrink the shared capture for other peers.
        let targetW = Int(nativeW), targetH = Int(nativeH)
        let config = SCStreamConfiguration()
        // Preserve source detail without enlarging a small window to iPad resolution.
        let scale = min(1, nativeW / Double(targetW), nativeH / Double(targetH))
        config.width = max(2, Int(Double(targetW) * scale) / 2 * 2)
        config.height = max(2, Int(Double(targetH) * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(targetFPS))
        config.queueDepth = 3
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = showsCursor
        config.capturesAudio = false
        config.pixelFormat = annotationEngine.isActive ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        encWidth = config.width
        encHeight = config.height
        DiagLog.log("Stream", "restartCapture target \(targetW)x\(targetH) fps=\(targetFPS) port=\(port)")
        server.configureNative(bitrate: bitrate, fps: targetFPS)
        server.start()
        do {
            let s = SCStream(filter: f, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: workQueue)
            stream = s
            workQueue.sync { self.activeCapture = s }
            try await s.startCapture()
            guard generation == lifecycleGeneration else { return }
            DiagLog.log("Stream", "restartCapture started port=\(port) target=\(targetW)x\(targetH)")
            stream = s
            framesThisSecond = 0
            fpsTimerStart = Date()
            phase = .streaming
            startRectWatch()
            encodedFrameLogCounter = 0
            workQueue.sync { self.startKeepAlive() }
        } catch {
            guard generation == lifecycleGeneration else { return }
            phase = .failed(error.localizedDescription)
            DiagLog.log("Stream", "restartCapture failed port \(port): \(error.localizedDescription)")
        }
    }

    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastCaptureAt) >= 1,
                  let buffer = self.lastPixelBuffer else { return }
            self.encodeH264(buffer)
        }
        keepAliveTimer = timer
        timer.resume()
    }

    /// Per-stream settings; existing TCP connections survive a capture restart.
    func updateQuality(bitrate newBitrate: Int? = nil, fps newFPS: Int? = nil) {
        if let newBitrate { bitrate = min(100_000_000, max(8_000_000, newBitrate)) }
        if let newFPS, [30, 60].contains(newFPS), newFPS != targetFPS {
            targetFPS = newFPS
            qualityRequiresRestart = true
        }
        qualityWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.qualityWorkItem = nil
            self.server.configureNative(bitrate: self.bitrate, fps: self.targetFPS)
            DiagLog.log("Quality", "apply port=\(self.port) bitrate=\(self.bitrate) fps=\(self.targetFPS)")
            if self.qualityRequiresRestart {
                self.qualityRequiresRestart = false
                self.refresh()
            }
        }
        qualityWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func reportFPS() {
        DispatchQueue.main.async {
            self.framesThisSecond += 1
            let now = Date()
            let elapsed = now.timeIntervalSince(self.fpsTimerStart)
            if elapsed >= 1 {
                let fps = Double(self.framesThisSecond) / elapsed
                if fps <= 0.01 || self.currentFPS <= 0.01 {
                    DiagLog.log("Stream", "reportFPS fps=\(String(format: "%.2f", fps)) frames=\(self.framesThisSecond) port=\(self.port)")
                }
                self.currentFPS = fps
                self.framesThisSecond = 0
                self.fpsTimerStart = now
            }
        }
    }
}

extension StreamSession: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === activeCapture, type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let ib = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = ib
        lastCaptureAt = Date()
        encodeH264(ib)
    }
}

extension StreamSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagLog.log("Stream", "capture didStopWithError port \(port): \(error.localizedDescription)")
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.phase = .failed(error.localizedDescription)
            self.workQueue.async {
                self.keepAliveTimer?.cancel()
                self.keepAliveTimer = nil
            }
        }
    }
}

extension StreamSession {
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
    private func encodeH264(_ pb: CVPixelBuffer) {
        drawAnnotations(on: pb)
        server.nativeSource.append(pb)
    }
}

// Input is accepted only for an authenticated connection and an enabled stream.
extension StreamSession {
    func requestTouchPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func releaseRemoteTouch() {
        if remoteTouchOwner != nil {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: remoteTouchPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        remoteTouchOwner = nil
    }

    private func handleRemoteTouch(_ event: [String: Any], owner: ObjectIdentifier) {
        guard touchEnabled, phase == .streaming, AXIsProcessTrusted(),
              let action = event["action"] as? String else { return }
        if action == "cancel" { if remoteTouchOwner == owner { releaseRemoteTouch() }; return }
        guard let x = event["x"] as? Double, let y = event["y"] as? Double,
              x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
        var rect = filter.contentRect
        if #available(macOS 15.2, *), filter.style == .window, let window = filter.includedWindows.first { rect = window.frame }
        guard rect.width > 0, rect.height > 0 else { return }
        let point = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        guard remoteTouchOwner == nil || remoteTouchOwner == owner else { return }
        func post(_ type: CGEventType, button: CGMouseButton = .left, clicks: Int64 = 1) {
            guard let mouse = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
            mouse.setIntegerValueField(.mouseEventClickState, value: clicks)
            if let pressure = event["pressure"] as? Double, pressure.isFinite {
                mouse.setDoubleValueField(.mouseEventPressure, value: min(1, max(0, pressure)))
            }
            mouse.post(tap: .cghidEventTap)
        }
        switch action {
        case "down":
            guard remoteTouchOwner == nil else { return }
            remoteTouchOwner = owner; remoteTouchPoint = point; post(.leftMouseDown)
        case "move":
            guard remoteTouchOwner == owner else { return }
            remoteTouchPoint = point; post(.leftMouseDragged)
        case "up":
            guard remoteTouchOwner == owner else { return }
            remoteTouchPoint = point; post(.leftMouseUp); remoteTouchOwner = nil
        case "pencilDoubleTap", "pencilSqueeze":
            guard remoteTouchOwner == nil else { return }
            if action == "pencilSqueeze", event["phase"] as? String != "ended" { return }
            let mapping = action == "pencilDoubleTap" ? pencilTapAction : pencilSqueezeAction
            DiagLog.log("Touch", "\(action) -> \(mapping)")
            if mapping == "rightClick" { post(.rightMouseDown, button: .right); post(.rightMouseUp, button: .right) }
            if mapping == "doubleClick" {
                post(.leftMouseDown); post(.leftMouseUp)
                post(.leftMouseDown, clicks: 2); post(.leftMouseUp, clicks: 2)
            }
        default: break
        }
    }
}

#if DEBUG
extension ScreenStreamer {
    @MainActor func verifyNativeCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let publishing = ProcessInfo.processInfo.arguments.contains("--verify-native-publish")
            let code = publishing ? "68342719" : MatchingCode.generate()
            let session = StreamSession(port: 18318, filter: SCContentFilter(display: display, excludingWindows: []),
                name: "原生视频验证", bitrate: 8_000_000, fps: 30, showsCursor: true, annotationEngine: annotation, code: code)
            if publishing {
                sessions.append(session); session.start(); refreshBroadcast()
                NSLog("NativePublisher READY code=%@ port=18318", code)
                return
            }
            let client = MacReceiverClient()
            let preview = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            preview.contentView = NSHostingView(rootView: MacStreamImageView(decoder: client.decoder))
            preview.title = "原生视频验证"; preview.orderFront(nil)
            session.start()
            defer { client.disconnect(); session.stop(); preview.orderOut(nil) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            client.connect(host: "127.0.0.1", port: 18318, code: code)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let first = client.frameCount
            session.updateQuality(bitrate: 4_000_000, fps: 60)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let image = client.decoder.frameForDisplay(after: nil)?.image
            NSLog("NativeCapture %@ first=%ld frames=%ld size=%@ status=%@", first >= 10 && client.frameCount > first && image != nil ? "PASS" : "FAIL", first, client.frameCount, String(describing: image?.extent.size), String(describing: client.status))
        } catch { NSLog("NativeCapture FAIL %@", error.localizedDescription) }
    }
}
#endif
