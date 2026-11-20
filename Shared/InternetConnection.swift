import Foundation
import Network
import Security
import CryptoKit
import WebRTC
import Combine
import Darwin

/// Sender password is kept in the app's private Keychain, never in invitation URLs or defaults.
enum ConnectionPasswordStore {
    private static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"Han.touping.connection-password", kSecAttrAccount as String:"sender"] }
    static func read() -> String {
        var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

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

/// Bounded, best-effort lifecycle and sender admission reports. No media and no background retry loop.
final class DirectConnectionAudit {
    let sessionID: String
    private let role: String
    private let route: String
    private var connectedAt: TimeInterval?
    private var events = Set<String>()
    private let eventLock = NSLock()
    private static let slotLock = NSLock()
    private static var active = 0
    private static func reserve() -> Bool {
        slotLock.lock(); defer { slotLock.unlock() }
        guard active < 16 else { return false }; active += 1; return true
    }
    private static func release() { slotLock.lock(); active -= 1; slotLock.unlock() }
    init(sessionID: String? = nil, sending: Bool, route: String = "internet_ip") {
        self.route = route
        self.sessionID = sessionID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        role = sending ? "sender" : "receiver"
        record("attempt")
    }
    func record(_ event: String) {
        eventLock.lock(); defer { eventLock.unlock() }
        guard ["attempt", "approved", "rejected", "connected", "ended"].contains(event), events.insert(event).inserted else { return }
        guard Self.reserve() else { PerformanceDisk.shared.write("audit.direct report_capacity_reached"); return }
        if event == "connected" { connectedAt = ProcessInfo.processInfo.systemUptime }
        var packet: [String: Any] = ["role": "audit", "route": route, "session_id": sessionID,
                                    "peer_role": role, "event": event, "device": DeviceAuditMetadata.value]
        if role == "sender" { packet["access_token"] = CastAccount.accessToken }
        if event == "ended", let connectedAt { packet["duration_ms"] = Int((ProcessInfo.processInfo.systemUptime - connectedAt) * 1000) }
        let report = packet
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
                var authenticatedReport = report
                if role == "sender" { authenticatedReport["access_token"] = await CastAccount.validAccessToken() }
                let data = try JSONSerialization.data(withJSONObject: authenticatedReport)
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
        case .localCode: return "局域邀请"
        case .internetIP: return "公网地址"
        case .internetCode: return "公网邀请"
        }
    }
}

enum InternetSettings {
    static func browserAddress(code: String) -> String { "https://zhibenwang.com/touping/#invite=\(code)" }
    static func localBrowserAddress(ip: String, port: UInt16, code: String) -> String { "http://\(ip):\(port)/#invite=\(code)" }
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
        let key = Data(SHA256.hash(data: Data(("touping-tls-v1:" + code.precomposedStringWithCanonicalMapping).utf8)))
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("touping-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// Uses the scheduling service's JWTs; credentials stay in the platform Keychain.
final class CastAccount: ObservableObject {
    static let shared = CastAccount()
    @Published var loggedIn = false
    @Published var nickname = ""
    @Published var matchingCode = ""
    @Published var membership = ""
    @Published var message = ""
    @Published var busy = false
    @Published var roles: [String] = []
    static var accessToken: String {
        let token: String
        #if os(iOS)
        if Bundle.main.bundleURL.pathExtension == "appex" { token = BroadcastSettings.store.string(forKey: "account.access") ?? "" }
        else { token = shared.tokens()["access"] ?? "" }
        #else
        token = shared.tokens()["access"] ?? ""
        #endif
        // This only detects expiry locally. The server verifies JWT signatures and account status.
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return "" }
        var encoded = String(parts[1]).replacingOccurrences(of:"-", with:"+").replacingOccurrences(of:"_", with:"/")
        encoded += String(repeating:"=", count:(4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded:encoded), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let expires = object["exp"] as? Double, expires > Date().timeIntervalSince1970 else { return "" }
        return token
    }
    private let base = URL(string: "https://zhibenwang.com/api/")!
    private var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"Han.touping.account", kSecAttrAccount as String:"jwt"] }
    private func tokens() -> [String: String] {
        #if os(iOS)
        let sharedRefresh = BroadcastSettings.store.string(forKey:"account.refresh") ?? ""
        if Bundle.main.bundleURL.pathExtension == "appex" || !sharedRefresh.isEmpty {
            return ["access":BroadcastSettings.store.string(forKey:"account.access") ?? "", "refresh":sharedRefresh]
        }
        #endif
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data,
              let result = try? JSONDecoder().decode([String:String].self, from: data) else { return [:] }
        return result
    }
    private func saveTokens(_ values: [String: String]) throws {
        #if os(iOS)
        if Bundle.main.bundleURL.pathExtension == "appex" {
            guard BroadcastSettings.store.set(values["access"] ?? "", forKey:"account.access"),
                  BroadcastSettings.store.set(values["refresh"] ?? "", forKey:"account.refresh") else { throw URLError(.cannotWriteToFile) }
            return
        }
        #endif
        let data = try JSONEncoder().encode(values)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
        } else if status != errSecSuccess { throw URLError(.cannotWriteToFile) }
        #if os(iOS)
        BroadcastSettings.store.set(values["access"] ?? "", forKey:"account.access")
        BroadcastSettings.store.set(values["refresh"] ?? "", forKey:"account.refresh")
        #endif
    }
    private func request(_ path: String, method: String = "GET", body: [String:String]? = nil, authenticated: Bool = true) async throws -> (Int, [String:Any]) {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { request.setValue("Bearer " + CastAccount.accessToken, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 65536, let response = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw URLError(.badServerResponse) }
        return (response.statusCode, object)
    }
    static var hasSession: Bool { !accessToken.isEmpty || !(shared.tokens()["refresh"] ?? "").isEmpty }
    @MainActor static func validAccessToken() async -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while shared.busy && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        guard !shared.busy else { return "" }
        if !accessToken.isEmpty { return accessToken }
        guard !(shared.tokens()["refresh"] ?? "").isEmpty else { return "" }
        await shared.restore()
        return accessToken
    }
    static func verifySender() async -> Bool {
        guard !(await validAccessToken()).isEmpty else { return false }
        do {
            let result = try await shared.request("auth/me/")
            return result.0 == 200 && result.1["id"] is String
        } catch { return false }
    }
    static func relayConfiguration() async -> [String:Any]? {
        guard !(await validAccessToken()).isEmpty else { return nil }
        do {
            let result = try await shared.request("touping/relay/", method:"POST", body:[:])
            return result.0 == 200 ? result.1 : nil
        } catch { return nil }
    }
    @MainActor func login(phone: String, password: String, role: String, otp: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let (status, object) = try await request("token/", method: "POST", body: ["phone":phone, "password":password, "role":role, "otp":otp], authenticated: false)
            if status == 409, let accounts = object["accounts"] as? [[String:Any]] {
                roles = accounts.compactMap { $0["role"] as? String }; message = "请选择账号身份后重新登录"; return
            }
            guard status == 200, let access = object["access"] as? String, let refresh = object["refresh"] as? String else {
                message = object["detail"] as? String ?? (status == 428 ? "请输入管理账号动态口令" : "登录失败"); return
            }
            try saveTokens(["access":access, "refresh":refresh]); try await loadProfile(); message = "已登录"
        } catch { message = "登录失败，请检查网络或稍后重试" }
    }
    @MainActor private func loadProfile() async throws {
        var result = try await request("touping/profile/")
        if result.0 == 401, let refresh = tokens()["refresh"] {
            let renewed = try await request("token/refresh/", method: "POST", body: ["refresh":refresh], authenticated: false)
            if renewed.0 == 200, let access = renewed.1["access"] as? String {
                try saveTokens(["access":access,"refresh":renewed.1["refresh"] as? String ?? refresh])
                result = try await request("touping/profile/")
            }
        }
        guard result.0 == 200 else { throw URLError(.userAuthenticationRequired) }
        apply(result.1)
    }
    @MainActor private func apply(_ object: [String:Any]) {
        loggedIn = true; nickname = object["nickname"] as? String ?? ""; matchingCode = object["matching_code"] as? String ?? ""; membership = object["membership"] as? String ?? ""
        if !nickname.isEmpty {
            UserDefaults.standard.set(nickname, forKey:"room.nickname"); RoomSession.shared.refreshNickname()
        }
        if !matchingCode.isEmpty {
            UserDefaults.standard.set(matchingCode, forKey:"lastCode")
            #if os(iOS)
            BroadcastSettings.store.set(matchingCode, forKey:"broadcastCode")
            #endif
        }
    }
    @MainActor func restore() async {
        guard !tokens().isEmpty, !busy else { return }; busy = true; defer { busy = false }
        #if os(iOS)
        if Bundle.main.bundleURL.pathExtension != "appex" {
            let existing = tokens()
            BroadcastSettings.store.set(existing["access"] ?? "", forKey:"account.access")
            BroadcastSettings.store.set(existing["refresh"] ?? "", forKey:"account.refresh")
        }
        #endif
        do { try await loadProfile() } catch { message = "登录已过期或账号服务暂不可用，请重新登录" }
    }
    @MainActor func update() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let (status, object) = try await request("touping/profile/", method:"PATCH", body:["nickname":nickname,"matching_code":matchingCode])
            guard status == 200 else { message = object["error"] as? String ?? "保存失败，请重新登录后重试"; return }
            apply(object); message = "已保存；新的投屏任务使用绑定码，已有任务保持原码"
        } catch { message = "保存失败，请稍后重试" }
    }
    @MainActor func logout() {
        #if os(iOS)
        BroadcastSettings.store.set("", forKey:"account.access")
        BroadcastSettings.store.set("", forKey:"account.refresh")
        #endif
        SecItemDelete(query as CFDictionary); loggedIn = false; nickname = ""; matchingCode = ""; membership = ""; message = "已退出"; roles = []
    }
}
