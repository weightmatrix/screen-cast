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
    let decoder = ImageDecoder()

    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var expectedPayloadLength: Int?
    private var expectedType: UInt8?
    private let netQueue = DispatchQueue(label: "com.witten.touping.net")
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
        UIApplication.shared.isIdleTimerDisabled = true
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
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func sendScreenSize() {
        guard let conn = connection else { return }
        let bounds = UIScreen.main.bounds
        let w = UInt32(bounds.width * UIScreen.main.scale)
        let h = UInt32(bounds.height * UIScreen.main.scale)
        var msg = Data()
        msg.append(contentsOf: w.bigEndian.bytes)
        msg.append(contentsOf: h.bigEndian.bytes)
        var head = Data()
        head.append(uint32: msg.count)
        head.append(UInt8(2))
        conn.send(content: head + msg, completion: .idempotent)
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = s
        }
    }

    func setStatus(_ message: String) {
        setStatus(.failed(message))
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
            } else if codec == 0 {
                decoder.setH264Config(sps: Data(), pps: Data())
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
    mutating func append(uint32: Int) {
        var v = UInt32(uint32).bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func copySlice(_ offset: Int, _ length: Int) -> Data {
        guard offset >= 0, length > 0, offset + length <= count else { return Data() }
        return withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return Data() }
            return Data(bytes: base.advanced(by: offset), count: length)
        }
    }
}

extension UInt32 {
    var bytes: [UInt8] {
        var v = bigEndian
        return Swift.withUnsafeBytes(of: &v) { Array($0) }
    }
}
