import Foundation

@main enum ConnectionRecoveryCheck {
    static func main() {
        var budget = RecoveryBudget()
        let expected: [Double] = [0, 1, 2, 4, 8, 15, 30, 30]
        for delay in expected { precondition(budget.next(now: 0) == delay) }
        precondition(budget.next(now: 0) == nil)
        budget.reset(); precondition(budget.next(now: 5) == 0)
        precondition(!budget.expired(now: 124.9) && budget.expired(now: 125))

        var now = 0.0, attempts = 0, exhausted = 0, cancels = 0
        var state = ConnectionRecovery.State.idle
        let recovery = ConnectionRecovery(clock: { now }, automaticMonitoring: false)
        recovery.state = { state }
        recovery.cancelTransport = { cancels += 1; state = .idle }
        recovery.onExhausted = { exhausted += 1 }
        func begin() { recovery.begin { attempts += 1; state = .connecting } }
        begin(); recovery.tick(); precondition(attempts == 1)
        state = .failed; recovery.tick()
        now = 0.9; recovery.tick(); precondition(attempts == 1)
        now = 1; recovery.tick(); precondition(attempts == 2)
        state = .connected; recovery.tick()
        now = 300; recovery.tick(); precondition(recovery.isActive, "Connected time is not retry time")
        recovery.networkChanged(online: true, signature: "wifi")
        recovery.networkChanged(online: false, signature: "offline")
        now = 419; recovery.tick(); precondition(recovery.isActive)
        now = 420; recovery.tick(); precondition(!recovery.isActive && exhausted == 1, "Offline deadline must stop")
        begin(); recovery.tick(); let previous = attempts
        recovery.stop(); state = .failed; now += 200; recovery.tick()
        recovery.networkChanged(online: true, signature: "cellular")
        precondition(attempts == previous, "Manual stop cannot revive")
        begin(); recovery.tick(); recovery.suspend(); now += 10; recovery.tick()
        precondition(state == .idle); recovery.resume(); recovery.tick()
        now += 2; recovery.tick(); precondition(attempts == previous + 2)
        state = .connecting; now += 21; recovery.tick(); now += 3; recovery.tick()
        precondition(attempts == previous + 3, "Hung negotiation must rebuild")
        recovery.stop()
        let initial = attempts
        begin()
        for _ in 0..<8 { recovery.tick(); state = .failed; recovery.tick(); now += 30 }
        recovery.tick()
        precondition(!recovery.isActive && attempts - initial <= 8)
        precondition(cancels > 0)
        var waiting = false
        recovery.waitingForApproval = { waiting }
        begin(); recovery.tick()
        waiting = true
        let pendingAttempt = attempts
        now += 290; recovery.tick()
        precondition(recovery.isActive && attempts == pendingAttempt, "Owner approval must not be retried at 20 or 120 seconds")
        waiting = false; recovery.tick()
        precondition(recovery.isActive && attempts == pendingAttempt)
        now += 21; recovery.tick(); now += 1; recovery.tick()
        precondition(attempts == pendingAttempt + 1, "Negotiation timeout resumes after approval")
        recovery.stop()
        print("PASS retry backoff, attempt/deadline limits, network loss, success reset, manual stop, suspension and hung negotiation")
    }
}
