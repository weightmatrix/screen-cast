import Foundation

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
}
