import Foundation
import Combine
import Network
import UIKit

final class StreamClient: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var frameCount: Int = 0
    @Published private(set) var recoveryMessage = ""
    private lazy var recovery: ConnectionRecovery = {
        let value = ConnectionRecovery()
        value.state = { [weak self] in
            switch self?.status {
            case .connected: return .connected
            case .connecting: return .connecting
            case .failed: return .failed
            default: return .idle
            }
        }
        value.onTransition = { text in ConnectionDiag.shared.log("recovery " + text) }
        value.waitingForApproval = { [weak self] in self?.waitingForApproval == true }
        value.cancelTransport = { [weak self] in self?.disconnect(userInitiated: false) }
        value.onMessage = { [weak self] text in
            if self?.recoveryMessage != text { self?.recoveryMessage = text }
        }
        value.onExhausted = { [weak self] in self?.setStatus(.failed("重连失败，已断开；请点击连接重试")) }
        return value
    }()
    private var waitingForApproval = false
    private var autoConnectStarted = false
    let decoder = ImageDecoder()

    @Published var receivesPageAudio = true { didSet { updateAudio() } }
    @Published var receivesMicrophone = true { didSet { updateAudio() } }
    private func updateAudio() { nativePeer?.receiveAudio(page: receivesPageAudio, microphone: receivesMicrophone) }
    @Published private(set) var receiveTiming = ReceiveTiming()
    private var nativePeer: NativeVideoPeer?
    private var nativeRoom: NativeVideoRoom?
    private var internetDirect = false
    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var rxOffset = 0
    private var expectedPayloadLength: Int?
    private var expectedType: UInt8?
    private let netQueue = DispatchQueue.main
    private var connectionTimeout: DispatchWorkItem?
    private let lastDataLock = NSLock()
    private var lastDataAt = Date()
    private var isDisconnecting = false
    private var lastHost: String?
    private var lastPort: UInt16?
    private var lastMatchCode: String?
    var connectionPassword = ""
    var applicationText = ""
    private var authenticationCode: String?
    private var isThermalHigh = false
    private var lastKeyFrameRequest = Date.distantPast
    private var receivedFrames = 0
    var discoveryLookup: ((String) -> (String, UInt16)?)?

    private static let maxMessageLength = 8 * 1024 * 1024

    init() {
        decoder.onNeedsKeyFrame = { [weak self] in self?.requestKeyFrame() }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIdleTimerDisabled()
        }
        updateIdleTimerDisabled()
    }

    private func configureNativePeer(_ video: NativeVideoPeer) {
        nativePeer = video
        updateAudio()
        video.onReceiveTiming = { [weak self, weak video] timing in
            guard let self, self.nativePeer === video else { return }
            self.receiveTiming = timing
        }
        var count = 0
        video.onImage = { [weak self, weak video] image in
            guard let self, video != nil else { return }
            self.decoder.publishNativeFrame(image)
            count += 1
            let number = count
            if number == 1 || number % 30 == 0 {
                DispatchQueue.main.async { [weak self, weak video] in
                    guard let self, self.nativePeer === video else { return }
                    self.receivedFrames = number; self.frameCount = number
                    self.lastDataAt = Date()
                    self.connectionTimeout?.cancel(); self.setStatus(.connected); self.recovery.noteMediaReceived()
                }
            }
        }
        video.onConnected = { [weak self] in self?.connectionTimeout?.cancel() }
        video.onError = { [weak self, weak video] text in
            guard let self, self.nativePeer === video else { return }
            if !self.recovery.hasReceivedMedia { self.recovery.stop() }
            self.disconnect(userInitiated: false); self.setStatus(.failed(text))
        }
    }

    func connectInternetCode(_ code: String) {
        if !recovery.isAttempting {
            autoConnectStarted = true
            recovery.begin { [weak self] in self?.connectInternetCode(code) }; return
        }
        disconnect(userInitiated: false)
        guard MatchingCode.isValid(code) else { setStatus(.failed("请输入 6–36 位数字匹配码")); return }
        isDisconnecting = false
        setStatus(.connecting)
        let room = NativeVideoRoom(code: code, password: connectionPassword, application: applicationText)
        nativeRoom = room
        room.onWaitingApproval = { [weak self] in self?.waitingForApproval = true }
        room.onApproved = { [weak self] in self?.waitingForApproval = false }
        configureNativePeer(room.video)
        room.onConnected = { [weak self] in self?.connectionTimeout?.cancel() }
        room.onError = { [weak self, weak room] text in
            guard let self, self.nativeRoom === room else { return }
            if !self.recovery.hasReceivedMedia { self.recovery.stop() }
            self.disconnect(userInitiated: false); self.setStatus(.failed(text))
        }
        room.start()
    }

    func connectInternetIP(host: String, port: UInt16, code: String) {
        if !recovery.isAttempting {
            autoConnectStarted = true
            recovery.begin { [weak self] in self?.connectInternetIP(host: host, port: port, code: code) }; return
        }
        disconnect(userInitiated: false)
        internetDirect = true
        isDisconnecting = false
        lastHost = host; lastPort = port; authenticationCode = code
        startConnection()
    }

    func connect(host: String, port: UInt16, code: String) {
        if !recovery.isAttempting {
            autoConnectStarted = true
            recovery.begin { [weak self] in self?.connect(host: host, port: port, code: code) }; return
        }
        ConnectionDiag.shared.log("connect host=\(host) port=\(port)")
        disconnect(userInitiated: false)
        isDisconnecting = false
        lastHost = host
        lastPort = port
        authenticationCode = code
        startConnection()
    }

    func connectWithCode(_ code: String) {
        if !recovery.isAttempting {
            autoConnectStarted = true
            recovery.begin { [weak self] in self?.connectWithCode(code) }; return
        }
        ConnectionDiag.shared.log("connectWithCode code=\(code)")
        disconnect(userInitiated: false)
        isDisconnecting = false
        lastMatchCode = code
        authenticationCode = code
        guard let lookup = discoveryLookup, let found = lookup(code) else {
            ConnectionDiag.shared.log("connectWithCode lookup miss")
            setStatus(.failed("未找到匹配码对应的投屏流"))
            return
        }
        ConnectionDiag.shared.log("connectWithCode found \(found.0):\(found.1)")
        lastHost = found.0
        lastPort = found.1
        startConnection()
    }

    private func startConnection() {
        guard connection == nil, let host = lastHost, let port = lastPort else { return }
        guard !host.isEmpty, port > 0, AdmissionCredentials.validPassword(connectionPassword), AdmissionCredentials.application(applicationText) != nil else {
            setStatus(.failed("请填写有效地址、端口和 6–36 位数字匹配码"))
            return
        }
        isDisconnecting = false
        ConnectionDiag.shared.log("startConnection \(host):\(port) code=\(lastMatchCode ?? "-")")
        do {
            rxBuffer.removeAll(keepingCapacity: false)
            rxOffset = 0
            expectedPayloadLength = nil
            expectedType = nil
        }
        lastDataLock.lock()
        lastDataAt = Date()
        lastDataLock.unlock()
        setStatus(.connecting)
        decoder.reset()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: internetDirect ? InternetSettings.tlsParameters(code: connectionPassword) : .tcp)
        self.connection = connection
        ConnectionDiag.shared.relay = { [weak self] entry in
            self?.sendDiagnostic(entry)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    ConnectionDiag.shared.log("connection ready \(host):\(port)")
                    self.netQueue.async { [weak self] in self?.readLoop(on: connection) }
                case .failed(let error):
                    ConnectionDiag.shared.log("connection failed \(host):\(port)")
                    self.handleDisconnect(connection)
                    self.setStatus(.failed(error.localizedDescription))
                case .cancelled:
                    ConnectionDiag.shared.log("connection cancelled \(host):\(port)")
                    self.handleDisconnect(connection)
                case .waiting(let error):
                    ConnectionDiag.shared.log("connection waiting \(host):\(port) error=\(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: netQueue)
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            self.handleDisconnect(connection)
            self.setStatus(.failed("连接或认证超时，请检查地址、端口和匹配码"))
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 340, execute: timeout)
        updateIdleTimerDisabled()
    }

    private func handleDisconnect(_ disconnectedConnection: NWConnection) {
        ConnectionDiag.shared.log("handleDisconnect isDisconnecting=\(isDisconnecting)")
        guard !isDisconnecting, connection === disconnectedConnection else { return }
        connectionTimeout?.cancel()
        disconnectedConnection.cancel()
        connection = nil
        do {
            self.rxBuffer.removeAll(keepingCapacity: false)
            self.rxOffset = 0
            self.expectedPayloadLength = nil
            self.expectedType = nil
        }
        setStatus(.idle)
        updateIdleTimerDisabled()
    }

    func autoSearch(mode: String, host: String, port: UInt16, code: String) {
        guard AdmissionCredentials.validPassword(connectionPassword), AdmissionCredentials.application(applicationText) != nil, !autoConnectStarted, !recovery.isActive,
              MatchingCode.isValid(code), mode == "code" || (mode == "ip" && !host.isEmpty) else { return }
        autoConnectStarted = true
        if mode == "code" { connectWithCode(code) } else { connect(host: host, port: port, code: code) }
    }

    func disconnect(userInitiated: Bool = true) {
        ConnectionDiag.shared.log("disconnect userInitiated=\(userInitiated) frames=\(frameCount)")
        RoomAudioSettings.shared.setMicrophone(false)
        waitingForApproval = false
        if userInitiated { autoConnectStarted = true; recovery.stop() }
        receiveTiming = ReceiveTiming()
        nativeRoom?.stop(); nativeRoom = nil
        nativePeer?.stop(); nativePeer = nil
        internetDirect = false
        connectionTimeout?.cancel()
        ConnectionDiag.shared.relay = nil
        isDisconnecting = true
        lastHost = nil
        lastPort = nil
        lastMatchCode = nil
        authenticationCode = nil
        let conn = connection
        connection = nil
        conn?.cancel()
        do {
            rxBuffer.removeAll(keepingCapacity: false)
            rxOffset = 0
            expectedPayloadLength = nil
            expectedType = nil
        }
        receivedFrames = 0
        frameCount = 0
        setStatus(.idle)
        decoder.reset()
        updateIdleTimerDisabled()
    }

    /// iOS may freeze the process before Network.framework reports that the
    /// peer disappeared. Drop that transport explicitly so a wake-up never
    /// reuses a connection whose state predates suspension.
    func prepareForSuspension() {
        recovery.suspend()
        connectionTimeout?.cancel()
        ConnectionDiag.shared.log("app suspended; discard transport")
        isDisconnecting = true
        let conn = connection
        connection = nil
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        rxBuffer.removeAll(keepingCapacity: false)
        rxOffset = 0
        expectedPayloadLength = nil
        expectedType = nil
        setStatus(.idle)
        decoder.reset()
        isDisconnecting = false
    }

    func resumeAfterSuspension() { recovery.resume() }

    private func sendScreenSize() {
        guard let conn = connection else { return }
        let bounds = UIScreen.main.bounds
        let w = UInt32(bounds.width * UIScreen.main.scale)
        let h = UInt32(bounds.height * UIScreen.main.scale)
        var msg = Data()
        msg.append(contentsOf: w.bytes)
        msg.append(contentsOf: h.bytes)
        var head = Data()
        head.append(uint32: msg.count)
        head.append(UInt8(2))
        ConnectionDiag.shared.log("sendScreenSize \(w)x\(h)")
        conn.send(content: head + msg, completion: .idempotent)
    }

    private func sendAuthentication(nonce: String, invitation: String) {
        guard let conn = connection, AdmissionCredentials.validPassword(connectionPassword),
              let application = AdmissionCredentials.application(applicationText) else { return }
        let proof = AdmissionCredentials.proof(verifier: AdmissionCredentials.verifier(password: connectionPassword, invitation: invitation), nonce: nonce)
        guard let payload = NativeVideo.packet(["proof":proof, "application":application, "nickname":RoomSession.shared.nickname]) else { return }
        var msg = Data(); msg.append(uint32: payload.count); msg.append(UInt8(5)); msg.append(payload)
        conn.send(content: msg, completion: .idempotent)
        let video = NativeVideoPeer(internet: internetDirect, auditDirect: internetDirect)
        configureNativePeer(video)
        video.sendSignal = { [weak conn] object in if let conn { NativeVideo.send(object, over: conn) } }
        var hello: [String: Any] = ["type":"hello", "version":3]
        if let auditID = video.directAudit?.sessionID { hello["audit_session"] = auditID }
        NativeVideo.send(hello, over: conn)
        sendScreenSize()
    }

    private func setStatus(_ s: Status) {
        status = s
        updateIdleTimerDisabled()
    }

    func setStatus(_ message: String) {
        setStatus(.failed(message))
    }

    private func updateIdleTimerDisabled() {
        let state = ProcessInfo.processInfo.thermalState
        isThermalHigh = state == .serious || state == .critical
        if case .connected = status {
            UIApplication.shared.isIdleTimerDisabled = !isThermalHigh
        } else {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func readLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.lastDataLock.lock()
                self.lastDataAt = Date()
                self.lastDataLock.unlock()
                self.rxBuffer.append(data)
                self.parseMessages()
            }
            if let error {
                ConnectionDiag.shared.log("readLoop error \(error.localizedDescription)")
                self.setStatus(.failed(error.localizedDescription))
                DispatchQueue.main.async { [weak self] in self?.handleDisconnect(connection) }
                return
            }
            if isComplete {
                ConnectionDiag.shared.log("readLoop complete")
                DispatchQueue.main.async { [weak self] in self?.handleDisconnect(connection) }
                return
            }
            self.readLoop(on: connection)
        }
    }

    private func parseMessages() {
        var consumed = 0
        while true {
            let totalAvailable = rxBuffer.count - rxOffset
            let remaining = totalAvailable - consumed
            if let expectedPayloadLength, let expectedType {
                guard remaining >= expectedPayloadLength else { break }
                let start = rxOffset + consumed
                let payload = rxBuffer.copySlice(start, expectedPayloadLength)
                consumed += expectedPayloadLength
                self.expectedPayloadLength = nil
                self.expectedType = nil
                handle(type: expectedType, payload: payload)
            } else {
                guard remaining >= 5 else { break }
                let base = rxOffset + consumed
                let length = rxBuffer.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                    guard base + 4 < ptr.count else { return -1 }
                    return Int(ptr.loadUnaligned(fromByteOffset: base, as: UInt32.self).bigEndian)
                }
                guard length > 0, length <= Self.maxMessageLength else {
                    ConnectionDiag.shared.log("parse error invalid length \(length)")
                    rxBuffer.removeAll(keepingCapacity: false)
                    rxOffset = 0
                    consumed = 0
                    expectedPayloadLength = nil
                    expectedType = nil
                    connection?.cancel()
                    connection = nil
                    setStatus(.failed("数据流异常，请重新连接"))
                    return
                }
                let type = rxBuffer.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> UInt8 in
                    guard base + 4 < ptr.count else { return 0 }
                    return ptr.load(fromByteOffset: base + 4, as: UInt8.self)
                }
                consumed += 5
                expectedPayloadLength = length
                expectedType = type
            }
            if totalAvailable > Self.maxMessageLength * 4 {
                ConnectionDiag.shared.log("parse error buffer overflow total=\(totalAvailable)")
                rxBuffer.removeAll(keepingCapacity: false)
                rxOffset = 0
                consumed = 0
                expectedPayloadLength = nil
                expectedType = nil
                connection?.cancel()
                connection = nil
                setStatus(.failed("数据流异常，请重新连接"))
                return
            }
        }
        if consumed > 0 {
            rxOffset += consumed
            if rxOffset > 1_000_000 || rxOffset * 2 > rxBuffer.count {
                rxBuffer.removeFirst(rxOffset)
                rxOffset = 0
            }
        }
    }

    func checkStaleConnection() {
        if nativePeer != nil { return }
        guard case .connected = status, let conn = connection else { return }
        lastDataLock.lock()
        let elapsed = Date().timeIntervalSince(lastDataAt)
        lastDataLock.unlock()
        guard elapsed > 15 else { return }
        ConnectionDiag.shared.log("stale connection elapsed=\(String(format: "%.1f", elapsed)) force reconnect")
        conn.cancel()
        connection = nil
        netQueue.async { [weak self] in
            self?.rxBuffer.removeAll(keepingCapacity: false)
            self?.rxOffset = 0
            self?.expectedPayloadLength = nil
            self?.expectedType = nil
        }
        setStatus(.idle)
    }

    private func requestKeyFrame() {
        guard case .connected = status, let connection,
              Date().timeIntervalSince(lastKeyFrameRequest) >= 0.15 else { return }
        lastKeyFrameRequest = Date()
        connection.send(content: Data([0, 0, 0, 1, 10, 1]), completion: .contentProcessed { _ in })
    }

    private func sendDiagnostic(_ entry: String) {
        netQueue.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            let payload = Data(entry.utf8)
            guard payload.count > 0, payload.count <= 60_000 else { return }
            var msg = Data()
            msg.append(uint32: payload.count)
            msg.append(UInt8(4))
            msg.append(payload)
            conn.send(content: msg, completion: .contentProcessed { _ in })
        }
    }

    private func handle(type: UInt8, payload: Data) {
        switch type {
        case 22:
            DispatchQueue.main.async { [weak self] in self?.waitingForApproval = true }
        case 21:
            guard let source = connection,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: String],
                  let nonce = object["nonce"], nonce.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                  let invitation = object["invite"], MatchingCode.isValid(invitation) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === source else { return }
                self.sendAuthentication(nonce: nonce, invitation: invitation)
            }
        case 20:
            DispatchQueue.main.async { [weak self] in self?.waitingForApproval = false }
            if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { nativePeer?.receive(object) }
        case 0, 1:
            disconnect()
            setStatus(.failed("对端仍使用旧视频协议，请将两端更新到原生视频版"))
        case 11:
            if payload.count <= 2048, let line = String(data: payload, encoding: .utf8) {
                PerformanceDisk.shared.write("remote \(line)", forward: false)
            }
        case 7:
            DispatchQueue.main.async { [weak self] in self?.recovery.stop() }
            let message = String(data: payload, encoding: .utf8) ?? "匹配码错误"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let conn = self.connection { self.handleDisconnect(conn) }
                self.isDisconnecting = true
                self.setStatus(.failed(message))
            }
        default:
            break
        }
    }
}



extension UInt32 {
    var bytes: [UInt8] {
        var v = bigEndian
        return Swift.withUnsafeBytes(of: &v) { Array($0) }
    }
}
