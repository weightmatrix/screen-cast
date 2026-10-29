import Foundation
import Darwin

final class DiscoveryBroadcaster {
    static let shared = DiscoveryBroadcaster()
    static let udpPort: UInt16 = 8321

    private var socketFd: Int32 = -1
    private var timer: Timer?
    private var entries: [(code: String, port: UInt16)] = []

    func start() {
        guard socketFd < 0 else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        socketFd = fd
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.broadcast()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
    }

    func update(entries: [(code: String, port: UInt16)]) {
        self.entries = entries
        DiagLog.log("Discovery", "broadcast entries \(entries.map { "\($0.code):\($0.port)" }.joined(separator: ","))")
    }

    private func broadcast() {
        guard socketFd >= 0, !entries.isEmpty else { return }
        let ips = CastingServer.localIPInfos
        let destinations = broadcastAddresses()
        for entry in entries {
            let ipArray = ips.map { ["ip": $0.ip, "priority": $0.priority] }
            let object: [String: Any] = [
                "code": entry.code,
                "port": entry.port,
                "ips": ipArray
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { continue }
            for destination in destinations {
              data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = Self.udpPort.bigEndian
                addr.sin_addr.s_addr = destination
                let len = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(socketFd, raw.baseAddress, raw.count, 0, sa, len)
                    }
                }
              }
            }
        }
    }

    private func broadcastAddresses() -> Set<in_addr_t> {
        var result: Set<in_addr_t> = [inet_addr("255.255.255.255")]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return result }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let item = current {
            let interface = item.pointee
            if (interface.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST)) == UInt32(IFF_UP | IFF_BROADCAST),
               let address = interface.ifa_dstaddr, address.pointee.sa_family == sa_family_t(AF_INET) {
                let broadcast = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                result.insert(broadcast.sin_addr.s_addr)
            }
            current = interface.ifa_next
        }
        return result
    }
}
