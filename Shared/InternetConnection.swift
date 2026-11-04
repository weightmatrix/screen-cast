import Foundation
import Network
import Security
import CryptoKit
import WebRTC
import Combine
import Darwin

/// App-instance identity, not a hardware identifier or proof of identity.
enum DeviceAuditMetadata {
    static let value: [String: String] = {
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: "auditInstallationID") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(identifier, forKey: "auditInstallationID")
        let platform: String
        let model: String
        #if os(macOS)
        platform = "macOS"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, min(size, 128)))
        model = sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : "unknown"
        #else
        platform = "iPadOS"
        var info = utsname(); uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        model = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ["installation_id": identifier, "platform": platform, "model": model,
                "os_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
    }()
}

/// Three bounded, best-effort lifecycle reports. No media and no background retry loop.
final class DirectConnectionAudit {
    let sessionID: String
    private let role: String
    private var events = Set<String>()
    private let eventLock = NSLock()
    private static let slotLock = NSLock()
    private static var active = 0
    private static func reserve() -> Bool {
        slotLock.lock(); defer { slotLock.unlock() }
        guard active < 16 else { return false }; active += 1; return true
    }
    private static func release() { slotLock.lock(); active -= 1; slotLock.unlock() }
    init(sessionID: String? = nil, sending: Bool) {
        self.sessionID = sessionID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        role = sending ? "sender" : "receiver"
        record("attempt")
    }
    func record(_ event: String) {
        eventLock.lock(); defer { eventLock.unlock() }
        guard ["attempt", "connected", "ended"].contains(event), events.insert(event).inserted else { return }
        guard Self.reserve() else { PerformanceDisk.shared.write("audit.direct report_capacity_reached"); return }
        let packet: [String: Any] = ["role": "audit", "route": "internet_ip", "session_id": sessionID,
                                    "peer_role": role, "event": event, "device": DeviceAuditMetadata.value]
        Task {
            defer { Self.release() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            let socket = session.webSocketTask(with: InternetSettings.auditURL)
            socket.maximumMessageSize = 2048; socket.resume()
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
            do {
                let data = try JSONSerialization.data(withJSONObject: packet)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let response = text.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      object["type"] as? String == "audit_recorded" else { throw URLError(.badServerResponse) }
            } catch { PerformanceDisk.shared.write("audit.direct report_failed event=\(event)") }
        }
    }
}

/// One bounded lookup per conflict, never a background availability poll.
/// The normal sender registration remains the final atomic collision check.
final class MatchingCodeSuggestion: ObservableObject {
    @Published private(set) var code: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    private var conflict: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    func request(for current: String, excluding codes: [String], force: Bool = false) {
        guard force || conflict != current else { return }
        reset(); conflict = current; isLoading = true
        let token = generation
        let allExcluded = Set([current] + codes)
        let excluded = [current] + Array(Set(codes).subtracting([current])).prefix(31)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: InternetSettings.signalingURL)
        self.socket = socket; socket.maximumMessageSize = 2048; socket.resume()
        task = Task { @MainActor [weak self] in
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
            do {
                let packet: [String: Any] = ["role": "suggest", "exclude": excluded.map(InternetSettings.room)]
                let data = try JSONSerialization.data(withJSONObject: packet)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                let reply = try await socket.receive()
                let result: Data
                switch reply {
                case .data(let value): result = value
                case .string(let value): result = Data(value.utf8)
                @unknown default: throw URLError(.badServerResponse)
                }
                guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
                      object["type"] as? String == "suggestion", let candidate = object["code"] as? String,
                      MatchingCode.isValid(candidate), !allExcluded.contains(candidate) else { throw URLError(.badServerResponse) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.code = candidate; self.isLoading = false
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.isLoading = false; self.errorText = "获取建议码失败，请重试"
            }
        }
    }

    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        code = nil; errorText = nil; isLoading = false; conflict = nil
    }

    deinit { task?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case localIP = "ip", localCode = "code", internetIP = "wanIP", internetCode = "wanCode"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .localIP: return "局域 IP 直连"
        case .localCode: return "局域匹配码"
        case .internetIP: return "广域网 IP 直连"
        case .internetCode: return "广域网匹配码"
        }
    }
}

enum InternetSettings {
    static func browserAddress(code: String) -> String { "https://zhibenwang.com/touping/#code=\(code)" }
    static func localBrowserAddress(ip: String, port: UInt16, code: String) -> String { "http://\(ip):\(port)/#code=\(code)" }
    static let signalingURL = URL(string: "wss://zhibenwang.com/touping/signal")!
    static let auditURL = URL(string: "wss://zhibenwang.com/touping/audit")!
    static let stunURL = "stun:67.216.201.61:3478"
    static func room(_ code: String) -> String { SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func tlsParameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let key = Data(SHA256.hash(data: Data(("touping-tls-v1:" + code).utf8)))
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("touping-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}
