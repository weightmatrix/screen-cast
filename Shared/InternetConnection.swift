import Foundation
import Network
import Security
import CryptoKit
import WebRTC

enum ConnectionMode: String, CaseIterable, Identifiable {
    case localIP = "ip", localCode = "code", internetIP = "wanIP", internetCode = "wanCode"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .localIP: return "局域 IP 直连"
        case .localCode: return "局域匹配码"
        case .internetIP: return "广域网 IP 直连"
        case .internetCode: return "广域网匹配码"
        }
    }
}

enum InternetSettings {
    static let signalingURL = URL(string: "wss://zhibenwang.com/touping/signal")!
    static let stunURL = "stun:49.233.174.254:3478"
    static func room(_ code: String) -> String { SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func tlsParameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let key = Data(SHA256.hash(data: Data(("touping-tls-v1:" + code).utf8)))
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("touping-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// P2P DTLS/SCTP carries the existing byte protocol. The pairing server never receives these bytes.
final class InternetTunnel: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    var onReady: ((UInt16) -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onRegistered: (() -> Void)?
    var onBitrateLimit: ((Int) -> Void)?
    private var rateController = InternetRateController()
    private var rateWork: DispatchWorkItem?
    private var rateBytes = 0
    private var rateStalled = 0.0
    private var rateCongested = false
    private var rateSampleTime = 0.0
    func noteCongestion() { rateCongested = true }
    var onClosed: (() -> Void)?
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }()
    private let senderPort: UInt16?
    private let code: String
    private let signalingURL: URL
    private let stunURL: String
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var listener: NWListener?
    private var pipe: NWConnection?
    private var timeout: DispatchWorkItem?
    private var closed = false
    private var connected = false
    private var channelOpened = false
    private var pipeReady = false
    private var credits = PeerByteWindow()
    private var incomingQueue: [Data] = []
    private var delivering = false
    private var pendingAcknowledgement = 0
    private var waitingForBuffer = false
    private var resumeWork: DispatchWorkItem?
    private var windowRetry: DispatchWorkItem?
    private var localWindowAcknowledged = false
    private var creditWaitStarted: Double?
    private let flowPerf: StreamPerformance
    #if DEBUG
    func verifyBufferWake() {
        guard let channel else { return }
        waitingForBuffer = true
        // Inject a drained-buffer delegate event; loopback may never saturate the SDK buffer.
        dataChannel(channel, didChangeBufferedAmount: 0)
    }
    var verificationBufferLimit: UInt64 = 131072
    private(set) var bufferWakeCount = 0
    private(set) var flowPauseCount = 0
    private(set) var peakIncomingBytes = 0
    private var deliveryHeldForVerification = false
    func setDeliveryHeldForVerification(_ held: Bool) {
        deliveryHeldForVerification = held
        if !held { drainIncoming() }
    }
    #endif
    private var reading = false
    private var pendingRead: Data?
    private var incomingBytes = 0
    private var signalBytes = 0
    private var receivedSignalBytes = 0
    private var remoteSet = false
    private var candidates: [RTCIceCandidate] = []
    private var offerStarted = false

    init(code: String, senderPort: UInt16? = nil, signalingURL: URL = InternetSettings.signalingURL, stunURL: String = InternetSettings.stunURL) {
        self.code = code; self.senderPort = senderPort
        self.flowPerf = StreamPerformance(senderPort == nil ? "internet.receiver.flow" : "internet.sender.flow")
        self.signalingURL = signalingURL; self.stunURL = stunURL
        super.init()
    }

    func start() {
        guard MatchingCode.isValid(code), !closed, peer == nil else { return }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [RTCIceServer(urlStrings: [stunURL, "stun:stun.cloudflare.com:3478"])]
        config.iceTransportPolicy = .all // No TURN URL or credentials, so no relay candidate can be allocated.
        config.iceCandidatePoolSize = 0
        peer = Self.factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        guard peer != nil else { fail("无法启动 P2P 连接"); return }
        let configSession = URLSessionConfiguration.ephemeral
        configSession.timeoutIntervalForRequest = 610
        configSession.urlCache = nil
        let session = URLSession(configuration: configSession)
        self.session = session
        let task = session.webSocketTask(with: signalingURL)
        socket = task
        task.maximumMessageSize = 16384
        task.resume()
        signal(["role": senderPort == nil ? "receiver" : "sender", "room": InternetSettings.room(code)])
        listen(task)
        if senderPort == nil { armTimeout() }
    }

    private func armTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail("P2P 直连失败，当前网络可能不支持穿透；未使用视频中继") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: work)
    }

    func stop() {
        guard !closed else { return }
        closed = true
        rateWork?.cancel(); rateWork = nil
        timeout?.cancel(); timeout = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        listener?.cancel(); listener = nil
        pipe?.cancel(); pipe = nil
        channel?.delegate = nil; channel?.close(); channel = nil
        peer?.delegate = nil; peer?.close(); peer = nil
        resumeWork?.cancel(); resumeWork = nil
        windowRetry?.cancel(); windowRetry = nil
        candidates.removeAll(); pendingRead = nil
        incomingQueue.removeAll(); incomingBytes = 0; pendingAcknowledgement = 0
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        stop()
        onError?(message)
        onClosed?()
    }

    private func signal(_ object: [String: Any]) {
        guard !closed, let socket, let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 16384 else { return }
        signalBytes += data.count
        guard signalBytes <= 65536 else { fail("配对数据超过限制"); return }
        let text = String(decoding: data, as: UTF8.self)
        Task { [weak self, weak socket] in
            do { try await socket?.send(.string(text)) }
            catch { DispatchQueue.main.async { if self?.connected == false { self?.fail("无法连接公网配对服务") } } }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        Task { [weak self, weak task] in
            guard let task else { return }
            do {
                let message = try await task.receive()
                let data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.receivedSignalBytes += data.count
                    guard self.receivedSignalBytes <= 65536,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.fail("配对响应无效"); return }
                    self.handle(obj)
                    if self.socket === task { self.listen(task) }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, !self.connected else { return }
                    self.fail("配对连接已结束，请重试")
                }
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "waiting": onRegistered?()
        case "peer":
            guard senderPort != nil, !offerStarted else { return }
            offerStarted = true
            armTimeout()
            let config = RTCDataChannelConfiguration()
            config.isOrdered = true
            channel = peer?.dataChannel(forLabel: "touping-stream-v2", configuration: config)
            channel?.delegate = self
            makeDescription(offer: true)
        case "offer", "answer":
            guard let sdp = obj["sdp"] as? String, sdp.utf8.count <= 12288 else { fail("配对描述无效"); return }
            let isOffer = obj["type"] as? String == "offer"
            guard isOffer == (senderPort == nil) else { fail("配对角色无效"); return }
            peer?.setRemoteDescription(RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: sdp)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.closed else { return }
                    guard error == nil else { self.fail("无法应用 P2P 连接描述"); return }
                    self.remoteSet = true
                    for candidate in self.candidates { self.peer?.add(candidate, completionHandler: { _ in }) }
                    self.candidates.removeAll()
                    if isOffer { self.makeDescription(offer: false) }
                }
            }
        case "candidate":
            guard let sdp = obj["candidate"] as? String, sdp.utf8.count <= 2048,
                  !sdp.contains(" typ relay"), let line = (obj["line"] as? NSNumber)?.int32Value else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line, sdpMid: obj["mid"] as? String)
            if remoteSet { peer?.add(candidate, completionHandler: { _ in }) }
            else if candidates.count < 64 { candidates.append(candidate) }
        case "error": fail(String((obj["message"] as? String ?? "配对失败").prefix(120)))
        default: fail("配对响应类型无效")
        }
    }

    private func makeDescription(offer: Bool) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let completion: (RTCSessionDescription?, Error?) -> Void = { [weak self] description, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                guard error == nil, let description else { self.fail("无法创建 P2P 连接描述"); return }
                self.peer?.setLocalDescription(description) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, !self.closed else { return }
                        guard error == nil else { self.fail("无法设置 P2P 连接描述"); return }
                        self.signal(["type": offer ? "offer" : "answer", "sdp": description.sdp])
                    }
                }
            }
        }
        if offer { peer?.offer(for: constraints, completionHandler: completion) }
        else { peer?.answer(for: constraints, completionHandler: completion) }
    }

    private func openPipe() {
        guard !closed, !channelOpened else { return }
        channelOpened = true
        timeout?.cancel()
        let handshake = DispatchWorkItem { [weak self] in self?.fail("P2P 流控握手失败，请将两端更新到最新版后重连") }
        timeout = handshake
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: handshake)
        announceWindow()
        if let senderPort {
            attachPipe(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: senderPort)!, using: .tcp))
        } else {
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] conn in
                    guard let self, self.pipe == nil else { conn.cancel(); return }
                    self.attachPipe(conn)
                    self.listener?.cancel(); self.listener = nil
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    if case .ready = state, let port = listener?.port { self?.onReady?(port.rawValue) }
                    if case .failed = state { self?.fail("无法建立本地 P2P 接口") }
                }
                listener.start(queue: .main)
            } catch { fail("无法创建本地 P2P 接口") }
        }
    }

    private func finishHandshake() {
        guard !closed, channelOpened, credits.limit > 0, localWindowAcknowledged, !connected else { return }
        connected = true; timeout?.cancel(); timeout = nil
        windowRetry?.cancel(); windowRetry = nil
        PerformanceDisk.shared.write("internet.direct connected pairingBytes=\(signalBytes + receivedSignalBytes) relay=false flowVersion=2 role=\(senderPort == nil ? "receiver" : "sender") receiveWindow=\(PeerByteWindow.capacity)")
        signal(["type":"done"])
        onConnected?()
        if senderPort != nil {
            rateSampleTime = ProcessInfo.processInfo.systemUptime
            onBitrateLimit?(rateController.target)
            scheduleRateSample()
        }
        readPipe()
    }

    private func scheduleRateSample() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closed else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let start = self.creditWaitStarted {
                self.rateStalled += now - start
                self.creditWaitStarted = now
            }
            let elapsed = now - self.rateSampleTime
            let limit = self.rateController.sample(bytes: self.rateBytes, seconds: elapsed,
                stalledSeconds: self.rateStalled, congested: self.rateCongested)
            PerformanceDisk.shared.write("internet.adaptive target=\(limit) ackBytes=\(self.rateBytes) elapsed=\(elapsed) stalled=\(self.rateStalled) congestion=\(self.rateCongested)")
            self.onBitrateLimit?(limit)
            self.rateBytes = 0; self.rateStalled = 0; self.rateCongested = false
            self.rateSampleTime = now
            self.scheduleRateSample()
        }
        rateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func announceWindow() {
        guard !closed, !connected, channelOpened else { return }
        _ = sendControl("W:\(PeerByteWindow.capacity)")
        let work = DispatchWorkItem { [weak self] in self?.announceWindow() }
        windowRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func noteCreditPause() {
        guard creditWaitStarted == nil else { return }
        creditWaitStarted = ProcessInfo.processInfo.systemUptime
        flowPerf.record("waitingForCredit")
        #if DEBUG
        flowPauseCount += 1
        #endif
    }

    private func sendControl(_ text: String) -> Bool {
        guard !closed, let channel, channel.readyState == .open else { return false }
        let sent = channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
        if !sent { waitingForBuffer = true }
        return sent
    }

    private func scheduleResume() {
        guard !closed, resumeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resumeWork = nil
            self.flushAcknowledgements()
            self.readPipe()
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flushAcknowledgements() {
        guard !closed, pendingAcknowledgement > 0 else { return }
        if sendControl("A:\(pendingAcknowledgement)") { pendingAcknowledgement = 0 }
        else { scheduleResume() }
    }

    private func handleControl(_ data: Data) {
        guard data.count <= 32, let text = String(data: data, encoding: .utf8),
              let separator = text.firstIndex(of: ":"),
              let count = Int(text[text.index(after: separator)...]) else { fail("直连流控消息无效"); return }
        switch text[..<separator] {
        case "W":
            if credits.limit == 0 {
                guard credits.announce(count) else { fail("直连接收窗口无效"); return }
            } else if credits.limit != count { fail("直连接收窗口发生异常变化"); return }
            // Repeated announcements acknowledge the same window, never mint more credits.
            _ = sendControl("R:\(count)")
            finishHandshake()
        case "R":
            guard count == PeerByteWindow.capacity else { fail("直连窗口确认无效"); return }
            localWindowAcknowledged = true
            finishHandshake()
        case "A":
            guard credits.acknowledge(count) else { fail("直连确认窗口无效"); return }
            rateBytes += count
            flowPerf.record("ack", bytes: count)
            if let started = creditWaitStarted {
                rateStalled += ProcessInfo.processInfo.systemUptime - started
                flowPerf.record("creditWait", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
                creditWaitStarted = nil
            }
            readPipe()
        default: fail("双方需要更新到支持直连流控的版本")
        }
    }

    private func drainIncoming() {
        #if DEBUG
        guard !deliveryHeldForVerification else { return }
        #endif
        guard !closed, pipeReady, !delivering, !incomingQueue.isEmpty, let pipe else { return }
        let data = incomingQueue.removeFirst()
        delivering = true
        let started = ProcessInfo.processInfo.systemUptime
        pipe.send(content: data, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.delivering = false
                guard error == nil else { self.fail("本地视频接口断开"); return }
                self.incomingBytes -= data.count
                self.pendingAcknowledgement += data.count
                self.flowPerf.record("delivered", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, bytes: data.count)
                if self.pendingAcknowledgement >= 32768 || self.incomingQueue.isEmpty { self.flushAcknowledgements() }
                self.drainIncoming()
            }
        })
    }

    private func attachPipe(_ connection: NWConnection) {
        pipe = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, self.pipe === connection else { return }
            PerformanceDisk.shared.write("internet.pipe role=\(self.senderPort == nil ? "receiver" : "sender") state=\(state) endpoint=\(connection?.endpoint.debugDescription ?? "nil")")
            if case .ready = state { self.pipeReady = true; self.drainIncoming(); self.readPipe() }
            if case .failed = state { self.fail("直连已断开") }
            if case .cancelled = state, !self.closed { self.fail("直连已断开") }
        }
        connection.start(queue: .main)
    }

    private func readPipe() {
        guard !closed, connected, pipeReady, let pipe, let channel,
              channel.readyState == .open, !reading else { return }
        if pendingAcknowledgement > 0 {
            flushAcknowledgements()
            if pendingAcknowledgement > 0 { return }
        }
        guard credits.available > 0 else {
            noteCreditPause()
            return // Acknowledgements wake the sender; there is no polling or disconnect.
        }
        #if DEBUG
        let bufferLimit = verificationBufferLimit
        #else
        let bufferLimit: UInt64 = 131072
        #endif
        if channel.bufferedAmount >= bufferLimit { waitingForBuffer = true; scheduleResume(); return }
        if let pendingRead {
            guard pendingRead.count <= credits.available else { return }
            guard channel.sendData(RTCDataBuffer(data: pendingRead, isBinary: true)) else { waitingForBuffer = true; scheduleResume(); return }
            guard credits.sent(pendingRead.count) else { fail("直连发送窗口无效"); return }
            flowPerf.record("sent", bytes: pendingRead.count)
            self.pendingRead = nil
        }
        guard credits.available > 0 else {
            noteCreditPause()
            return
        }
        reading = true
        pipe.receive(minimumIncompleteLength: 1, maximumLength: min(8192, credits.available)) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.reading = false
                if let data, !data.isEmpty { self.pendingRead = data }
                if done || error != nil { self.fail("对方已结束直连"); return }
                self.readPipe()
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        DispatchQueue.main.async { [weak self, weak dataChannel] in
            guard let self, !self.closed, self.waitingForBuffer,
                  let dataChannel, self.channel === dataChannel,
                  dataChannel.bufferedAmount < 65536 else { return }
            self.waitingForBuffer = false
            self.resumeWork?.cancel(); self.resumeWork = nil
            #if DEBUG
            self.bufferWakeCount += 1
            #endif
            self.flowPerf.record("bufferEventWake")
            self.flushAcknowledgements()
            self.readPipe()
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            if dataChannel.readyState == .open { self.openPipe() }
            if dataChannel.readyState == .closed { self.fail("P2P 直连已结束") }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            if !buffer.isBinary { self.handleControl(buffer.data); return }
            guard self.connected, !buffer.data.isEmpty, buffer.data.count <= 8192 else {
                self.fail("直连数据版本不匹配，请更新双方后重连"); return
            }
            self.incomingBytes += buffer.data.count
            guard self.incomingBytes <= PeerByteWindow.capacity else {
                self.fail("对方未遵循直连流控，请更新双方后重连"); return
            }
            #if DEBUG
            self.peakIncomingBytes = max(self.peakIncomingBytes, self.incomingBytes)
            #endif
            self.incomingQueue.append(buffer.data)
            self.drainIncoming()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed { DispatchQueue.main.async { [weak self] in self?.fail("P2P 无法直连，未启用视频中继") } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !candidate.sdp.contains(" typ relay") else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, !self.connected else { return }
            self.signal(["type":"candidate", "candidate":candidate.sdp, "mid":candidate.sdpMid as Any? ?? NSNull(), "line":candidate.sdpMLineIndex])
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Install on the WebRTC callback thread so its first ordered message is not lost.
        dataChannel.delegate = self
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            guard dataChannel.label == "touping-stream-v2" else { self.fail("请将投屏两端更新到支持流控的版本"); return }
            self.channel = dataChannel; dataChannel.delegate = self
            if dataChannel.readyState == .open { self.openPipe() }
        }
    }
}

#if DEBUG
@MainActor enum InternetFlowVerification {
    static func run() async {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let source = try NWListener(using: parameters)
            let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 251) })
            var sources: [NWConnection] = []
            source.newConnectionHandler = { connection in
                DispatchQueue.main.async {
                    sources.append(connection)
                    connection.start(queue: .main)
                    connection.send(content: payload, completion: .idempotent)
                }
            }
            source.start(queue: .main)
            for _ in 0..<40 {
                if let port = source.port, port.rawValue != 0 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let port = source.port, port.rawValue != 0 else { PerformanceDisk.shared.write("FlowCheck FAIL source listener"); return }
            let code = MatchingCode.generate()
            let sender = InternetTunnel(code: code, senderPort: port.rawValue)
            let receiver = InternetTunnel(code: code)
            sender.verificationBufferLimit = 8192
            var issue: String?
            var registered = false
            var finished = false
            var received = Data()
            var client: NWConnection?
            defer {
                finished = true
                sender.stop(); receiver.stop(); client?.cancel()
                sources.forEach { $0.cancel() }; source.cancel()
            }
            receiver.setDeliveryHeldForVerification(true)
            receiver.onConnected = { [weak receiver] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak receiver] in
                    receiver?.setDeliveryHeldForVerification(false)
                }
            }
            sender.onRegistered = { registered = true }
            sender.onConnected = { [weak sender] in sender?.verifyBufferWake() }
            sender.onError = { if !finished { issue = $0 } }
            receiver.onError = { if !finished { issue = $0 } }
            receiver.onReady = { port in
                let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                client = connection
                func readNext() {
                    guard !finished else { return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, done, error in
                        DispatchQueue.main.async {
                            guard !finished else { return }
                            if let data { received.append(data) }
                            if received.count > payload.count { issue = "duplicate bytes"; return }
                            if received.count == payload.count { return }
                            if error != nil || done { issue = "early local EOF"; return }
                            readNext()
                        }
                    }
                }
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { readNext() }
                    }
                }
                connection.start(queue: .main)
            }
            sender.start()
            for _ in 0..<120 {
                if registered || issue != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if registered { receiver.start() }
            else { issue = issue ?? "registration timed out" }
            for _ in 0..<450 {
                if received.count == payload.count || issue != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let passed = issue == nil && received == payload && sender.flowPauseCount > 0
                && receiver.peakIncomingBytes <= PeerByteWindow.capacity && sender.bufferWakeCount > 0
            PerformanceDisk.shared.write("FlowCheck \(passed ? "PASS" : "FAIL") slow-receiver 4MiB bytes=\(received.count) pauseCount=\(sender.flowPauseCount) bufferWakeCount=\(sender.bufferWakeCount) peakIncoming=\(receiver.peakIncomingBytes) limit=\(PeerByteWindow.capacity) issue=\(issue ?? "none")")
            NSLog("FlowCheck %@ bytes=%ld pauses=%ld peak=%ld issue=%@", passed ? "PASS" : "FAIL", received.count, sender.flowPauseCount, receiver.peakIncomingBytes, issue ?? "none")
        } catch {
            PerformanceDisk.shared.write("FlowCheck FAIL \(error.localizedDescription)")
        }
    }
}
#endif
