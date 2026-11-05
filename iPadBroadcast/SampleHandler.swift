import ReplayKit
import Combine

final class SampleHandler: RPBroadcastSampleHandler {
    private let nativeCapture = NativeScreenSource()
    private var server: CastingServer?
    private var heartbeat: Timer?
    private var observation: AnyCancellable?
    private var running = false
    private var lastDiagnosticSnapshot = ""
    private var lastDiagnosticNetwork = ""
    private var lastPendingSnapshot = ""
    private let lifecycleLock = NSLock()
    private var lifecycle: UUID?

    private func isCurrent(_ token: UUID) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return lifecycle == token
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let token = UUID()
        lifecycleLock.lock(); lifecycle = token; lifecycleLock.unlock()
        PerformanceDisk.shared.write("broadcast.lifecycle started token=\(token) version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown") build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown")")
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
            guard let self, self.isCurrent(token) else { return }
            self.running = true
            self.lastDiagnosticSnapshot = ""; self.lastDiagnosticNetwork = ""; self.lastPendingSnapshot = ""
            let server = CastingServer(port: 8318, accessCode: code, nativeSource: self.nativeCapture)
            server.configureNative(bitrate: bitrate, fps: fps, dimension: requestedResolution)
            server.nativeSource.onResolution = { summary in defaults.set(summary, forKey: "broadcastResolutionStatus") }
            self.server = server
            defaults.set("", forKey: "broadcastKick")
            defaults.set("[]", forKey: "broadcastPeers")
            defaults.set("[]", forKey: "broadcastPending")
            defaults.set("", forKey: "broadcastApproval")
            self.observation = server.$lastError.compactMap { $0 }.sink { [weak self] text in self?.fail("网络监听失败：\(text)") }
            PerformanceDisk.shared.relay = { [weak server] line in
                DispatchQueue.main.async { server?.sendDiagnostics(line) }
            }
            PerformanceDisk.shared.write("broadcast.start")
            server.onInternetStatus = { text in defaults.set(text, forKey: "broadcastInternetStatus") }
            server.setInternetMatchingEnabled(defaults.string(forKey: "broadcastInternetMode") != "ipOnly")
            server.setInternetEnabled(defaults.bool(forKey: "broadcastInternetEnabled"))
            server.start()
            guard self.isCurrent(token) else { server.stop(); return }
            DiscoveryBroadcaster.shared.start()
            DiscoveryBroadcaster.shared.update(entries: [(code, 8318)])
            defaults.set(true, forKey: "broadcastActive")
            defaults.set("正在投屏", forKey: "broadcastStatus")
            defaults.set(Date().timeIntervalSince1970, forKey: "broadcastHeartbeat")
            self.nativeCapture.audio.configure(page: defaults.bool(forKey: "broadcastPageAudio"), microphone: defaults.bool(forKey: "broadcastMicAudio"))
            self.heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.nativeCapture.audio.configure(page: defaults.bool(forKey: "broadcastPageAudio"), microphone: defaults.bool(forKey: "broadcastMicAudio"))
                defaults.set(Date().timeIntervalSince1970, forKey: "broadcastHeartbeat")
                if let server = self?.server {
                    if let data = try? JSONEncoder().encode(server.pendingConnections) {
                        let pendingJSON = String(decoding: data, as: UTF8.self)
                        if pendingJSON != self?.lastPendingSnapshot {
                            defaults.set(pendingJSON, forKey: "broadcastPending")
                            self?.lastPendingSnapshot = pendingJSON
                        }
                    }
                    if let command = defaults.string(forKey: "broadcastApproval"), !command.isEmpty {
                        defaults.set("", forKey: "broadcastApproval")
                        let parts = command.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 { server.respondToRequest(String(parts[1]), accept: parts[0] == "accept") }
                    }
                    let snapshot = try? JSONEncoder().encode(server.diagnostics)
                    let json = snapshot.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    if json != self?.lastDiagnosticSnapshot {
                        defaults.set(json, forKey: "broadcastPeers")
                        self?.lastDiagnosticSnapshot = json
                    }
                    let ips = CastingServer.localIPs.joined(separator: "、")
                    let network = "\(ips)/\(server.listeningPort ?? 0)/\(server.internetListeningPort ?? 0)/\(server.browserListeningPort ?? 0)"
                    if network != self?.lastDiagnosticNetwork {
                        defaults.set(ips, forKey: "broadcastLocalIPs")
                        defaults.set(Int(server.listeningPort ?? 0), forKey: "broadcastSignalPort")
                        defaults.set(Int(server.internetListeningPort ?? 0), forKey: "broadcastInternetPort")
                        defaults.set(Int(server.browserListeningPort ?? 0), forKey: "broadcastBrowserPort")
                        self?.lastDiagnosticNetwork = network
                    }
                    if let command = defaults.string(forKey: "broadcastKick"), !command.isEmpty {
                        // Consume once; peer UUIDs cannot target a later connection.
                        defaults.set("", forKey: "broadcastKick")
                        server.disconnectPeer(command)
                    }
                }
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video: nativeCapture.append(sampleBuffer)
        case .audioApp: nativeCapture.audio.append(sampleBuffer, microphone: false)
        case .audioMic: nativeCapture.audio.append(sampleBuffer, microphone: true)
        @unknown default: break
        }
    }
    override func broadcastPaused() {
        PerformanceDisk.shared.write("broadcast.lifecycle paused")
        nativeCapture.setPaused(true)
        BroadcastSettings.store.set("投屏已暂停", forKey: "broadcastStatus")
    }
    override func broadcastResumed() {
        PerformanceDisk.shared.write("broadcast.lifecycle resumed")
        nativeCapture.setPaused(false)
        BroadcastSettings.store.set("正在投屏", forKey: "broadcastStatus")
    }
    override func broadcastFinished() {
        lifecycleLock.lock(); lifecycle = nil; lifecycleLock.unlock()
        PerformanceDisk.shared.write("broadcast.lifecycle finished")
        nativeCapture.setPaused(true)
        DispatchQueue.main.async { [weak self] in self?.cleanup() }
    }
    private func cleanup() {
        running = false
        PerformanceDisk.shared.relay = nil
        heartbeat?.invalidate(); heartbeat = nil
        observation = nil
        server?.stop(); server = nil
        BroadcastSettings.store.set("[]", forKey: "broadcastPeers")
        BroadcastSettings.store.set("[]", forKey: "broadcastPending")
        BroadcastSettings.store.set("", forKey: "broadcastApproval")
        BroadcastSettings.store.set("", forKey: "broadcastKick")
        DiscoveryBroadcaster.shared.stop()
        BroadcastSettings.store.set(false, forKey: "broadcastActive")
        if ["正在投屏", "投屏已暂停"].contains(BroadcastSettings.store.string(forKey: "broadcastStatus") ?? "") {
            BroadcastSettings.store.set("投屏已结束", forKey: "broadcastStatus")
        }
    }
    private func fail(_ message: String) {
        lifecycleLock.lock(); let wasActive = lifecycle != nil; lifecycle = nil; lifecycleLock.unlock()
        guard wasActive else { return }
        PerformanceDisk.shared.write("broadcast.lifecycle failed reason=\(message)")
        BroadcastSettings.store.set(message, forKey: "broadcastStatus")
        BroadcastSettings.store.set(false, forKey: "broadcastActive")
        nativeCapture.setPaused(true)
        DispatchQueue.main.async { [weak self] in self?.cleanup() }
        finishBroadcastWithError(NSError(domain: "Touping.Broadcast", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

// Reuse the same authenticated transport and discovery code as native macOS.
final class DiagLog {
    static func log(_ tag: String, _ message: String) { NSLog("[%@] %@", tag, message) }
}
