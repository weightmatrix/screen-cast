import Foundation
import Combine
import Network
import Darwin
import AppKit
import AVFoundation
import CoreMedia
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

    private func publishFrame(_ image: CIImage?) {
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

    private var internetTunnel: InternetTunnel?
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

    func connectInternetCode(_ code: String) {
        disconnect()
        guard MatchingCode.isValid(code) else { setStatus(.failed("请输入 6–36 位数字匹配码")); return }
        isDisconnecting = false
        setStatus(.connecting)
        let tunnel = InternetTunnel(code: code)
        internetTunnel = tunnel
        tunnel.onReady = { [weak self, weak tunnel] port in
            guard let self, let tunnel, self.internetTunnel === tunnel else { return }
            self.lastHost = "127.0.0.1"; self.lastPort = port
            self.authenticationCode = code
            self.startConnection()
        }
        tunnel.onError = { [weak self] text in self?.disconnect(); self?.setStatus(.failed(text)) }
        tunnel.start()
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
        internetTunnel?.stop(); internetTunnel = nil
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
        case 0:
            guard payload.count >= 5 else { break }
            let codec = payload[0]
            DiagLog.log("Receive", "config codec=\(codec) bytes=\(payload.count)")
            if codec == 3 {
                connectionTimeout?.cancel()
                setStatus(.connected)
                decoder.setH264Serialized(payload.dropFirst(1))
            }
        case 1:
            decoder.decodeFrame(payload)
            receivedFrames += 1
            if receivedFrames == 1 || receivedFrames % 30 == 0 { frameCount = receivedFrames }
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
