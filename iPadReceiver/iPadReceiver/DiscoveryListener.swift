import Foundation
import Darwin

final class DiscoveryListener {
    static let shared = DiscoveryListener()
    static let udpPort: UInt16 = 8321

    private var socketFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var entries: [String: (ip: String, port: UInt16, priority: Int)] = [:]
    private var lastSeen: [String: Date] = [:]
    private let queue = DispatchQueue(label: "discovery", qos: .utility)

    func start() {
        guard socketFd < 0 else { return }
        ConnectionDiag.shared.log("discovery start udp=\(Self.udpPort)")

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            ConnectionDiag.shared.log("discovery socket create failed errno=\(errno)")
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
            ConnectionDiag.shared.log("discovery bind failed errno=\(errno)")
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
        ConnectionDiag.shared.log("discovery started")
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
        ConnectionDiag.shared.log("discovery recv code=\(code) \(bestIP):\(port) priority=\(bestPriority)")
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
                ConnectionDiag.shared.log("discovery expired code=\(code)")
                return nil
            }
            ConnectionDiag.shared.log("discovery hit code=\(code) \(entry.0):\(entry.1) priority=\(entry.2)")
            return (entry.0, entry.1)
        }
    }
}
