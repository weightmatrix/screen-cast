import Foundation
import Security

/// The host and broadcast extension share only their own small settings items.
/// No App Group container or access to other applications' keychain data is used.
final class BroadcastStore {
    private let group = Bundle.main.object(forInfoDictionaryKey: "BroadcastKeychainGroup") as? String ?? ""
    private let service = "com.witten.touping.broadcast-settings"
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrAccessGroup as String: group]
    }
    private func value(_ key: String) -> Any? {
        guard !group.isEmpty else { return nil }
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
    @discardableResult func set(_ value: Any, forKey key: String) -> Bool {
        guard !group.isEmpty, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return false }
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    func string(forKey key: String) -> String? { value(key) as? String }
    func integer(forKey key: String) -> Int { (value(key) as? NSNumber)?.intValue ?? 0 }
    func double(forKey key: String) -> Double { (value(key) as? NSNumber)?.doubleValue ?? 0 }
    func bool(forKey key: String) -> Bool { (value(key) as? NSNumber)?.boolValue ?? false }
}

enum BroadcastSettings {
    static func clampedBitrate(_ value: Int) -> Int {
        min(100_000_000, max(8_000_000, value))
    }

    static func resolutionLimit(_ value: Int) -> Int {
        [1600, 1920, 0].contains(value) ? value : 1600
    }

    static let store = BroadcastStore()
    static var isActive: Bool {
        let heartbeat = store.double(forKey: "broadcastHeartbeat")
        return store.bool(forKey: "broadcastActive") && Date().timeIntervalSince1970 - heartbeat < 6
    }
}
