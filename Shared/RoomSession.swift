import Foundation
import Combine

struct RoomMessage: Identifiable, Codable {
    let id: String
    let author: String
    let text: String
}

/// One authenticated sender process owns the room for all of its capture sessions.
/// No history is uploaded or written to disk; at most 200 messages remain in memory.
final class RoomSession: ObservableObject {
    static let shared = RoomSession()
    @Published private(set) var messages: [RoomMessage] = []
    @Published private(set) var peerNicknames: [String: String] = [:]
    @Published private(set) var peerOrigins: [String: String] = [:]
    @Published private(set) var receiverCanSpeak = false {
        didSet { if receiverCanSpeak && !oldValue { RoomAudioSettings.shared.restoreReceiverMicrophone() } }
    }
    @Published private(set) var error = ""
    let participant: String = {
        #if os(iOS)
        if let existing = BroadcastSettings.store.string(forKey: "room.participant"), UUID(uuidString: existing) != nil { return existing }
        let value = UUID().uuidString.lowercased(); BroadcastSettings.store.set(value, forKey: "room.participant"); return value
        #else
        return UUID().uuidString.lowercased()
        #endif
    }()
    private struct Link {
        let host: Bool
        let send: ([String: Any]) -> Bool
        var participant: String
        var nickname: String
        var ready = false
        var arrivals: [Double] = []
    }
    private var links: [String: Link] = [:]
    private var seen = Set<String>()
    var nickname: String {
        #if os(iOS)
        if Bundle.main.bundleURL.pathExtension == "appex" { return Self.name(BroadcastSettings.store.string(forKey: "room.nickname") ?? "", fallback: BroadcastSettings.store.string(forKey: "room.defaultNickname") ?? "访客·" + participant.prefix(4).uppercased()) }
        #endif
        let store = UserDefaults.standard
        let fallback: String
        if let saved = store.string(forKey: "room.defaultNickname") { fallback = saved }
        else { fallback = "访客·" + participant.prefix(4).uppercased(); store.set(fallback, forKey: "room.defaultNickname") }
        #if os(iOS)
        if BroadcastSettings.store.string(forKey: "room.defaultNickname") != fallback { BroadcastSettings.store.set(fallback, forKey: "room.defaultNickname") }
        #endif
        let value = store.string(forKey: "room.nickname") ?? ""
        return Self.name(value, fallback: fallback)
    }
    static func name(_ text: String, fallback: String) -> String {
        let value = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }.prefix(32))).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? fallback : value
    }
    func attach(_ id: String, host: Bool, send: @escaping ([String: Any]) -> Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        links[id] = Link(host: host, send: send, participant: id, nickname: "用户-" + id.prefix(4))
    }
    func opened(_ id: String) {
        _ = links[id]?.send(["kind":"hello", "participant":participant, "nickname":nickname])
    }
    func detach(_ id: String) {
        links.removeValue(forKey: id); peerNicknames.removeValue(forKey: id); peerOrigins.removeValue(forKey: id)
        receiverCanSpeak = links.values.contains { !$0.host && $0.ready }
        VoiceRoom.shared.remove(id)
        if links.isEmpty { messages.removeAll(); seen.removeAll(); error = "" }
    }
    func receive(_ object: [String: Any], from id: String) {
        guard var link = links[id], let kind = object["kind"] as? String else { return }
        if kind == "hello" {
            guard let value = object["participant"] as? String, UUID(uuidString: value) != nil else { return }
            link.participant = value.lowercased()
            link.nickname = Self.name(object["nickname"] as? String ?? "", fallback: "访客·" + value.prefix(4).uppercased())
            if let key = object["origin"] as? String, let origin = ConnectionOrigin(rawValue: key) { peerOrigins[id] = origin.title }
            link.ready = true; links[id] = link; peerNicknames[id] = link.nickname
            receiverCanSpeak = links.values.contains { !$0.host && $0.ready }
            VoiceRoom.shared.identify(id, participant: link.participant)
            if link.host { _ = link.send(["kind":"host", "participant":participant, "nickname":nickname]) }
            return
        }
        if kind == "host", !link.host, let value = object["participant"] as? String, UUID(uuidString: value) != nil {
            link.ready = true; links[id] = link; receiverCanSpeak = true
            VoiceRoom.shared.identify(id, participant: value.lowercased()); return
        }
        if kind == "notice", !link.host, let text = object["text"] as? String, text.utf8.count <= 500 { error = text; return }
        guard kind == "chat", let text = object["text"] as? String,
              let messageID = object["id"] as? String, UUID(uuidString: messageID) != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 500, text.utf8.count <= 2000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        link.arrivals = link.arrivals.filter { now - $0 < 10 }
        guard link.arrivals.count < 8 else { return }
        link.arrivals.append(now); links[id] = link
        guard !seen.contains(messageID) else { return }
        let author = link.host ? link.nickname : Self.name(object["author"] as? String ?? "", fallback: "用户")
        let message = RoomMessage(id: messageID, author: author, text: text)
        append(message)
        if link.host, !broadcast(message) { _ = link.send(["kind":"notice", "text":"部分接收者发送队列已满，本条消息可能未送达所有人"]) }
    }
    private func append(_ message: RoomMessage) {
        seen.insert(message.id); messages.append(message)
        if messages.count > 200 { seen.remove(messages.removeFirst().id) }
    }
    @discardableResult private func broadcast(_ message: RoomMessage) -> Bool {
        let packet: [String: Any] = ["kind":"chat", "id":message.id, "author":message.author, "text":message.text]
        var delivered = true
        for link in links.values where link.host { if !link.send(packet) { delivered = false } }
        if !delivered { error = "部分接收者发送队列已满，本条消息可能未送达所有人" }
        return delivered
    }
    private var sent: [Double] = []
    func send(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = ProcessInfo.processInfo.systemUptime
        sent = sent.filter { now - $0 < 10 }
        guard !clean.isEmpty, clean.unicodeScalars.count <= 500, clean.utf8.count <= 2000, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }) else { error = "消息最多500字"; return false }
        guard sent.count < 8 else { error = "发送过于频繁，请稍后重试"; return false }
        let message = RoomMessage(id: UUID().uuidString.lowercased(), author: nickname, text: clean)
        #if os(iOS)
        if Bundle.main.bundleURL.pathExtension != "appex", BroadcastSettings.isActive {
            guard (BroadcastSettings.store.string(forKey: "room.chatOutbox") ?? "").isEmpty,
                  let data = try? JSONEncoder().encode(message),
                  BroadcastSettings.store.set(String(decoding: data, as: UTF8.self), forKey: "room.chatOutbox") else { error = "聊天发送队列忙，请稍后重试"; return false }
            sent.append(now); error = ""; return true
        }
        #endif
        var delivered = true
        if links.values.contains(where: { $0.host }) {
            append(message); delivered = broadcast(message)
        } else {
            guard let link = links.filter({ !$0.value.host && $0.value.ready }).sorted(by: { $0.key < $1.key }).first?.value,
                  link.send(["kind":"chat", "id":message.id, "text":clean]) else { error = "尚未连接聊天室，或发送队列已满"; return false }
            // The host echoes the accepted message, including the authenticated nickname.
        }
        sent.append(now); if delivered { error = "" }; return true
    }
    func refreshNickname() {
        #if os(iOS)
        if Bundle.main.bundleURL.pathExtension != "appex" { BroadcastSettings.store.set(UserDefaults.standard.string(forKey: "room.nickname") ?? "", forKey: "room.nickname") }
        #endif
        for key in links.keys { opened(key) }
    }
    #if os(iOS)
    private var lastBridgeSnapshot = ""
    private var lastBridgeNickname = ""
    private var bridgeWasActive = false
    func pollBroadcast() {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        if BroadcastSettings.isActive {
            bridgeWasActive = true
            let chatError = BroadcastSettings.store.string(forKey: "room.chatError") ?? ""
            if !chatError.isEmpty { error = chatError; BroadcastSettings.store.set("", forKey: "room.chatError") }
            let audioError = BroadcastSettings.store.string(forKey: "room.audioError") ?? ""
            if !audioError.isEmpty { RoomAudioSettings.shared.error = audioError; BroadcastSettings.store.set("", forKey: "room.audioError") }
            let raw = BroadcastSettings.store.string(forKey: "room.chatHistory") ?? "[]"
            if raw != lastBridgeSnapshot, raw.utf8.count <= 131072, let data = raw.data(using: .utf8), let history = try? JSONDecoder().decode([RoomMessage].self, from: data), history.count <= 40 {
                lastBridgeSnapshot = raw; messages = history
            }
        } else if bridgeWasActive { bridgeWasActive = false; lastBridgeSnapshot = ""; messages.removeAll() }
    }
    func serviceBroadcast() {
        guard Bundle.main.bundleURL.pathExtension == "appex" else { return }
        let currentNickname = nickname
        if currentNickname != lastBridgeNickname { lastBridgeNickname = currentNickname; refreshNickname() }
        VoiceRoom.shared.setEnabled(BroadcastSettings.store.bool(forKey: "room.receiveVoices"))
        let raw = BroadcastSettings.store.string(forKey: "room.chatOutbox") ?? ""
        if !raw.isEmpty {
            BroadcastSettings.store.set("", forKey: "room.chatOutbox")
            if raw.utf8.count <= 4096, let data = raw.data(using: .utf8), let message = try? JSONDecoder().decode(RoomMessage.self, from: data) { if !send(message.text) { BroadcastSettings.store.set(error, forKey: "room.chatError") } }
        }
        if let data = try? JSONEncoder().encode(Array(messages.suffix(40))), data.count <= 131072 {
            let raw = String(decoding: data, as: UTF8.self)
            if raw != lastBridgeSnapshot { lastBridgeSnapshot = raw; BroadcastSettings.store.set(raw, forKey: "room.chatHistory") }
        }
    }
    #endif

}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}

/// Bounded 48kHz mono microphone mixer. A receiver never gets its own voice back.
final class VoiceRoom {
    static let shared = VoiceRoom()
    private struct Source { var samples: [Int16] = []; var base = 0; var time = 0.0 }
    private let lock = NSLock()
    private var sources: [String: Source] = [:]
    private var identities: [String: String] = [:]
    private var cursors: [String: [String: Int]] = [:]
    private var enabled = true
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; if !value { sources.removeAll(); cursors.removeAll() }; lock.unlock() }
    func identify(_ peer: String, participant: String) { lock.lock(); identities[peer] = participant; lock.unlock() }
    func remove(_ peer: String) {
        lock.lock(); sources.removeValue(forKey: peer); identities.removeValue(forKey: peer); cursors.removeValue(forKey: peer)
        for key in cursors.keys { cursors[key]?.removeValue(forKey: peer) }; lock.unlock()
    }
    func isPrimary(_ peer: String) -> Bool { lock.lock(); defer { lock.unlock() }; return primary(peer) }
    private func primary(_ peer: String) -> Bool {
        let identity = identities[peer] ?? peer
        return identities.filter { $0.value == identity }.keys.min().map { $0 == peer } ?? true
    }
    func append(_ peer: String, pcm: [Int16]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, primary(peer), pcm.count <= 8192, sources.count < 32 || sources[peer] != nil else { return false }
        var source = sources[peer] ?? Source()
        source.samples.append(contentsOf: pcm)
        let drop = max(0, source.samples.count - 9600)
        if drop > 0 { source.samples.removeFirst(drop); source.base += drop }
        source.time = ProcessInfo.processInfo.systemUptime; sources[peer] = source
        return true
    }
    func mix(excluding peer: String, frames: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        guard enabled, (1...8192).contains(frames) else { return [Int16](repeating: 0, count: max(0, min(8192, frames))) }
        var sums = [Int32](repeating: 0, count: frames)
        let excluded = identities[peer] ?? peer, now = ProcessInfo.processInfo.systemUptime
        var offsets = cursors[peer] ?? [:]
        for (id, source) in sources where id != peer && (identities[id] ?? id) != excluded && now - source.time < 0.25 && primary(id) {
            let start = max(source.base, offsets[id] ?? (source.base + max(0, source.samples.count - frames)))
            let relative = min(source.samples.count, start - source.base), count = min(frames, source.samples.count - relative)
            for index in 0..<count { sums[index] += Int32(source.samples[relative + index]) }
            offsets[id] = source.base + relative + count
        }
        if cursors.count < 32 || cursors[peer] != nil { cursors[peer] = offsets }
        return sums.map { Int16(clamping: $0) }
    }
}
