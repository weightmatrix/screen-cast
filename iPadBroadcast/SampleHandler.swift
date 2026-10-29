import ReplayKit
import Combine

final class SampleHandler: RPBroadcastSampleHandler {
    private let nativeCapture = NativeScreenSource()
    private var server: CastingServer?
    private var heartbeat: Timer?
    private var observation: AnyCancellable?
    private var running = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        nativeCapture.setPaused(false)
        let defaults = BroadcastSettings.store
        let code = defaults.string(forKey: "broadcastCode") ?? "67890123"
        guard MatchingCode.isValid(code) else {
            fail("请先在投屏 App 中设置 6–36 位数字匹配码")
            return
        }
        let fps = defaults.integer(forKey: "broadcastFPS") == 60 ? 60 : 30
        let bitrate = BroadcastSettings.clampedBitrate(defaults.integer(forKey: "broadcastBitrate"))
        let storedResolution = defaults.string(forKey: "broadcastResolution")
        let requestedResolution = BroadcastSettings.resolutionLimit(Int(storedResolution ?? "1600") ?? 1600)
        PerformanceDisk.shared.write("broadcast.settings storedResolution=\(storedResolution ?? "missing") requestedLimit=\(requestedResolution) screen=\(defaults.string(forKey: "broadcastScreenPixels") ?? "unknown")")
        defaults.set("等待系统提供画面", forKey: "broadcastResolutionStatus")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.running = true
            let server = CastingServer(port: 8318, accessCode: code, nativeSource: self.nativeCapture)
            server.configureNative(bitrate: bitrate, fps: fps, dimension: requestedResolution)
            server.nativeSource.onResolution = { summary in defaults.set(summary, forKey: "broadcastResolutionStatus") }
            self.server = server
            self.observation = server.$lastError.compactMap { $0 }.sink { [weak self] text in self?.fail("网络监听失败：\(text)") }
            PerformanceDisk.shared.relay = { [weak server] line in
                DispatchQueue.main.async { server?.sendDiagnostics(line) }
            }
            PerformanceDisk.shared.write("broadcast.start")
            server.onInternetStatus = { text in defaults.set(text, forKey: "broadcastInternetStatus") }
            server.setInternetMatchingEnabled(defaults.string(forKey: "broadcastInternetMode") != "ipOnly")
            server.setInternetEnabled(defaults.bool(forKey: "broadcastInternetEnabled"))
            server.start()
            DiscoveryBroadcaster.shared.start()
            DiscoveryBroadcaster.shared.update(entries: [(code, 8318)])
            defaults.set(true, forKey: "broadcastActive")
            defaults.set("正在投屏", forKey: "broadcastStatus")
            defaults.set(Date().timeIntervalSince1970, forKey: "broadcastHeartbeat")
            self.heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                defaults.set(Date().timeIntervalSince1970, forKey: "broadcastHeartbeat")
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        nativeCapture.append(sampleBuffer)
    }
    override func broadcastPaused() {
        nativeCapture.setPaused(true)
        BroadcastSettings.store.set("投屏已暂停", forKey: "broadcastStatus")
    }
    override func broadcastResumed() {
        nativeCapture.setPaused(false)
        BroadcastSettings.store.set("正在投屏", forKey: "broadcastStatus")
    }
    override func broadcastFinished() {
        nativeCapture.setPaused(true)
        DispatchQueue.main.async { [weak self] in self?.cleanup() }
    }
    private func cleanup() {
        running = false
        heartbeat?.invalidate(); heartbeat = nil
        observation = nil
        server?.stop(); server = nil
        DiscoveryBroadcaster.shared.stop()
        BroadcastSettings.store.set(false, forKey: "broadcastActive")
        if ["正在投屏", "投屏已暂停"].contains(BroadcastSettings.store.string(forKey: "broadcastStatus") ?? "") {
            BroadcastSettings.store.set("投屏已结束", forKey: "broadcastStatus")
        }
    }
    private func fail(_ message: String) {
        BroadcastSettings.store.set(message, forKey: "broadcastStatus")
        BroadcastSettings.store.set(false, forKey: "broadcastActive")
        finishBroadcastWithError(NSError(domain: "Touping.Broadcast", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

// Reuse the same authenticated transport and discovery code as native macOS.
final class DiagLog {
    static func log(_ tag: String, _ message: String) { NSLog("[%@] %@", tag, message) }
}
