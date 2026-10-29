import Foundation
@main enum Check {
    static func main() {
        var pacer = EncoderFramePacer()
        var now = 0.0
        func feed(_ count: Int, drop: Bool, interval: Double = 1.0 / 60) {
            for _ in 0..<count {
                now += interval
                _ = pacer.observe(drop: drop, now: now, upper: 60, enabled: true)
            }
        }
        feed(122, drop: true)
        precondition(pacer.target == 60, "One bad window must not reduce FPS")
        feed(125, drop: true)
        precondition(pacer.target == 30)
        feed(250, drop: true)
        precondition(pacer.target <= 20)
        feed(1300, drop: true)
        precondition(pacer.target == 15)
        feed(500, drop: false)
        precondition(pacer.target > 15 && pacer.target <= 20, "Recovery must be slow")
        let before = pacer.target
        feed(20, drop: false, interval: 1)
        precondition(pacer.target == before, "Idle capture must not trigger recovery")
        _ = pacer.observe(drop: false, now: now + 1, upper: 30, enabled: false)
        precondition(pacer.target == 30, "LAN/disconnect must restore user setting")
        print("PASS sustained drops, hysteresis, floor, slow recovery, idle, restore upper")
    }
}
