import Foundation
import CryptoKit
import Darwin

enum LocalBonjour {
    static let type = "_touping._tcp"
    static func prefix(_ code: String) -> String {
        "tp-" + SHA256.hash(data: Data(code.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + "-"
    }
    static func name(code: String, port: UInt16) -> String { prefix(code) + String(port) }
}

/// Fixed Bonjour service type; no restricted raw multicast/broadcast on iOS.
final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = BonjourDiscovery()
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var resolving = Set<String>()
    private var resolvedAt: [String: Date] = [:]
    private let lock = NSLock()
    private var endpoints: [String: (ip: String, port: UInt16)] = [:]

    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.start() }; return }
        guard browser == nil else { return }
        let browser = NetServiceBrowser(); self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: LocalBonjour.type + ".", inDomain: "local.")
    }
    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.stop() }; return }
        browser?.stop(); browser = nil
        services.values.forEach { $0.stop() }; services.removeAll()
        resolving.removeAll(); resolvedAt.removeAll()
        lock.lock(); endpoints.removeAll(); lock.unlock()
    }
    func find(code: String) -> (ip: String, port: UInt16)? {
        let prefix = LocalBonjour.prefix(code)
        lock.lock()
        let result = endpoints.keys.sorted().first(where: { $0.hasPrefix(prefix) }).flatMap { endpoints[$0] }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.start()
            for (name, service) in self.services where name.hasPrefix(prefix) {
                if Date().timeIntervalSince(self.resolvedAt[name] ?? .distantPast) > 5 { self.resolve(service) }
            }
        }
        return result
    }
    private func resolve(_ service: NetService) {
        guard resolving.insert(service.name).inserted else { return }
        service.delegate = self; service.resolve(withTimeout: 3)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name.hasPrefix("tp-"), services.count < 64 else { return }
        services[service.name] = service; resolve(service)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: service.name)?.stop()
        resolving.remove(service.name); resolvedAt.removeValue(forKey: service.name)
        lock.lock(); endpoints.removeValue(forKey: service.name); lock.unlock()
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.remove(sender.name); resolvedAt[sender.name] = Date()
        guard services[sender.name] === sender, let port = UInt16(exactly: sender.port), port > 0 else { return }
        let addresses = (sender.addresses ?? []).compactMap { data -> (String, Int)? in
            data.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr>.size, let base = raw.baseAddress else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(raw.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return (String(cString: host), address.pointee.sa_family == UInt8(AF_INET) ? 0 : 1)
            }
        }.sorted { $0.1 < $1.1 }
        guard let address = addresses.first else { return }
        lock.lock(); endpoints[sender.name] = (address.0, port); lock.unlock()
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender.name)
        lock.lock(); endpoints.removeValue(forKey: sender.name); lock.unlock()
    }
}
