import Foundation
import Combine
import Network

final class CastingServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0
    @Published private(set) var lastError: String?

    var port: UInt16 = 8318
    var onNewClient: (() -> Void)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var pendingSends: [ObjectIdentifier: Int] = [:]
    private var lastConfig: Data?

    var localIPs: [String] { Self.currentIPs() }

    @Published private(set) var remoteScreenSize: (width: Int, height: Int)?

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                    case .failed(let error):
                        self.lastError = error.localizedDescription
                        self.isRunning = false
                        self.listener = nil
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        pendingSends.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        clientCount = 0
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.drop(connection)
            }
        }
        connection.start(queue: .main)
        connections.append(connection)
        clientCount = connections.count
        if let config = lastConfig {
            send(type: 0, payload: config, to: connection)
        }
        readResolution(from: connection)
        onNewClient?()
    }

    private func readResolution(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 13) { [weak self] data, _, _, _ in
            guard let self, let data, data.count >= 5 else { return }
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian })
            let type = data[4]
            guard type == 2, length == 8, data.count >= 13 else { return }
            let w = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self).bigEndian })
            let h = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: UInt32.self).bigEndian })
            DispatchQueue.main.async { self.remoteScreenSize = (w, h) }
        }
    }

    private func drop(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        clientCount = connections.count
        pendingSends[ObjectIdentifier(connection)] = nil
    }

    func sendConfig(codec: UInt8, parameterSets: [Data]) {
        var payload = Data()
        payload.append(codec)
        for ps in parameterSets {
            payload.append(uint32: ps.count)
            payload.append(ps)
        }
        DispatchQueue.main.async {
            self.lastConfig = payload
            self.broadcast(type: 0, payload: payload)
        }
    }

    func sendFrame(_ data: Data, isKey: Bool) {
        DispatchQueue.main.async {
            self.broadcast(type: 1, payload: data)
        }
    }

    private func broadcast(type: UInt8, payload: Data) {
        for connection in connections {
            send(type: type, payload: payload, to: connection)
        }
    }

    private func send(type: UInt8, payload: Data, to connection: NWConnection) {
        var message = Data()
        message.append(uint32: payload.count)
        message.append(type)
        message.append(payload)
        let key = ObjectIdentifier(connection)
        let pending = pendingSends[key] ?? 0
        guard pending < 8 else { return }
        pendingSends[key] = pending + 1
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            DispatchQueue.main.async {
                self?.pendingSends[key] = max(0, (self?.pendingSends[key] ?? 1) - 1)
            }
        })
    }

    static func currentIPs() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET),
               (interface.ifa_flags & UInt32(IFF_UP)) != 0,
               (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: host)
                    if !name.hasPrefix("127.") {
                        addresses.append(name)
                    }
                }
            }
            pointer = interface.ifa_next
        }
        freeifaddrs(ifaddr)
        return addresses
    }
}

private extension Data {
    mutating func append(uint32: Int) {
        var value = UInt32(uint32).bigEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &value) { Array($0) })
    }
}