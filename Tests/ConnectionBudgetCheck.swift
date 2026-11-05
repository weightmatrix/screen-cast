import Foundation

@main enum ConnectionBudgetCheck {
    static func main() {
        // Interleaved IDs represent different stream tasks and transport implementations.
        for i in 0..<5 { precondition(SenderConnectionBudget.reserve("wan-\(i)", internet: true)) }
        precondition(!SenderConnectionBudget.reserve("wan-overflow", internet: true))
        for i in 0..<10 { precondition(SenderConnectionBudget.reserve("lan-\(i)", internet: false)) }
        precondition(!SenderConnectionBudget.reserve("lan-overflow", internet: false))
        precondition(SenderConnectionBudget.reserve("wan-0", internet: true))
        precondition(!SenderConnectionBudget.reserve("wan-0", internet: false))
        SenderConnectionBudget.release("wan-0")
        SenderConnectionBudget.release("wan-0") // release is idempotent, not a decrement.
        precondition(SenderConnectionBudget.reserve("replacement", internet: true))
        precondition(!SenderConnectionBudget.reserve("extra", internet: true))
        for i in 0..<10 { SenderConnectionBudget.release("lan-\(i)") }
        for i in 0..<5 { SenderConnectionBudget.release("wan-\(i)") }
        SenderConnectionBudget.release("replacement")
        print("PASS combined WAN/LAN budgets, duplicate reservation, route mismatch and slot recovery")
    }
}
