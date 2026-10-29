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
    /// Exercises the real capture, encoder, TCP transport and receiver in the signed app.
    @MainActor func verifyCasting() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                DiagLog.log("RecoveryCheck", "FAIL no display")
                return
            }
            let session = StreamSession(port: 18318, filter: SCContentFilter(display: display, excludingWindows: []),
                name: "恢复验证", bitrate: 8_000_000, fps: 30, showsCursor: true, annotationEngine: annotation, code: String(repeating: "0", count: 30) + "123456")
            let internetCheck = ProcessInfo.processInfo.arguments.contains("--verify-internet-casting")
            let internetIPCheck = ProcessInfo.processInfo.arguments.contains("--verify-internet-ip")
            let internetPublish = ProcessInfo.processInfo.arguments.contains("--verify-internet-publish")
            session.internetMatchingEnabled = !internetIPCheck
            session.internetEnabled = internetCheck || internetIPCheck || internetPublish
            sessions.append(session)
            session.start()
            refreshBroadcast()
            if internetPublish {
                DiagLog.log("InternetCheck", "READY publisher code=\(session.code) port=\(session.port)")
                return
            }
            let client = MacReceiverClient()
            let preview = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 480),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            preview.contentView = NSHostingView(rootView: MacStreamImageView(decoder: client.decoder))
            preview.orderFront(nil)
            defer { preview.orderOut(nil) }
            var displayedFrames = 0
            var nonBlackFrames = 0
            client.decoder.onImageUpdate = { image in
                guard let image, let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data) else { return }
                displayedFrames += 1
                var bright = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 10)) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 10)) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           max(color.redComponent, color.greenComponent, color.blueComponent) > 0.15 { bright += 1 }
                    }
                }
                if bright > 10 { nonBlackFrames += 1 }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if internetCheck {
                for _ in 0..<60 {
                    if session.internetStatus.hasPrefix("广域网匹配就绪") { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                client.connectInternetCode(session.code)
            } else if internetIPCheck {
                client.connectInternetIP(host: "127.0.0.1", port: session.port + 1000, code: session.code)
            } else {
                client.connect(host: "127.0.0.1", port: session.port, code: session.code)
            }
            for _ in 0..<(internetCheck ? 160 : 40) {
                if nonBlackFrames >= 3 { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard nonBlackFrames >= 3 else {
                DiagLog.log("RecoveryCheck", "FAIL initial frames=\(displayedFrames) nonBlack=\(nonBlackFrames) status=\(client.status) phase=\(session.phase)")
                client.disconnect()
                removeSession(session)
                return
            }
            DiagLog.log("RecoveryCheck", "PASS capture -> H264 -> TCP -> decode -> visible image")
            if internetCheck || internetIPCheck {
                if ProcessInfo.processInfo.arguments.contains("--verify-internet-hold") {
                    let before = displayedFrames
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    DiagLog.log("InternetCheck", displayedFrames > before + 10 ? "PASS continued direct video without signaling media" : "FAIL continued direct video")
                }
                DiagLog.log("InternetCheck", "PASS \(internetCheck ? "public signaling -> P2P" : "TLS PSK direct") -> H264 decode -> GPU image frames=\(displayedFrames)")
                client.disconnect()
                removeSession(session)
                return
            }
            let qualityBefore = displayedFrames
            session.updateQuality(bitrate: 16_000_000, fps: 60)
            for _ in 0..<40 {
                if session.phase == .streaming, displayedFrames >= qualityBefore + 6,
                   session.encoderQualityMatches(bitrate: 16_000_000, fps: 60) { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            DiagLog.log("RecoveryCheck", session.encoderQualityMatches(bitrate: 16_000_000, fps: 60) && displayedFrames >= qualityBefore + 6
                        ? "PASS live bitrate/FPS applied to encoder and frames continue" : "FAIL live bitrate/FPS")
            let bitrateBefore = displayedFrames
            session.updateQuality(bitrate: 24_000_000)
            for _ in 0..<40 {
                if session.encoderQualityMatches(bitrate: 24_000_000, fps: 60), displayedFrames >= bitrateBefore + 3 { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            DiagLog.log("RecoveryCheck", session.encoderQualityMatches(bitrate: 24_000_000, fps: 60) && displayedFrames >= bitrateBefore + 3
                        ? "PASS bitrate-only update on existing encoder" : "FAIL bitrate-only update")
            if ProcessInfo.processInfo.arguments.contains("--verify-live-quality") {
                client.disconnect()
                removeSession(session)
                return
            }


            let before = displayedFrames
            session.refresh()
            for _ in 0..<40 {
                if displayedFrames >= before + 3, session.phase == .streaming { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            DiagLog.log("RecoveryCheck", displayedFrames >= before + 3 ? "PASS refresh continues frames" : "FAIL refresh")
            let windowContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let window = windowContent.windows.first(where: { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.frame.width > 100 }) {
                let oldCount = displayedFrames
                session.changeFilter(SCContentFilter(desktopIndependentWindow: window), name: "窗口切换验证")
                for _ in 0..<40 {
                    if displayedFrames >= oldCount + 3, session.phase == .streaming { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                DiagLog.log("RecoveryCheck", displayedFrames >= oldCount + 3 ? "PASS source switch continues frames" : "FAIL source switch")
                session.changeFilter(SCContentFilter(display: display, excludingWindows: []), name: "恢复验证")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } else { DiagLog.log("RecoveryCheck", "SKIP source switch: no visible app window") }
            client.disconnect()
            session.stop()
            try await Task.sleep(nanoseconds: 500_000_000)
            session.start()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let oldCount = displayedFrames
            client.connect(host: "127.0.0.1", port: session.port, code: session.code)
            for _ in 0..<40 {
                if displayedFrames >= oldCount + 3 { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            DiagLog.log("RecoveryCheck", displayedFrames >= oldCount + 3 ? "PASS stop/start and reconnect" : "FAIL stop/start")
            let rejected = MacReceiverClient()
            rejected.connect(host: "127.0.0.1", port: session.port, code: "00000000")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if case .failed(let message) = rejected.status, message.contains("匹配码错误") {
                DiagLog.log("RecoveryCheck", "PASS wrong code rejected with error")
            } else { DiagLog.log("RecoveryCheck", "FAIL wrong code status=\(rejected.status)") }
            rejected.disconnect()
            client.disconnect()
            MacDiscoveryListener.shared.start()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            DiagLog.log("RecoveryCheck", MacDiscoveryListener.shared.find(code: session.code) != nil ? "PASS LAN broadcast discovery" : "FAIL LAN broadcast discovery")
            MacDiscoveryListener.shared.stop()
            // Keep the sender alive briefly for the physical iPad verification.
            DiagLog.log("RecoveryCheck", "READY iPad code=\(session.code) port=\(session.port)")
        } catch {
            DiagLog.log("RecoveryCheck", "FAIL \(error.localizedDescription)")
        }
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
        server.start()
        server.onClientCountChanged = { [weak self] count in
            DispatchQueue.main.async { self?.clientCount = count }
        }
        server.onRemoteResolutionChanged = { [weak self] in
            self?.handleRemoteResolutionChanged()
        }
        server.onInternetBitrateLimit = { [weak self] limit in
            guard let self else { return }
            self.workQueue.async {
                self.internetBitrateLimit = limit
                if limit == nil { self.framePacer.reset(upper: self.targetFPS) }
                self.applyBitrate()
            }
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
        guard phase == .streaming, let remote = server.maxRemoteResolution else { return }
        let currentW = encWidth
        let currentH = encHeight
        let changed = abs(currentW - remote.width) > 16 || abs(currentH - remote.height) > 16
        guard changed else { return }
        DiagLog.log("Stream", "remote resolution changed \(currentW)x\(currentH) -> \(remote.width)x\(remote.height) port=\(port)")
        refresh()
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
        var padRes = server.maxRemoteResolution
        if let pad = padRes,
           pad.width <= 0 || pad.height <= 0 || pad.width > 16_384 || pad.height > 16_384 {
            DiagLog.log("Stream", "ignore invalid remote resolution \(pad.width)x\(pad.height) port=\(port)")
            padRes = nil
        }
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
        config.pixelFormat = kCVPixelFormatType_32BGRA
        encWidth = config.width
        encHeight = config.height
        DiagLog.log("Stream", "restartCapture target \(targetW)x\(targetH) fps=\(targetFPS) port=\(port)")
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
            DiagLog.log("Quality", "apply port=\(self.port) bitrate=\(self.bitrate) fps=\(self.targetFPS)")
            if self.qualityRequiresRestart {
                self.qualityRequiresRestart = false
                self.refresh()
            } else {
                self.workQueue.async { [weak self] in self?.applyBitrate() }
            }
        }
        qualityWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    #if DEBUG
    func encoderQualityMatches(bitrate: Int, fps: Int) -> Bool {
        workQueue.sync { () -> Bool in
            guard let encoder = compressionSession else { return false }
            var rate: Unmanaged<CFTypeRef>?, frameRate: Unmanaged<CFTypeRef>?
            let a = VTSessionCopyProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, allocator: nil, valueOut: &rate)
            let b = VTSessionCopyProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, allocator: nil, valueOut: &frameRate)
            let actualBitrate = (rate?.takeRetainedValue() as? NSNumber)?.intValue
            let actualFPS = (frameRate?.takeRetainedValue() as? NSNumber)?.intValue
            return a == noErr && b == noErr && actualBitrate == bitrate && actualFPS == fps
        }
    }
    #endif

    private var framePacer = EncoderFramePacer()
    private var lastPacedFrame = 0.0
    private var encodingFPS: Int { min(targetFPS, framePacer.target) }
    private var internetBitrateLimit: Int?
    private var effectiveBitrate: Int { min(bitrate, internetBitrateLimit ?? bitrate) }
    func applyBitrate() {
        guard let s = compressionSession else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: encodingFPS as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: effectiveBitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [effectiveBitrate * 3 / 8, 1] as CFArray)
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
    private func ensureH264Session(_ w: Int, _ h: Int) -> Bool {
        if w != encodeWidth || h != encodeHeight {
            if let s = compressionSession { VTCompressionSessionInvalidate(s); compressionSession = nil }
            lastSerializedFormatDescription = nil
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
            kVTCompressionPropertyKey_MaxFrameDelayCount: 1,
            kVTCompressionPropertyKey_AverageBitRate: effectiveBitrate,
            kVTCompressionPropertyKey_DataRateLimits: [effectiveBitrate * 3 / 8, 1] as [Any],
            kVTCompressionPropertyKey_ExpectedFrameRate: encodingFPS,
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
        // Drop before encoding, so H.264 reference chains stay intact.
        perf.record("capture")
        guard pendingEncodedFrames < 2 else { perf.record("dropBusy"); return }
        let now = ProcessInfo.processInfo.systemUptime
        if internetBitrateLimit != nil, now - lastPacedFrame < 0.95 / Double(encodingFPS) { perf.record("dropPaced"); return }
        lastPacedFrame = now
        drawAnnotations(on: pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard ensureH264Session(w, h), let ses = compressionSession else { return }
        var fp: CFDictionary?
        if needKeyFrame { fp = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary }
        ptsCounter += 600 / CMTimeValue(encodingFPS)
        let pts = CMTime(value: ptsCounter, timescale: 600)
        let generation = encodingGeneration
        pendingEncodedFrames += 1
        let encodeStart = ProcessInfo.processInfo.systemUptime
        let status = VTCompressionSessionEncodeFrame(ses, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: fp, infoFlagsOut: nil) { [weak self] st, flags, sb in
            guard let self else { return }
            self.workQueue.async {
                guard generation == self.encodingGeneration else { return }
                self.pendingEncodedFrames = max(0, self.pendingEncodedFrames - 1)
                let dropped = st == noErr && (flags.contains(.frameDropped) || sb == nil)
                if st == noErr {
                    let old = self.encodingFPS
                    let next = self.framePacer.observe(drop: dropped, now: ProcessInfo.processInfo.systemUptime,
                        upper: self.targetFPS, enabled: self.internetBitrateLimit != nil)
                    if old != next, let encoder = self.compressionSession {
                        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: next as CFNumber)
                        PerformanceDisk.shared.write("mac.adaptiveFPS target=\(next)")
                    }
                }
                if dropped { self.perf.record("dropRateControl"); return }
                guard st == noErr, let sb else { self.needKeyFrame = true; return }
                self.perf.record("encoded", milliseconds: (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000, bytes: CMSampleBufferGetTotalSampleSize(sb))
                self.handleEncoded(sb)
            }
        }
        if status == noErr {
            needKeyFrame = false
        } else {
            pendingEncodedFrames = max(0, pendingEncodedFrames - 1)
            needKeyFrame = true
            DiagLog.log("Stream", "encode failed status=\(status)")
        }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        guard let (data, isKey) = StreamFormat.annexB(sb) else {
            DiagLog.log("BlackScreen", "h264ToAnnexB nil port=\(port)")
            return
        }
        if isKey {
            needKeyFrame = false
            if let fd = StreamFormat.serialize(fmt), fd != lastSerializedFormatDescription {
                lastSerializedFormatDescription = fd
                server.sendConfig(fd)
            }
        }
        encodedFrameLogCounter += 1
        if encodedFrameLogCounter <= 3 || encodedFrameLogCounter % 30 == 0 {
            DiagLog.log("BlackScreen", "encodedFrame #\(encodedFrameLogCounter) bytes=\(data.count) key=\(isKey) port=\(port)")
        }
        server.sendFrame(data, isKeyFrame: isKey)
        reportFPS()
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
