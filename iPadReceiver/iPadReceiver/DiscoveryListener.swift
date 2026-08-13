import Foundation
import Network

final class DiscoveryListener {
    static let shared = DiscoveryListener()
    static let udpPort: UInt16 = 8321

    private var listener: NWListener?
    private var entries: [String: (ip: String, port: UInt16)] = [:]
    private var lastSeen: [String: Date] = [:]
    private let queue = DispatchQueue(label: "discovery", qos: .utility)

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
            guard let self, let data, let json = String(data: data, encoding: .utf8) else { return }
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = dict["code"] as? String,
               let port = dict["port"] as? UInt16,
               let remote = conn.endpoint as? NWEndpoint {
                let ip = self.extractIP(from: remote) ?? self.extractIP(from: conn.currentPath?.remoteEndpoint)
                if let ip {
                    self.entries[code] = (ip, port)
                    self.lastSeen[code] = Date()
                }
            }
            self.receive(on: conn)
        }
    }

    private func extractIP(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr.debugDescription
            case .ipv6(let addr):
                return addr.debugDescription
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func find(code: String) -> (ip: String, port: UInt16)? {
        guard let entry = entries[code] else { return nil }
        if let seen = lastSeen[code], Date().timeIntervalSince(seen) > 8 {
            entries.removeValue(forKey: code)
            return nil
        }
        return entry
    }
}
