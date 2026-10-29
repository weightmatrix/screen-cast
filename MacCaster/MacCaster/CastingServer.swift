import Foundation
import Combine
import Network

final class CastingServer: ObservableObject {
    private struct OutboundMessage {
        let type: UInt8
        let payload: Data
        let queuedAt = ProcessInfo.processInfo.systemUptime
    }

    struct LocalIPInfo {
        let ip: String
        let priority: Int
    }

    let port: UInt16
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    var onNativeFPS: ((Double) -> Void)?
    var onClientCountChanged: ((Int) -> Void)?
    var onRemoteResolutionChanged: (() -> Void)?
    var onNeedsKeyFrame: (() -> Void)?
    var onTouchEvent: (([String: Any], ObjectIdentifier) -> Void)?
    var onTouchDisconnect: ((ObjectIdentifier) -> Void)?
    // Reject input even from older receivers that still expose touch controls.
    let touchEnabled = false
    var accessCode: String {
        didSet { if oldValue != accessCode, internetEnabled { stopInternet(); startInternet() } }
    }
    private var internetEnabled = false
    private var internetMatchingEnabled = true
    func setInternetMatchingEnabled(_ enabled: Bool) {
        guard enabled != internetMatchingEnabled else { return }
        internetMatchingEnabled = enabled
        if !enabled {
            internetRetry?.cancel(); internetRetry = nil
            nativeRoom?.stop(); nativeRoom = nil
            internetVideoConnected = false; notifyClientCountChanged()
        }
        startInternet()
    }
    private var internetListener: NWListener?
    let nativeSource: NativeScreenSource
    private var nativePeers: [ObjectIdentifier: NativeVideoPeer] = [:]
    private var internetConnections: Set<ObjectIdentifier> = []
    private var nativeBitrate = 100_000_000
    private var nativeFPS = 60
    private var nativeRoom: NativeVideoRoom?
    private var internetVideoConnected = false
    func configureNative(bitrate: Int, fps: Int, dimension: Int = 0) {
        nativeBitrate = bitrate; nativeFPS = fps
        nativeSource.configure(fps: fps, dimension: dimension)
        nativePeers.values.forEach { $0.quality(bitrate: bitrate, fps: fps) }
        nativeRoom?.video.quality(bitrate: bitrate, fps: fps)
    }
    private var internetRetry: DispatchWorkItem?
    private var internetFailures = 0
    var onInternetStatus: ((String) -> Void)?
    var internetPort: UInt16? { port <= 64535 ? port + 1000 : nil }

    func setInternetEnabled(_ enabled: Bool) {
        guard enabled != internetEnabled else { return }
        internetEnabled = enabled
        if enabled { startInternet() } else { stopInternet(); onInternetStatus?("广域网已关闭") }
    }

    private func stopInternet() {
        internetVideoConnected = false; notifyClientCountChanged()
        internetRetry?.cancel(); internetRetry = nil
        nativeRoom?.stop(); nativeRoom = nil
        internetListener?.cancel(); internetListener = nil
    }

    private func startInternet() {
        guard internetEnabled, isRunning, MatchingCode.isValid(accessCode) else { return }
        if internetListener == nil, let internetPort {
            do {
                let listener = try NWListener(using: InternetSettings.tlsParameters(code: accessCode), on: NWEndpoint.Port(rawValue: internetPort)!)
                internetListener = listener
                listener.newConnectionHandler = { [weak self] conn in
                    self?.internetConnections.insert(ObjectIdentifier(conn)); self?.accept(conn)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.onInternetStatus?("公网 IP 监听失败；可尝试广域网匹配码") }
                }
                listener.start(queue: .main)
            } catch { onInternetStatus?("公网 IP 监听失败；可尝试广域网匹配码") }
        }
        guard internetMatchingEnabled else {
            onInternetStatus?("公网 IP 端口 \(internetPort ?? 0) · 不使用配对服务器")
            return
        }
        guard nativeRoom == nil else { return }
        let room = NativeVideoRoom(code: accessCode, source: nativeSource, bitrate: nativeBitrate, fps: nativeFPS)
        nativeRoom = room
        room.video.onSendingFPS = { [weak self] fps in self?.onNativeFPS?(fps) }
        room.onRegistered = { [weak self] in self?.onInternetStatus?("广域网匹配就绪 · 原生视频") }
        room.onConnected = { [weak self] in
            guard let self else { return }
            self.internetFailures = 0; self.internetVideoConnected = true; self.notifyClientCountChanged()
            self.onInternetStatus?("P2P 已直连 · 原生视频")
        }
        room.onError = { [weak self] text in
            guard let self else { return }
            self.onInternetStatus?(text); self.nativeRoom = nil
            self.internetVideoConnected = false; self.notifyClientCountChanged()
            guard self.internetEnabled, self.internetMatchingEnabled, self.isRunning else { return }
            self.internetFailures = min(self.internetFailures + 1, 5)
            let work = DispatchWorkItem { [weak self] in self?.startInternet() }; self.internetRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + min(60, 5 * pow(2, Double(self.internetFailures - 1))), execute: work)
        }
        room.start()
    }

    private let perf = StreamPerformance("transport.send")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var clientResolutions: [ObjectIdentifier: (Int, Int)] = [:]
    private var controlBuffers: [ObjectIdentifier: [UInt8]] = [:]
    private var authenticatedConnections: Set<ObjectIdentifier> = []
    private var outboundQueues: [ObjectIdentifier: [OutboundMessage]] = [:]
    private var sendsInFlight: Set<ObjectIdentifier> = []
    private var awaitingKeyFrame: Set<ObjectIdentifier> = []
    private var authTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var lastConfig: Data?
    private var bindRetryWorkItem: DispatchWorkItem?
    private var lastKeyFrameRequest = Date.distantPast

    var maxRemoteResolution: (width: Int, height: Int)? {
        let vals = clientResolutions.values
        guard !vals.isEmpty else { return nil }
        let maxW = vals.map(\.0).max()!
        let maxH = vals.map(\.1).max()!
        return (maxW, maxH)
    }

    static var localIPs: [String] {
        localIPInfos.map(\.ip)
    }

    static var localIPInfos: [LocalIPInfo] {
        var results: [LocalIPInfo] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let iface = current.pointee
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (iface.ifa_flags & UInt32(IFF_UP)) != 0, (iface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: host)
                    if !name.hasPrefix("127.") {
                        let interfaceName = iface.ifa_name.map { String(cString: $0) } ?? ""
                        let priority = Self.priority(interfaceName: interfaceName, ip: name)
                        results.append(LocalIPInfo(ip: name, priority: priority))
                    }
                }
            }
            pointer = iface.ifa_next
        }
        freeifaddrs(ifaddr)
        return results.sorted { $0.priority > $1.priority }
    }

    private static func priority(interfaceName: String, ip: String) -> Int {
        if ip.hasPrefix("169.254.") {
            return 5
        }
        if interfaceName.hasPrefix("en") {
            return 60
        }
        if interfaceName.hasPrefix("bridge") {
            return 50
        }
        if interfaceName.hasPrefix("awdl") {
            return 10
        }
        return 20
    }

    init(port: UInt16, accessCode: String, nativeSource: NativeScreenSource = NativeScreenSource()) {
        self.nativeSource = nativeSource
        self.port = port
        self.accessCode = accessCode
    }

    func start() {
        bindRetryWorkItem?.cancel()
        bindRetryWorkItem = nil
        guard listener == nil else { return }
        bindListener(retry: 0)
    }

    private func bindListener(retry: Int) {
        guard listener == nil else { return }
        lastError = nil
        DiagLog.log("Connection", "listener start port \(port)")
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.stateUpdateHandler = { [weak self, weak l] state in
                DispatchQueue.main.async {
                    guard let self, let l else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.startInternet()
                        DiagLog.log("Connection", "listener ready port \(self.port)")
                    case .failed(let e):
                        guard self.listener === l else { return }
                        self.lastError = e.localizedDescription
                        self.isRunning = false
                        l.cancel()
                        self.listener = nil
                        DiagLog.log("Connection", "listener failed port \(self.port): \(e.localizedDescription)")
                        self.scheduleBindRetry(after: 0.5, retry: retry + 1)
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                DiagLog.log("Connection", "accepted conn port \(self?.port ?? 0)")
                self?.accept(conn)
            }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = error.localizedDescription
            DiagLog.log("Connection", "listener create failed port \(port): \(error.localizedDescription)")
            scheduleBindRetry(after: 0.5, retry: retry + 1)
        }
    }

    private func scheduleBindRetry(after delay: TimeInterval, retry: Int) {
        guard retry <= 3, listener == nil else { return }
        bindRetryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bindRetryWorkItem = nil
            self.bindListener(retry: retry)
        }
        bindRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func stop() {
        stopInternet()
        DiagLog.log("Connection", "server stop port \(port) connections=\(connections.count)")
        bindRetryWorkItem?.cancel()
        bindRetryWorkItem = nil
        nativePeers.values.forEach { $0.stop() }; nativePeers.removeAll(); internetConnections.removeAll()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        controlBuffers.removeAll()
        authenticatedConnections.removeAll()
        outboundQueues.removeAll()
        sendsInFlight.removeAll()
        awaitingKeyFrame.removeAll()
        authTimeouts.values.forEach { $0.cancel() }
        authTimeouts.removeAll()
        clientResolutions.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        DispatchQueue.main.async { [weak self] in self?.onClientCountChanged?(0) }
    }

    private func accept(_ conn: NWConnection) {
        DiagLog.log("Connection", "conn accepted \(conn.endpoint.debugDescription)")
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            switch state {
            case .failed, .cancelled:
                DiagLog.log("Connection", "conn dropped \(conn.endpoint.debugDescription) state=\(state)")
                self?.drop(conn)
            default:
                break
            }
        }
        conn.start(queue: .main)
        connections.append(conn)
        let key = ObjectIdentifier(conn)
        let timeout = DispatchWorkItem { [weak self, weak conn] in
            guard let self, let conn, !self.authenticatedConnections.contains(key) else { return }
            DiagLog.log("Connection", "authentication timeout \(conn.endpoint.debugDescription)")
            conn.cancel()
        }
        authTimeouts[key] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        readResolution(from: conn)
    }

    private func drop(_ conn: NWConnection) {
        guard connections.contains(where: { $0 === conn }) else { return }
        conn.cancel()
        DiagLog.log("Connection", "drop conn \(conn.endpoint.debugDescription)")
        connections.removeAll { $0 === conn }
        let key = ObjectIdentifier(conn)
        nativePeers.removeValue(forKey: key)?.stop()
        internetConnections.remove(key)
        onTouchDisconnect?(key)
        controlBuffers[key] = nil
        clientResolutions[key] = nil
        authenticatedConnections.remove(key)
        outboundQueues[key] = nil
        sendsInFlight.remove(key)
        awaitingKeyFrame.remove(key)
        authTimeouts.removeValue(forKey: key)?.cancel()
        notifyClientCountChanged()
    }

    private func readResolution(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn else { return }
            guard self.connections.contains(where: { $0 === conn }) else { return }
            let key = ObjectIdentifier(conn)
            if let data, !data.isEmpty {
                self.controlBuffers[key, default: []].append(contentsOf: data)
                self.parseControlMessages(for: conn)
            }
            if error != nil || isComplete {
                self.drop(conn)
            } else {
                self.readResolution(from: conn)
            }
        }
    }

    private func parseControlMessages(for conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard var buffer = controlBuffers[key] else { return }
        while buffer.count >= 5 {
            let length = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
            })
            guard length >= 0, length <= 64 * 1024 else {
                conn.cancel()
                return
            }
            guard buffer.count >= 5 + length else { break }
            let type = buffer[4]
            if type == 5 {
                let codeData = Data(buffer[5..<(5 + length)])
                if let code = String(data: codeData, encoding: .utf8), MatchingCode.isValid(code), code == accessCode {
                    authenticate(conn)
                } else {
                    DiagLog.log("Connection", "authentication rejected \(conn.endpoint.debugDescription)")
                    controlBuffers[key] = nil
                    let payload = Data("匹配码错误，请输入发送端显示的匹配码".utf8)
                    var message = Data()
                    message.append(uint32: payload.count)
                    message.append(UInt8(7))
                    message.append(payload)
                    conn.send(content: message, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
            } else if authenticatedConnections.contains(key), type == 20 {
                let data = Data(buffer[5..<(5 + length)])
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { conn.cancel(); return }
                if object["type"] as? String == "hello" {
                    guard nativePeers[key] == nil else { conn.cancel(); return }
                    let video = NativeVideoPeer(source: nativeSource, internet: internetConnections.contains(key), bitrate: nativeBitrate, fps: nativeFPS)
                    nativePeers[key] = video
                    video.onSendingFPS = { [weak self] fps in self?.onNativeFPS?(fps) }
                    video.sendSignal = { [weak conn] object in if let conn { NativeVideo.send(object, over: conn) } }
                    video.onError = { [weak self, weak conn] _ in if let conn { self?.drop(conn) } }
                    video.offer()
                } else { nativePeers[key]?.receive(object) }
            } else if authenticatedConnections.contains(key), type == 2, length == 8 {
                let w = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self).bigEndian })
                let h = Int(buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: UInt32.self).bigEndian })
                if w > 0, h > 0, w <= 16_384, h <= 16_384 {
                    clientResolutions[key] = (w, h)
                    DiagLog.log("Connection", "remote resolution \(w)x\(h) conn=\(conn.endpoint.debugDescription)")
                    self.onRemoteResolutionChanged?()
                } else {
                    DiagLog.log("Connection", "invalid remote resolution \(w)x\(h) conn=\(conn.endpoint.debugDescription)")
                    conn.cancel()
                    return
                }
            } else if authenticatedConnections.contains(key), type == 10, length == 1 {
                self.requestKeyFrame()
            } else if authenticatedConnections.contains(key), touchEnabled, type == 9, length <= 2048 {
                let payload = Data(buffer[5..<(5 + length)])
                if let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    onTouchEvent?(event, key)
                }
            } else if authenticatedConnections.contains(key), type == 4, length > 0 {
                let textData = Data(buffer[5..<(5 + length)])
                if let text = String(data: textData, encoding: .utf8) {
                    DiagLog.log("iPad", text)
                }
            }
            buffer.removeFirst(5 + length)
        }
        controlBuffers[key] = buffer
    }

    private func authenticate(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard !authenticatedConnections.contains(key) else { return }
        authenticatedConnections.insert(key)
        authTimeouts.removeValue(forKey: key)?.cancel()
        awaitingKeyFrame.insert(key)
        DiagLog.log("Connection", "authentication accepted \(conn.endpoint.debugDescription)")
        notifyClientCountChanged()
        enqueue(type: 8, payload: Data([touchEnabled ? 1 : 0]), isKeyFrame: false, to: conn)
        // Authentication is control only; native video starts after the versioned hello.
    }

    private func notifyClientCountChanged() {
        onClientCountChanged?(authenticatedConnections.count + (internetVideoConnected ? 1 : 0))
    }

    func sendConfig(_ serializedFD: Data) {
        var payload = Data()
        payload.append(UInt8(3))
        payload.append(uint32: serializedFD.count)
        payload.append(serializedFD)
        DispatchQueue.main.async {
            // Repeated keyframes have the same format. Re-announcing it clears valid queued video.
            guard self.lastConfig != payload else { return }
            DiagLog.log("Connection", "sendConfig fd=\(serializedFD.count) port=\(self.port)")
            self.lastConfig = payload
            self.broadcast(type: 0, payload: payload)
        }
    }

    func sendDiagnostics(_ line: String) {
        broadcast(type: 11, payload: Data(line.prefix(2048).utf8))
    }

    func sendFrame(_ data: Data, isKeyFrame: Bool) {
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            self.perf.record("sendMainQueueWait", milliseconds: (ProcessInfo.processInfo.systemUptime - enqueuedAt) * 1000)
            self.perf.interval("enqueueInterval")
            self.broadcast(type: 1, payload: data, isKeyFrame: isKeyFrame)
        }
    }

    private func broadcast(type: UInt8, payload: Data, isKeyFrame: Bool = false) {
        for conn in connections where authenticatedConnections.contains(ObjectIdentifier(conn)) {
            enqueue(type: type, payload: payload, isKeyFrame: isKeyFrame, to: conn)
        }
    }

    private func enqueue(type: UInt8, payload: Data, isKeyFrame: Bool, to conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard authenticatedConnections.contains(key) else { return }

        if type == 1, awaitingKeyFrame.contains(key), !isKeyFrame {
            return
        }

        let isInternetPipe = internetConnections.contains(key)
        let frameLimit = isInternetPipe ? 2 : 3
        let ageLimit = isInternetPipe ? 0.06 : 0.1
        var queue = outboundQueues[key] ?? []
        if type == 0 {
            queue.removeAll { $0.type == 0 || $0.type == 1 }
            awaitingKeyFrame.insert(key)
        } else if type == 1, isKeyFrame {
            queue.removeAll { $0.type == 1 }
            awaitingKeyFrame.remove(key)
        } else if type == 1, queue.filter({ $0.type == 1 }).count >= frameLimit ||
                    (type == 1 && queue.contains { $0.type == 1 && ProcessInfo.processInfo.systemUptime - $0.queuedAt > ageLimit }) {
            queue.removeAll { $0.type == 1 }
            awaitingKeyFrame.insert(key)
            outboundQueues[key] = queue
            DiagLog.log("Connection", "backpressure requests keyframe \(conn.endpoint.debugDescription)")
            perf.record("backpressure")
            requestKeyFrame()
            return
        }

        queue.append(OutboundMessage(type: type, payload: payload))
        outboundQueues[key] = queue
        pumpSend(to: conn)
    }

    private func requestKeyFrame() {
        guard Date().timeIntervalSince(lastKeyFrameRequest) >= 0.5 else { return }
        lastKeyFrameRequest = Date()
        onNeedsKeyFrame?()
    }

    private func pumpSend(to conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard !sendsInFlight.contains(key),
              var queue = outboundQueues[key],
              !queue.isEmpty else { return }
        let message = queue.removeFirst()
        outboundQueues[key] = queue
        sendsInFlight.insert(key)
        var msg = Data()
        msg.append(uint32: message.payload.count)
        msg.append(message.type)
        msg.append(message.payload)
        let sendStart = ProcessInfo.processInfo.systemUptime
        if message.type == 1 { perf.record("queueWait", milliseconds: (sendStart - message.queuedAt) * 1000) }
        conn.send(content: msg, completion: .contentProcessed { [weak self, weak conn] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if message.type == 1 { self.perf.record(error == nil ? "sent" : "sendError", milliseconds: (ProcessInfo.processInfo.systemUptime - sendStart) * 1000, bytes: message.payload.count) }
                self.sendsInFlight.remove(key)
                if error != nil, let conn {
                    self.drop(conn)
                } else if let conn {
                    self.pumpSend(to: conn)
                }
            }
        })
    }
}
