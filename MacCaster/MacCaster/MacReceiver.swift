import Foundation
import Combine
import Network
import AppKit
import AVFoundation
import CoreMedia
import VideoToolbox

final class MacDiscoveryListener {
    static let shared = MacDiscoveryListener()
    static let udpPort: UInt16 = 8321

    private var listener: NWListener?
    private var entries: [String: (ip: String, port: UInt16)] = [:]
    private var lastSeen: [String: Date] = [:]
    private let queue = DispatchQueue(label: "macdiscovery", qos: .utility)

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: Self.udpPort)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .main)
                self?.receive(on: conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data,
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = dict["code"] as? String,
               let portNumber = dict["port"] as? NSNumber,
               portNumber.intValue > 0,
               portNumber.intValue <= Int(UInt16.max),
               let ip = self.extractIP(from: conn.currentPath?.remoteEndpoint) {
                let port = UInt16(portNumber.intValue)
                self.entries[code] = (ip, port)
                self.lastSeen[code] = Date()
            }
            self.receive(on: conn)
        }
    }

    private func extractIP(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr):
                return addr.debugDescription
            case .ipv6(let addr):
                return addr.debugDescription
            default:
                return nil
            }
        }
        return nil
    }

    func find(code: String) -> (ip: String, port: UInt16)? {
        queue.sync {
            guard let entry = entries[code] else { return nil }
            if let seen = lastSeen[code], Date().timeIntervalSince(seen) > 8 {
                entries.removeValue(forKey: code)
                lastSeen.removeValue(forKey: code)
                return nil
            }
            return entry
        }
    }
}

final class MacReceiverDecoder: ObservableObject {
    @Published var diagText = "等待画面"
    @Published var isH264 = false

    var onImageUpdate: ((NSImage?) -> Void)?

    private var frameCount = 0
    private var h264FormatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var h264Pts = CMTime(value: 0, timescale: 600)
    private let ciContext = CIContext()
    private var enqueueCount = 0

    func setH264Serialized(_ payload: Data) {
        guard payload.count >= 5 else { return }
        let fdLen = Int(payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        let fdData = payload.copySlice(4, fdLen)
        guard !fdData.isEmpty else { return }
        guard let desc = deserializeFormatDescription(fdData) else {
            DispatchQueue.main.async { [weak self] in self?.diagText = "FD反序列化失败" }
            return
        }
        if let s = decompressionSession { VTDecompressionSessionInvalidate(s); decompressionSession = nil }
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
        h264Pts = CMTime(value: 0, timescale: 600)
        frameCount = 0
        isH264 = true
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        DispatchQueue.main.async { [weak self] in
            self?.diagText = "H264 OK \(dims.width)x\(dims.height)"
        }
    }

    func decodeFrame(_ data: Data) {
        if isH264 {
            decodeH264(data)
        } else {
            decodeJPEG(data)
        }
    }

    private func decodeJPEG(_ data: Data) {
        guard let img = NSImage(data: data) else { return }
        frameCount += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onImageUpdate?(img)
            if self.frameCount % 60 == 0 {
                self.diagText = "JPEG 帧:\(self.frameCount)"
            }
        }
    }

    private func decodeH264(_ annexBData: Data) {
        guard let desc = h264FormatDesc, let session = decompressionSession else { return }
        let avcc = Self.annexBToAVCC(annexBData)
        guard !avcc.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.feedH264(data: avcc, formatDesc: desc, session: session)
        }
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

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self, status == noErr, let imageBuffer else {
                if status != noErr {
                    DispatchQueue.main.async { self?.diagText = "解码err:\(status)" }
                }
                return
            }
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.enqueueCount += 1
            DispatchQueue.main.async {
                self.onImageUpdate?(img)
                if self.enqueueCount == 1 || self.enqueueCount % 60 == 0 {
                    self.diagText = "H264 帧:\(self.enqueueCount) \(cgImage.width)x\(cgImage.height)"
                }
            }
        }
    }

    private func deserializeFormatDescription(_ data: Data) -> CMVideoFormatDescription? {
        var desc: CMFormatDescription?
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: nil,
                bigEndianImageDescriptionData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: data.count,
                stringEncoding: 0,
                flavor: .isoFamily,
                formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { return nil }
        return desc
    }

    func reset() {
        if let s = decompressionSession { VTDecompressionSessionInvalidate(s); decompressionSession = nil }
        isH264 = false
        h264FormatDesc = nil
        frameCount = 0
        enqueueCount = 0
        h264Pts = CMTime(value: 0, timescale: 600)
        DispatchQueue.main.async { [weak self] in
            self?.onImageUpdate?(nil)
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
    let decoder = MacReceiverDecoder()

    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var expectedPayloadLength: Int?
    private var expectedType: UInt8?
    private let netQueue = DispatchQueue(label: "mac.receiver.net")
    private var isDisconnecting = false
    private var lastHost: String?
    private var lastPort: UInt16?
    private var lastMatchCode: String?
    var discoveryLookup: ((String) -> (String, UInt16)?)?

    private static let maxMessageLength = 8 * 1024 * 1024

    func connect(host: String, port: UInt16) {
        disconnect()
        isDisconnecting = false
        lastHost = host
        lastPort = port
        startConnection()
    }

    func connectWithCode(_ code: String) {
        disconnect()
        isDisconnecting = false
        lastMatchCode = code
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
        setStatus(.connecting)
        decoder.reset()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.setStatus(.connected)
                    self.sendScreenSize()
                    self.netQueue.async { [weak self] in self?.readLoop(on: connection) }
                case .failed:
                    self.handleDisconnect(connection)
                case .cancelled:
                    self.handleDisconnect(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: netQueue)
    }

    private func handleDisconnect(_ disconnectedConnection: NWConnection) {
        guard !isDisconnecting, connection === disconnectedConnection else { return }
        connection = nil
        netQueue.async {
            self.rxBuffer.removeAll(keepingCapacity: false)
            self.expectedPayloadLength = nil
            self.expectedType = nil
        }
        setStatus(.idle)
    }

    func autoSearch(mode: String, host: String, port: UInt16, code: String) {
        guard !isDisconnecting, connection == nil else { return }
        switch status {
        case .connected, .connecting:
            return
        default:
            break
        }
        if mode == "code" {
            guard code.count == 4, let lookup = discoveryLookup else { return }
            guard let found = lookup(code) else { return }
            lastMatchCode = code
            lastHost = found.0
            lastPort = found.1
            startConnection()
        } else {
            guard !host.isEmpty else { return }
            lastHost = host
            lastPort = port
            startConnection()
        }
    }

    func disconnect() {
        isDisconnecting = true
        lastHost = nil
        lastPort = nil
        lastMatchCode = nil
        let conn = connection
        connection = nil
        conn?.cancel()
        netQueue.sync {
            rxBuffer.removeAll(keepingCapacity: false)
            expectedPayloadLength = nil
            expectedType = nil
        }
        frameCount = 0
        setStatus(.idle)
        decoder.reset()
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = s
        }
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

    private func readLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
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
            if codec == 3 {
                decoder.setH264Serialized(payload.dropFirst(1))
            }
        case 1:
            decoder.decodeFrame(payload)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.frameCount += 1
            }
        default:
            break
        }
    }
}

extension Data {
    func copySlice(_ offset: Int, _ length: Int) -> Data {
        guard offset >= 0, length > 0, offset + length <= count else { return Data() }
        return withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return Data() }
            return Data(bytes: base.advanced(by: offset), count: length)
        }
    }
}
