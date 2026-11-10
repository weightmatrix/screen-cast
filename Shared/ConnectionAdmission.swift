import Foundation
import CryptoKit
import Combine
import Security

/// All admissions run on the main queue, across every stream in this sender process.
enum SenderConnectionBudget {
    private static var slots: [String: Bool] = [:]
    static func reserve(_ id: String, internet: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = slots[id] { return existing == internet }
        guard slots.values.filter({ $0 == internet }).count < (internet ? 5 : 10) else { return false }
        slots[id] = internet; return true
    }
    static func release(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        slots.removeValue(forKey: id)
    }
}


struct PendingConnection: Identifiable, Codable {
    let id: String
    let route: String
    let ip: String
    let application: String
    var nickname: String? = nil
}

/// Invitation IDs locate a stream; passwords are separate and never part of an invitation.
enum AdmissionCredentials {
    static func validPassword(_ value: String) -> Bool {
        let value = value.precomposedStringWithCanonicalMapping
        return (6...64).contains(value.unicodeScalars.count) && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func application(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 200, text.utf8.count <= 800,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }) else { return nil }
        return text
    }
    static func verifier(password: String, invitation: String) -> String {
        SHA256.hash(data: Data(("touping-auth-v2:" + invitation + ":" + password.precomposedStringWithCanonicalMapping).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func proof(verifier: String, nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(verifier.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func equalProof(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == 64, b.count == 64 else { return false }
        return zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func invitation(_ value: String) -> String {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: input), let fragment = url.fragment,
           let query = URLComponents(string: "?" + fragment)?.queryItems,
           let code = query.first(where: { $0.name == "invite" || $0.name == "code" })?.value { return code }
        return input
    }
}

/// Local per-target drafts; passwords stay in Keychain, never UserDefaults or logs.
final class ReceiverFormMemory: ObservableObject {
    @Published var password = "" { didSet { save() } }
    @Published var application = "" { didSet { save() } }
    private var selected = ""
    private var loading = false
    private let defaults: UserDefaults
    private let readSecret: (String) -> String
    private let writeSecret: (String, String) -> Void
    init(defaults: UserDefaults = .standard,
         read: @escaping (String) -> String = ReceiverFormMemory.read,
         write: @escaping (String, String) -> Void = ReceiverFormMemory.write) {
        self.defaults = defaults; readSecret = read; writeSecret = write
    }
    static func target(mode: String, invitation: String, host: String, port: String) -> String {
        let code = AdmissionCredentials.invitation(invitation)
        if MatchingCode.isValid(code) { return "invitation:" + code }
        return "address:" + mode + ":" + host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + ":" + port
    }
    func select(_ target: String) {
        let key = SHA256.hash(data: Data(target.utf8)).map { String(format: "%02x", $0) }.joined()
        guard key != selected else { return }
        save(); selected = key; loading = true
        password = readSecret(key)
        application = defaults.string(forKey: "receiver.application." + key) ?? ""
        loading = false
    }
    private func save() {
        guard !loading, !selected.isEmpty else { return }
        var keys = defaults.stringArray(forKey: "receiver.profile.keys") ?? []
        if password.isEmpty && application.isEmpty {
            if keys.contains(selected) {
                writeSecret(selected, ""); defaults.removeObject(forKey: "receiver.application." + selected)
                keys.removeAll { $0 == selected }; defaults.set(keys, forKey: "receiver.profile.keys")
            }
            return
        }
        writeSecret(selected, String(password.prefix(256)))
        defaults.set(String(application.prefix(200)), forKey: "receiver.application." + selected)
        keys.removeAll { $0 == selected }; keys.append(selected)
        while keys.count > 32 {
            let old = keys.removeFirst(); defaults.removeObject(forKey: "receiver.application." + old); writeSecret(old, "")
        }
        defaults.set(keys, forKey: "receiver.profile.keys")
    }
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Han.touping.receiver-password", kSecAttrAccount as String: key]
    }
    static func read(_ key: String) -> String {
        var request = query(key); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ key: String, _ value: String) {
        let request = query(key)
        if value.isEmpty { SecItemDelete(request as CFDictionary); return }
        let update = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(request as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = request; item.merge(update) { _, new in new }; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
