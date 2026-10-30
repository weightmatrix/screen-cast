import Foundation
import Combine
import Network
import Darwin
import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import VideoToolbox

final class MacDiscoveryListener {
    static let shared = MacDiscoveryListener()
    static let udpPort: UInt16 = 8321

    private var socketFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var entries: [String: (ip: String, port: UInt16, priority: Int)] = [:]
    private var lastSeen: [String: Date] = [:]
    private let queue = DispatchQueue(label: "discovery", qos: .utility)

    func start() {
        guard socketFd < 0 else { return }
        DiagLog.log("Discovery", "discovery start udp=\(Self.udpPort)")

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            DiagLog.log("Discovery", "discovery socket create failed errno=\(errno)")
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.udpPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            DiagLog.log("Discovery", "discovery bind failed errno=\(errno)")
            return
        }

        socketFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receiveDatagram()
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
        DiagLog.log("Discovery", "discovery started")
    }

    func stop() {
        let source = readSource
        readSource = nil
        let fd = socketFd
        socketFd = -1
        if let source {
            source.cancel()
        } else if fd >= 0 {
            close(fd)
        }
    }

    private func receiveDatagram() {
        guard socketFd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bufferCount = buffer.count
        let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(socketFd, raw.baseAddress, bufferCount, 0, sa, &addrLen)
                }
            }
        }
        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = dict["code"] as? String,
              MatchingCode.isValid(code),
              let portNumber = dict["port"] as? NSNumber,
              portNumber.intValue > 0,
              portNumber.intValue <= Int(UInt16.max) else {
            return
        }

        var bestIP = Self.ipv4String(from: addr) ?? ""
        var bestPriority = bestIP.isEmpty ? 0 : 1_000
        if bestIP.isEmpty, let ips = dict["ips"] as? [[String: Any]] {
            for item in ips {
                guard let ip = item["ip"] as? String, !ip.isEmpty else { continue }
                let priority = (item["priority"] as? NSNumber)?.intValue ?? 0
                if bestIP.isEmpty || priority > bestPriority {
                    bestIP = ip
                    bestPriority = priority
                }
            }
        }
        guard !bestIP.isEmpty else { return }

        let port = UInt16(portNumber.intValue)
        entries[code] = (bestIP, port, bestPriority)
        lastSeen[code] = Date()
        DiagLog.log("Discovery", "discovery recv code=\(code) \(bestIP):\(port) priority=\(bestPriority)")
    }

    private static func ipv4String(from addr: sockaddr_in) -> String? {
        var addr = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = withUnsafePointer(to: &addr.sin_addr) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<in_addr>.size) { raw in
                inet_ntop(AF_INET, raw, &buffer, socklen_t(buffer.count))
            }
        }
        guard result != nil else { return nil }
        return String(cString: buffer)
    }

    func find(code: String) -> (ip: String, port: UInt16)? {
        queue.sync {
            guard let entry = entries[code] else { return nil }
            if let seen = lastSeen[code], Date().timeIntervalSince(seen) > 8 {
                entries.removeValue(forKey: code)
                lastSeen.removeValue(forKey: code)
                DiagLog.log("Discovery", "discovery expired code=\(code)")
                return nil
            }
            DiagLog.log("Discovery", "discovery hit code=\(code) \(entry.0):\(entry.1) priority=\(entry.2)")
            return (entry.0, entry.1)
        }
    }
}

final class MacReceiverDecoder: ObservableObject {
    @Published var diagText = "等待画面"

    #if DEBUG
    var onImageUpdate: ((NSImage?) -> Void)?
    #endif
    private let frameLock = NSLock()
    private var latestFrame: CIImage?
    private var frameRevision: UInt64 = 0
    private var frameDecodedAt = ProcessInfo.processInfo.systemUptime
    private var frameHandler: (() -> Void)?
    private let decodeQueue = DispatchQueue(label: "casting.mac.decode", qos: .userInteractive)

    func setFrameHandler(_ handler: (() -> Void)?) {
        frameLock.lock()
        frameHandler = handler
        frameLock.unlock()
        handler?()
    }

    func publishFrame(_ image: CIImage?) {
        frameLock.lock()
        latestFrame = image
        frameRevision &+= 1
        frameDecodedAt = ProcessInfo.processInfo.systemUptime
        let handler = frameHandler
        frameLock.unlock()
        handler?()
    }

    #if DEBUG
    func publishVerificationFrame(_ image: CIImage) { publishFrame(image) }
    #endif

    func frameForDisplay(after revision: UInt64?) -> (image: CIImage?, revision: UInt64, decodedAt: Double)? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard revision != frameRevision else { return nil }
        return (latestFrame, frameRevision, frameDecodedAt)
    }

    private var h264FormatDesc: CMVideoFormatDescription?
    private var h264ConfigData: Data?
    private var decompressionSession: VTDecompressionSession?
    private var h264Pts = CMTime(value: 0, timescale: 600)
    private let perf = StreamPerformance("mac.decode")
    private let ciContext = CIContext()
    private var enqueueCount = 0

    func setH264Serialized(_ payload: Data) {
        decodeQueue.async { [weak self] in self?.configureH264(payload) }
    }

    private func configureH264(_ payload: Data) {
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
        if let s = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            decompressionSession = nil
        }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: desc, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else {
            DispatchQueue.main.async { [weak self] in self?.diagText = "VTDS:\(status)" }
            return
        }
        decompressionSession = session
        h264FormatDesc = desc
        h264ConfigData = fdData
        h264Pts = CMTime(value: 0, timescale: 600)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        DispatchQueue.main.async { [weak self] in
            self?.diagText = "H264 OK \(dims.width)x\(dims.height)"
        }
    }

    func decodeFrame(_ data: Data) {
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        perf.interval("receiveInterval", at: enqueuedAt)
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.perf.record("dispatchWait", milliseconds: (ProcessInfo.processInfo.systemUptime - enqueuedAt) * 1000)
            self.decodeH264(data)
        }
    }

    private func decodeH264(_ annexBData: Data) {
        guard let desc = h264FormatDesc, let session = decompressionSession else { return }
        let avcc = Self.annexBToAVCC(annexBData)
        guard !avcc.isEmpty else { return }
        feedH264(data: avcc, formatDesc: desc, session: session)
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
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

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
        guard let sampleBuffer else { return }

        h264Pts = CMTimeAdd(h264Pts, CMTime(value: 1, timescale: 60))

        let decodeStart = ProcessInfo.processInfo.systemUptime
        perf.record("submitted", bytes: data.count)
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self, status == noErr, let imageBuffer else {
                if status != noErr {
                    DispatchQueue.main.async { self?.diagText = "解码err:\(status)" }
                }
                return
            }
            self.perf.interval("decodeCallbackInterval")
            self.perf.record("decoded", milliseconds: (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000)
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            self.publishFrame(ciImage)
            self.frameLock.lock()
            self.enqueueCount += 1
            let count = self.enqueueCount
            self.frameLock.unlock()
            #if DEBUG
            if self.onImageUpdate != nil,
               let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let image = NSImage(cgImage: cgImage, size: ciImage.extent.size)
                DispatchQueue.main.async { self.onImageUpdate?(image) }
            }
            #endif
            if count == 1 || count % 60 == 0 {
                DispatchQueue.main.async {
                    self.diagText = "H264 帧:\(count) \(Int(ciImage.extent.width))x\(Int(ciImage.extent.height))"
                }
            }
        }
    }


    func reset() {
        decodeQueue.async { [weak self] in self?.resetDecoder() }
    }

    private func resetDecoder() {
        if let s = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            decompressionSession = nil
        }
        h264FormatDesc = nil
        h264ConfigData = nil
        publishFrame(nil)
        frameLock.lock()
        enqueueCount = 0
        frameLock.unlock()
        h264Pts = CMTime(value: 0, timescale: 600)
        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            self?.onImageUpdate?(nil)
            #endif
            self?.diagText = "等待画面"
        }
    }
}

final class MacReceiverClient: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, connected, failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var frameCount: Int = 0
    private var receivedFrames = 0
    let decoder = MacReceiverDecoder()

    private var nativePeer: NativeVideoPeer?
    private var nativeRoom: NativeVideoRoom?
    private var internetDirect = false
    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var expectedPayloadLength: Int?
    private var expectedType: UInt8?
    private let netQueue = DispatchQueue.main
    private var connectionTimeout: DispatchWorkItem?
    private var lastDataAt = Date()
    private var isDisconnecting = false
    private var lastHost: String?
    private var lastPort: UInt16?
    private var lastMatchCode: String?
    private var authenticationCode: String?
    var discoveryLookup: ((String) -> (String, UInt16)?)?

    private static let maxMessageLength = 8 * 1024 * 1024

    private func configureNativePeer(_ video: NativeVideoPeer) {
        nativePeer = video
        var count = 0
        video.onImage = { [weak self, weak video] image in
            guard let self, video != nil else { return }
            self.decoder.publishFrame(image)
            count += 1
            let number = count
            if number == 1 || number % 30 == 0 {
                DispatchQueue.main.async { [weak self, weak video] in
                    guard let self, self.nativePeer === video else { return }
                    self.receivedFrames = number; self.frameCount = number
                    self.lastDataAt = Date()
                    self.connectionTimeout?.cancel(); self.setStatus(.connected)
                }
            }
        }
        video.onConnected = { [weak self] in self?.connectionTimeout?.cancel(); self?.setStatus(.connected) }
        video.onError = { [weak self] text in self?.disconnect(); self?.setStatus(.failed(text)) }
    }

    func connectInternetCode(_ code: String) {
        disconnect()
        guard MatchingCode.isValid(code) else { setStatus(.failed("请输入 6–36 位数字匹配码")); return }
        isDisconnecting = false
        setStatus(.connecting)
        let room = NativeVideoRoom(code: code)
        nativeRoom = room
        configureNativePeer(room.video)
        room.onConnected = { [weak self] in self?.setStatus(.connected) }
        room.onError = { [weak self] text in self?.disconnect(); self?.setStatus(.failed(text)) }
        room.start()
    }

    func connectInternetIP(host: String, port: UInt16, code: String) {
        disconnect()
        internetDirect = true
        isDisconnecting = false
        lastHost = host; lastPort = port; authenticationCode = code
        startConnection()
    }

    func connect(host: String, port: UInt16, code: String) {
        disconnect()
        isDisconnecting = false
        lastHost = host
        lastPort = port
        authenticationCode = code
        startConnection()
    }

    func connectWithCode(_ code: String) {
        disconnect()
        isDisconnecting = false
        lastMatchCode = code
        authenticationCode = code
        guard let lookup = discoveryLookup, let found = lookup(code) else {
            setStatus(.failed("未找到匹配码对应的投屏流"))
            return
        }
        lastHost = found.0
        lastPort = found.1
        startConnection()
    }

    private func startConnection() {
        guard connection == nil, let host = lastHost, let port = lastPort else { return }
        guard !host.isEmpty, port > 0, MatchingCode.isValid(authenticationCode) else {
            setStatus(.failed("请填写有效地址、端口和 6–36 位数字匹配码"))
            return
        }
        lastDataAt = Date()
        setStatus(.connecting)
        decoder.reset()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: internetDirect ? InternetSettings.tlsParameters(code: authenticationCode!) : .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    DiagLog.log("Receive", "TCP ready \(host):\(port)")
                    self.sendAuthentication()
                    self.sendScreenSize()
                    self.netQueue.async { [weak self] in self?.readLoop(on: connection) }
                case .failed(let error):
                    self.handleDisconnect(connection)
                    self.setStatus(.failed(error.localizedDescription))
                case .cancelled:
                    self.handleDisconnect(connection)
                case .waiting(let error):
                    DiagLog.log("Receive", "TCP waiting \(error.localizedDescription)")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func handleDisconnect(_ disconnectedConnection: NWConnection) {
        guard !isDisconnecting, connection === disconnectedConnection else { return }
        connectionTimeout?.cancel()
        disconnectedConnection.cancel()
        connection = nil
        do {
            self.rxBuffer.removeAll(keepingCapacity: false)
            self.expectedPayloadLength = nil
            self.expectedType = nil
        }
        setStatus(.idle)
    }

    func autoSearch(mode: String, host: String, port: UInt16, code: String) {
        guard mode == "ip" || mode == "code" else { return } // WAN attempts are explicit, never background server polling.
        guard !isDisconnecting, connection == nil else { return }
        switch status {
        case .connected, .connecting:
            return
        default:
            break
        }
        if mode == "code" {
            guard MatchingCode.isValid(code), let lookup = discoveryLookup else { return }
            guard let found = lookup(code) else { return }
            lastMatchCode = code
            authenticationCode = code
            lastHost = found.0
            lastPort = found.1
            startConnection()
        } else {
            guard !host.isEmpty, MatchingCode.isValid(code) else { return }
            authenticationCode = code
            lastHost = host
            lastPort = port
            startConnection()
        }
    }

    func disconnect() {
        nativeRoom?.stop(); nativeRoom = nil
        nativePeer?.stop(); nativePeer = nil
        internetDirect = false
        connectionTimeout?.cancel()
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
            expectedPayloadLength = nil
            expectedType = nil
        }
        frameCount = 0
        receivedFrames = 0
        setStatus(.idle)
        decoder.reset()
    }

    private func setStatus(_ s: Status) {
        DiagLog.log("Receive", "status \(s)")
        status = s
    }

    func checkStaleConnection() {
        if nativePeer != nil { return }
        guard case .connected = status, let conn = connection,
              Date().timeIntervalSince(lastDataAt) > 15 else { return }
        handleDisconnect(conn)
    }

    func setStatus(_ message: String) {
        setStatus(.failed(message))
    }

    private func sendScreenSize() {
        guard let conn = connection, let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let w = UInt32(screen.frame.width * scale)
        let h = UInt32(screen.frame.height * scale)
        var msg = Data()
        var bw = w.bigEndian
        var bh = h.bigEndian
        withUnsafeBytes(of: &bw) { msg.append(contentsOf: $0) }
        withUnsafeBytes(of: &bh) { msg.append(contentsOf: $0) }
        var head = Data()
        var hl = UInt32(msg.count).bigEndian
        withUnsafeBytes(of: &hl) { head.append(contentsOf: $0) }
        head.append(UInt8(2))
        conn.send(content: head + msg, completion: .idempotent)
    }

    private func sendAuthentication() {
        guard let conn = connection,
              let code = authenticationCode,
              MatchingCode.isValid(code) else { return }
        let payload = Data(code.utf8)
        var msg = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { msg.append(contentsOf: $0) }
        msg.append(UInt8(5))
        msg.append(payload)
        conn.send(content: msg, completion: .idempotent)
        let video = NativeVideoPeer(internet: internetDirect)
        configureNativePeer(video)
        video.sendSignal = { [weak conn] object in if let conn { NativeVideo.send(object, over: conn) } }
        NativeVideo.send(["type":"hello", "version":3], over: conn)
    }

    private func readLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.lastDataAt = Date()
                self.rxBuffer.append(data)
                self.parseMessages()
            }
            if let error {
                self.setStatus(.failed(error.localizedDescription))
                DispatchQueue.main.async { [weak self] in self?.handleDisconnect(connection) }
                return
            }
            if isComplete {
                DispatchQueue.main.async { [weak self] in self?.handleDisconnect(connection) }
                return
            }
            self.readLoop(on: connection)
        }
    }

    private func parseMessages() {
        var consumed = 0
        while true {
            let remaining = rxBuffer.count - consumed
            if let expectedPayloadLength, let expectedType {
                guard remaining >= expectedPayloadLength else { break }
                let payload = rxBuffer.copySlice(consumed, expectedPayloadLength)
                consumed += expectedPayloadLength
                self.expectedPayloadLength = nil
                self.expectedType = nil
                handle(type: expectedType, payload: payload)
            } else {
                guard remaining >= 5 else { break }
                let base = consumed
                let length = rxBuffer.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                    guard base + 4 < ptr.count else { return -1 }
                    return Int(ptr.loadUnaligned(fromByteOffset: base, as: UInt32.self).bigEndian)
                }
                guard length > 0, length <= Self.maxMessageLength else {
                    rxBuffer.removeAll(keepingCapacity: false)
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
            if rxBuffer.count > Self.maxMessageLength * 4 {
                rxBuffer.removeAll(keepingCapacity: false)
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
            rxBuffer.removeFirst(consumed)
        }
    }

    private func handle(type: UInt8, payload: Data) {
        switch type {
        case 20:
            if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { nativePeer?.receive(object) }
        case 0, 1:
            disconnect()
            setStatus(.failed("对端仍使用旧视频协议，请将两端更新到原生视频版"))
        case 11:
            if payload.count <= 2048, let line = String(data: payload, encoding: .utf8) {
                PerformanceDisk.shared.write("remote \(line)", forward: false)
            }
        case 7:
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

#if DEBUG
@MainActor enum NativeRoutesVerification {
    /// Moving full-frame content catches starvation that a constant red test cannot.
    static func motion() async {
        let code = MatchingCode.generate()
        let server = CastingServer(port: 19319, accessCode: code)
        server.configureNative(bitrate: 100_000_000, fps: 60)
        var registered = false
        server.onInternetStatus = { if $0.contains("匹配就绪") { registered = true } }
        server.start(); server.setInternetEnabled(true)
        defer { server.stop() }
        for _ in 0..<100 { if registered { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        let client = MacReceiverClient(); client.connectInternetCode(code)
        defer { client.disconnect() }
        var ready = false
        for _ in 0..<350 {
            if case .connected = client.status { ready = true; break }
            if case .failed = client.status { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready else { NSLog("NativeMotion FAIL negotiation status=%@", String(describing: client.status)); return }
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1440)
        let context = CIContext(options: [.cacheIntermediates: false])
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1440,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { return }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<1200 {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { break }
            let image = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputCenter": CIVector(x: CGFloat(index * 13), y: CGFloat(index * 7)),
                "inputWidth": 23, "inputSharpness": 1])!.outputImage!.cropped(to: rect)
            context.render(image, to: pixel)
            server.nativeSource.append(pixel)
            let wait = start + Double(index + 1) / 60 - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } else { await Task.yield() }
            if case .failed = client.status { break }
        }
        let size = client.decoder.frameForDisplay(after: nil)?.image?.extent.size
        NSLog("NativeMotion %@ frames=%ld size=%@ status=%@", client.frameCount >= 900 && size == rect.size ? "PASS" : "FAIL",
              client.frameCount, String(describing: size), String(describing: client.status))
    }

    static func receive() async {
        let client = MacReceiverClient()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacStreamImageView(decoder: client.decoder))
        window.title = "iPad 原生视频接收验证"; window.orderFront(nil)
        MacDiscoveryListener.shared.start()
        client.discoveryLookup = { MacDiscoveryListener.shared.find(code: $0) }
        defer { client.disconnect(); window.orderOut(nil) }
        var connected = false
        for _ in 0..<600 {
            if !connected, MacDiscoveryListener.shared.find(code: "68342719") != nil {
                client.connectWithCode("68342719"); connected = true
            }
            if client.frameCount >= 180 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("NativeDeviceReceive %@ frames=%ld size=%@ status=%@", client.frameCount >= 30 ? "PASS" : "FAIL", client.frameCount, String(describing: client.decoder.frameForDisplay(after: nil)?.image?.extent.size), String(describing: client.status))
    }
    static func run() async {
        let fourK = ProcessInfo.processInfo.arguments.contains("--verify-native-4k")
        let code = MatchingCode.generate()
        let server = CastingServer(port: 19318, accessCode: code)
        server.configureNative(bitrate: 8_000_000, fps: fourK ? 60 : 30)
        server.start()
        defer { server.stop() }
        let width = fourK ? 3840 : 1280, height = fourK ? 2160 : 720
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { return }
        let context = CIContext()
        context.render(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: pixel)
        var registered = false
        server.onInternetStatus = { text in if text.contains("匹配就绪") { registered = true } }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for mode in (fourK ? ["localIP"] : ["localIP", "localCode", "internetIP", "internetCode"]) {
            if mode == "internetIP" { server.setInternetMatchingEnabled(false); server.setInternetEnabled(true) }
            if mode == "internetCode" {
                server.setInternetMatchingEnabled(true)
                for _ in 0..<100 { if registered { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            let client = MacReceiverClient()
            if mode == "localIP" { client.connect(host: "127.0.0.1", port: 19318, code: code) }
            if mode == "localCode" { client.discoveryLookup = { _ in ("127.0.0.1", 19318) }; client.connectWithCode(code) }
            if mode == "internetIP" { client.connectInternetIP(host: "127.0.0.1", port: 20318, code: code) }
            if mode == "internetCode" { client.connectInternetCode(code) }
            for _ in 0..<240 {
                server.nativeSource.append(pixel)
                try? await Task.sleep(nanoseconds: 33_333_333)
                if case .failed = client.status { break }
            }
            let image = client.decoder.frameForDisplay(after: nil)?.image
            var sample = [UInt8](repeating: 0, count: 4)
            if let image { context.render(image, toBitmap: &sample, rowBytes: 4, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            let passed = client.frameCount >= 10 && image?.extent.size == CGSize(width: width, height: height) && sample[0] > 150 && sample[1] < 80
            NSLog("NativeRoutes %@ mode=%@ frames=%ld size=%@ pixel=%@ status=%@", passed ? "PASS" : "FAIL", mode, client.frameCount, String(describing: image?.extent.size), String(describing: sample), String(describing: client.status))
            PerformanceDisk.shared.write("NativeRoutes \(passed ? "PASS" : "FAIL") mode=\(mode) frames=\(client.frameCount) size=\(String(describing: image?.extent.size))")
            if mode == "localIP" && !fourK {
                for _ in 0..<90 { server.nativeSource.append(pixel, orientation: 6); try? await Task.sleep(nanoseconds: 33_333_333) }
                let rotated = client.decoder.frameForDisplay(after: nil)?.image?.extent.size
                NSLog("NativeRotation %@ size=%@", rotated == CGSize(width: 720, height: 1280) ? "PASS" : "FAIL", String(describing: rotated))
            }
            client.disconnect()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
#endif
