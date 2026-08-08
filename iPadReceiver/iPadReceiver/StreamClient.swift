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

    private static let maxMessageLength = 8 * 1024 * 1024

    func connect(host: String, port: UInt16) {
        disconnect()
        setStatus(.connecting)
        decoder.reset()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.setStatus(.connected)
                    self.sendScreenSize()
                    self.netQueue.async { [weak self] in self?.readLoop() }
                case .failed(let error):
                    self.setStatus(.failed(error.localizedDescription))
                case .cancelled:
                    if self.connection === connection, self.status != .idle {
                        self.setStatus(.idle)
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: netQueue)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func disconnect() {
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

    private func readLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.parseMessages()
            }
            if let error {
                self.setStatus(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.setStatus(.idle)
                return
            }
            self.readLoop()
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
