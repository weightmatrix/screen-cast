import Foundation
import Combine
import Network

final class CastingServer: ObservableObject {
    let port: UInt16
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    var onClientCountChanged: ((Int) -> Void)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var clientResolutions: [ObjectIdentifier: (Int, Int)] = [:]
    private var pendingSends: [ObjectIdentifier: Int] = [:]
    private var lastConfig: Data?

    var maxRemoteResolution: (width: Int, height: Int)? {
        let vals = clientResolutions.values
        guard !vals.isEmpty else { return nil }
        let maxW = vals.map(\.0).max()!
        let maxH = vals.map(\.1).max()!
        return (maxW, maxH)
    }

    static var localIPs: [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let iface = current.pointee
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (iface.ifa_flags & UInt32(IFF_UP)) != 0, (iface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: host)
                    if !name.hasPrefix("127.") { addresses.append(name) }
                }
            }
            pointer = iface.ifa_next
        }
        freeifaddrs(ifaddr)
        return addresses
    }

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready: self.isRunning = true
                    case .failed(let e): self.lastError = e.localizedDescription; self.isRunning = false; self.listener = nil
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        pendingSends.removeAll()
        clientResolutions.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        DispatchQueue.main.async { [weak self] in self?.onClientCountChanged?(0) }
    }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.drop(conn) }
        }
        conn.start(queue: .main)
        connections.append(conn)
        DispatchQueue.main.async { [weak self] in self?.onClientCountChanged?(self?.connections.count ?? 0) }
        if let config = lastConfig {
            send(type: 0, payload: config, to: conn)
        }
        readResolution(from: conn)
    }

    private func drop(_ conn: NWConnection) {
        connections.removeAll { $0 === conn }
        pendingSends[ObjectIdentifier(conn)] = nil
        clientResolutions[ObjectIdentifier(conn)] = nil
        DispatchQueue.main.async { [weak self] in self?.onClientCountChanged?(self?.connections.count ?? 0) }
    }

    private func readResolution(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 13) { [weak self] data, _, _, _ in
            guard let self, let data, data.count >= 5 else { return }
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian })
            let type = data[4]
            guard type == 2, length == 8, data.count >= 13 else { return }
            let w = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self).bigEndian })
            let h = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: UInt32.self).bigEndian })
            self.clientResolutions[ObjectIdentifier(conn)] = (w, h)
        }
    }

    func sendConfig(_ serializedFD: Data) {
        var payload = Data()
        payload.append(UInt8(3))
        payload.append(uint32: serializedFD.count)
        payload.append(serializedFD)
        DispatchQueue.main.async {
            self.lastConfig = payload
            self.broadcast(type: 0, payload: payload)
        }
    }

    func sendFrame(_ data: Data) {
        DispatchQueue.main.async { self.broadcast(type: 1, payload: data) }
    }

    private func broadcast(type: UInt8, payload: Data) {
        for conn in connections { send(type: type, payload: payload, to: conn) }
    }

    private func send(type: UInt8, payload: Data, to conn: NWConnection) {
        var msg = Data()
        msg.append(uint32: payload.count)
        msg.append(type)
        msg.append(payload)
        let key = ObjectIdentifier(conn)
        let pending = pendingSends[key] ?? 0
        guard pending < 8 else { return }
        pendingSends[key] = pending + 1
        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
            DispatchQueue.main.async {
                self?.pendingSends[key] = max(0, (self?.pendingSends[key] ?? 1) - 1)
            }
        })
    }
}

private extension Data {
    mutating func append(uint32: Int) {
        var v = UInt32(uint32).bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
