import Foundation
import Network

/// Monotonic, bounded budget, including time spent without a network.
struct RecoveryBudget {
    private(set) var attempts = 0
    private(set) var started: TimeInterval?
    mutating func next(now: TimeInterval) -> TimeInterval? {
        if started == nil { started = now }
        guard attempts < 8, now - started! < 120 else { return nil }
        let delay: TimeInterval = attempts == 0 ? 0 : [1, 2, 4, 8, 15, 30, 30][attempts - 1]
        attempts += 1
        return delay
    }
    func expired(now: TimeInterval) -> Bool { started.map { now - $0 >= 120 } ?? false }
    mutating func reset() { attempts = 0; started = nil }
}

/// All callbacks and transports are owned by the main queue. A new user intent
/// cancels the old generation, so delayed retries cannot revive a manual stop.
final class ConnectionRecovery {
    enum State { case idle, connecting, connected, failed }
    var state: (() -> State)?
    var waitingForApproval: (() -> Bool)?
    private var approvalWaiting = false
    var cancelTransport: (() -> Void)?
    var onTransition: ((String) -> Void)?
    private(set) var hasReceivedMedia = false
    func noteMediaReceived() { if isActive { hasReceivedMedia = true } }
    var onMessage: ((String) -> Void)?
    var onExhausted: (() -> Void)?
    private(set) var isAttempting = false
    private(set) var isActive = false
    private var attempt: (() -> Void)?
    private var budget = RecoveryBudget()
    private var timer: DispatchSourceTimer?
    private var monitor: NWPathMonitor?
    private var pathSignature: String?
    private var online = true
    private var suspended = false
    private var due: TimeInterval?
    private var attemptStarted: TimeInterval?
    private var wasConnected = false
    private var generation = UUID()
    private let clock: () -> TimeInterval
    private let automaticMonitoring: Bool

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticMonitoring: Bool = true) {
        self.clock = clock; self.automaticMonitoring = automaticMonitoring
    }

    func begin(_ action: @escaping () -> Void) {
        stop()
        cancelTransport?()
        isActive = true; attempt = action; budget.reset()
        schedule(now: clock())
        guard automaticMonitoring else { return }
        let token = generation
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status):\(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map { $0.name }.sorted()):\(path.isExpensive):\(path.isConstrained)"
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.isActive else { return }
                self.networkChanged(online: path.status == .satisfied, signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "casting.recovery.path"))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }

    func stop() {
        generation = UUID(); hasReceivedMedia = false; approvalWaiting = false; isActive = false; attempt = nil
        timer?.cancel(); timer = nil; monitor?.cancel(); monitor = nil
        due = nil; attemptStarted = nil; pathSignature = nil
        wasConnected = false; suspended = false; online = true
        onMessage?("")
    }

    func suspend() {
        onTransition?("application-suspended")
        suspended = true
        if wasConnected { wasConnected = false; budget.reset() }
        cancelTransport?(); attemptStarted = nil
    }
    func resume() {
        guard isActive, suspended else { return }
        suspended = false
        if due == nil { schedule(now: clock()) }
        tick()
    }

    private func schedule(now: TimeInterval) {
        guard let delay = budget.next(now: now) else { exhaust(); return }
        due = now + delay
        onMessage?("正在重连（\(budget.attempts)/8），最长等待 2 分钟")
    }

    private func exhaust() {
        stop(); cancelTransport?(); onExhausted?()
    }

    func networkChanged(online: Bool, signature: String) {
        guard isActive else { return }
        let changed = pathSignature != nil && pathSignature != signature
        pathSignature = signature; self.online = online
        if changed { onTransition?("path-changed online=\(online) healthy=\(state?() == .connected)") }
        // A satisfied path notification (VPN/cost/IPv6/interface metadata) does not
        // prove the active ICE pair failed. Let WebRTC migrate it while still connected.
        if changed, !suspended, !(online && state?() == .connected) {
            if wasConnected { wasConnected = false; budget.reset() }
            cancelTransport?(); attemptStarted = nil
            if due == nil { schedule(now: clock()) }
        }
        tick()
    }

    func tick() {
        guard isActive, !suspended else { return }
        let now = clock()
        if case .connected = state?() {
            if !wasConnected { budget.reset(); onMessage?("") }
            wasConnected = true; attemptStarted = nil; due = nil
            return
        }
        if wasConnected { wasConnected = false; budget.reset() }
        if waitingForApproval?() == true {
            approvalWaiting = true; onMessage?("等待投送者审批，最多5分钟"); return
        }
        if approvalWaiting { approvalWaiting = false; budget.reset(); attemptStarted = now; onMessage?("") }
        guard !budget.expired(now: now) else { exhaust(); return }
        guard online else { onMessage?("等待网络恢复，最长等待 2 分钟"); return }
        if let due {
            guard now >= due else { return }
            self.due = nil; attemptStarted = now
            isAttempting = true; attempt?(); isAttempting = false
        } else if let started = attemptStarted {
            let current = state?() ?? .idle
            if current == .failed || current == .idle || now - started >= 20 {
                cancelTransport?(); attemptStarted = nil; schedule(now: now)
            }
        } else { schedule(now: now) }
    }

    deinit { timer?.cancel(); monitor?.cancel() }
}
