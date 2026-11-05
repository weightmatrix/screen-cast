import Foundation
import CryptoKit

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
