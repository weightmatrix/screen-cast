import Foundation

@main enum ReceiverFormMemoryCheck {
    static func main() {
        let suite = "touping-form-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var secrets: [String: String] = [:]
        let memory = ReceiverFormMemory(defaults: defaults, read: { secrets[$0] ?? "" }, write: { key, value in
            if value.isEmpty { secrets.removeValue(forKey: key) } else { secrets[key] = value }
        })
        let a = ReceiverFormMemory.target(mode: "wanCode", invitation: "12345678", host: "", port: "")
        let b = ReceiverFormMemory.target(mode: "wanCode", invitation: "87654321", host: "", port: "")
        precondition(a == ReceiverFormMemory.target(mode: "code", invitation: "https://example.invalid/#invite=12345678", host: "", port: ""))
        memory.select(a); memory.password = "fixture-secret-alpha"; memory.application = "fixture application A"
        memory.select(b); precondition(memory.password.isEmpty && memory.application.isEmpty)
        memory.password = "fixture-secret-beta"; memory.application = "fixture application B"
        memory.select(a); precondition(memory.password == "fixture-secret-alpha" && memory.application == "fixture application A")
        let restored = ReceiverFormMemory(defaults: defaults, read: { secrets[$0] ?? "" }, write: { secrets[$0] = $1 })
        restored.select(b); precondition(restored.password == "fixture-secret-beta" && restored.application == "fixture application B")
        precondition(!String(describing: defaults.dictionaryRepresentation()).contains("fixture-secret"), "Passwords must not enter UserDefaults")
        restored.password = ""; precondition(!secrets.values.contains("fixture-secret-beta"))
        for index in 10000000..<10000040 { memory.select("invitation:\(index)"); memory.password = "fixture"; memory.application = "draft" }
        precondition((defaults.stringArray(forKey: "receiver.profile.keys") ?? []).count == 32 && secrets.count <= 32)
        precondition(!secrets.values.contains("fixture-secret-alpha"), "Eviction removes credentials with the draft")
        precondition(ReceiverFormMemory.target(mode: "ip", invitation: "", host: "HOST", port: "1") != ReceiverFormMemory.target(mode: "ip", invitation: "", host: "HOST", port: "2"))
        print("PASS native per-invitation Keychain-backed drafts, reload/isolation, no plaintext defaults, clear and bounded eviction")
    }
}
