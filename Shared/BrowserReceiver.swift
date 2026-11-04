import Foundation
import Network

/// LAN HTTP signaling and static assets only. Media always uses native WebRTC tracks.
final class BrowserReceiverServer {
    static func isLocalAddress(_ address: String) -> Bool {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return address == "::1" }
        let parts = fields.compactMap { UInt8($0) }
        guard parts.count == 4 else { return address == "::1" }
        return parts[0] == 10 || parts[0] == 127 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254) ||
            (parts[0] == 100 && (64...127).contains(parts[1]))
    }
    private final class Client {
        let video: NativeVideoPeer
        var events: [[String: Any]] = []
        var bytes = 0
        var messages = 0
        var connected = false
        let created = ProcessInfo.processInfo.systemUptime
        init(_ video: NativeVideoPeer) { self.video = video }
    }
    let port: UInt16
    var onReady: ((Bool) -> Void)?
    var onChanged: (() -> Void)?
    private let code: () -> String
    private let addresses: () -> [String]
    private let makePeer: () -> NativeVideoPeer
    private var listener: NWListener?
    private var clients: [String: Client] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var rates: [String: [Double]] = [:]
    private var cleanup: DispatchWorkItem?
    var videos: [NativeVideoPeer] { clients.values.map(\.video) }
    var connectedCount: Int { clients.values.filter(\.connected).count }
    init(port: UInt16, code: @escaping () -> String, addresses: @escaping () -> [String], makePeer: @escaping () -> NativeVideoPeer) {
        self.port = port; self.code = code; self.addresses = addresses; self.makePeer = makePeer
    }
    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state { case .ready: self?.onReady?(true)
                case .failed, .cancelled: self?.onReady?(false)
                default: break }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: .main); reap()
        } catch { onReady?(false) }
    }
    func stop() {
        cleanup?.cancel(); cleanup = nil
        listener?.cancel(); listener = nil
        let active = Array(clients.values); clients.removeAll()
        active.forEach { $0.video.stop() }
        connections.values.forEach { $0.cancel() }; connections.removeAll(); rates.removeAll()
        onReady?(false); onChanged?()
    }
    func disconnect(_ id: String) {
        if let key = clients.first(where: { $0.value.video.diagnosticID == id })?.key { remove(key) }
    }
    private func remove(_ id: String) {
        clients.removeValue(forKey: id)?.video.stop(); onChanged?()
    }
    private func reap() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, client) in clients where !client.connected && now - client.created > 30 { remove(id) }
        let work = DispatchWorkItem { [weak self] in self?.reap() }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, Self.isLocalAddress(host.debugDescription) else { connection.cancel(); return }
        guard connections.count < 16 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection); connections[key] = connection
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: key)
        }
        read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, ended, error in
            guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 24576 else { self.reply(connection, status: 413, object: ["error":"请求过大"]); return }
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound <= 8192,
                      let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { self.reply(connection, status: 400, object: [:]); return }
                let lines = header.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.reply(connection, status: 400, object: [:]); return }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else { self.reply(connection, status: 400, object: [:]); return }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard request.count == 3, headers["transfer-encoding"] == nil,
                      let size = Int(headers["content-length"] ?? "0"), size >= 0, size <= 16384 else { self.reply(connection, status: 400, object: [:]); return }
                let expected = boundary.upperBound + size
                if buffer.count >= expected {
                    guard buffer.count == expected else { self.reply(connection, status: 400, object: [:]); return }
                    self.handle(connection, method: String(request[0]), path: String(request[1]), headers: headers, body: Data(buffer[boundary.upperBound...])); return
                }
            } else if buffer.count > 8192 { self.reply(connection, status: 413, object: [:]); return }
            if ended || error != nil { connection.cancel(); self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            else { self.read(connection, buffer: buffer) }
        }
    }
    private func handle(_ connection: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        let hosts = Set((addresses().filter(Self.isLocalAddress) + ["127.0.0.1", "localhost"]).map { "\($0):\(port)" })
        guard let host = headers["host"], hosts.contains(host) else { reply(connection, status: 403, object: ["error":"请使用发送端显示的IP地址"]); return }
        if method == "GET", path == "/" || path == "/receiver.js" {
            let name = path == "/" ? "receiver.html" : "receiver.js"
            guard let url = Bundle.main.url(forResource: name, withExtension: nil), let data = try? Data(contentsOf: url), data.count < 65536 else { reply(connection, status: 503, object: ["error":"网页资源不可用"]); return }
            reply(connection, status: 200, data: data, type: path == "/" ? "text/html; charset=utf-8" : "application/javascript; charset=utf-8"); return
        }
        guard method == "POST", headers["origin"] == "http://" + host,
              headers["content-type"]?.hasPrefix("application/json") == true,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { reply(connection, status: 403, object: ["error":"无效来源或请求"]); return }
        if path == "/join" {
            let remote: String
            if case .hostPort(let address, _) = connection.endpoint { remote = address.debugDescription } else { remote = "unknown" }
            let now = ProcessInfo.processInfo.systemUptime
            rates = rates.mapValues { $0.filter { now - $0 < 60 } }.filter { !$0.value.isEmpty }
            guard rates.count < 128 || rates[remote] != nil, (rates[remote]?.count ?? 0) < 20 else { reply(connection, status: 429, object: ["error":"连接过于频繁，请稍后重试"]); return }
            rates[remote, default: []].append(now)
            guard object.count == 1, let supplied = object["code"] as? String, MatchingCode.isValid(supplied), supplied == code() else { reply(connection, status: 403, object: ["error":"匹配码错误"]); return }
            guard clients.count < 4 else { reply(connection, status: 409, object: ["error":"局域网页接收已达4台上限"]); return }
            let id = UUID().uuidString + UUID().uuidString
            let video = makePeer(), client = Client(video); clients[id] = client
            video.sendSignal = { [weak self, weak client] packet in
                guard let self, let client else { return }
                let size = (try? JSONSerialization.data(withJSONObject: packet).count) ?? 65537
                client.bytes += size; client.messages += 1
                guard client.bytes <= 65536, client.messages <= 96, client.events.count < 64 else { self.remove(id); return }
                client.events.append(packet)
            }
            video.onConnected = { [weak self, weak client] in client?.connected = true; self?.onChanged?() }
            video.onError = { [weak self] _ in self?.remove(id) }
            video.offer(); reply(connection, status: 200, object: ["id":id]); return
        }
        guard let id = object["id"] as? String, let client = clients[id] else { reply(connection, status: 404, object: ["error":"连接已结束，请重新接收"]); return }
        switch path {
        case "/poll":
            guard object.count == 1 else { reply(connection, status: 400, object: [:]); return }
            let events = client.events; client.events.removeAll(); reply(connection, status: 200, object: ["events":events])
        case "/signal":
            guard object.count == 2, let packet = object["packet"] as? [String: Any],
                  let type = packet["type"] as? String, type == "answer" || type == "candidate" else { reply(connection, status: 400, object: [:]); return }
            client.bytes += body.count; client.messages += 1
            guard client.bytes <= 65536, client.messages <= 96 else { remove(id); reply(connection, status: 413, object: [:]); return }
            client.video.receive(packet); reply(connection, status: 200, object: [:])
        case "/leave": remove(id); reply(connection, status: 200, object: [:])
        default: reply(connection, status: 404, object: [:])
        }
    }
    private func reply(_ connection: NWConnection, status: Int, object: [String: Any]) {
        reply(connection, status: status, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), type: "application/json")
    }
    private func reply(_ connection: NWConnection, status: Int, data: Data, type: String) {
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; media-src blob:; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let connection else { return }; connection.cancel(); self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        })
    }
}
