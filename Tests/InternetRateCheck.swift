import Foundation
@main enum Check {
    static func main() {
        var rate = InternetRateController()
        precondition(rate.target == 8_000_000)
        for _ in 0..<10 { _ = rate.sample(bytes: 0, seconds: 2, stalledSeconds: 0, congested: false) }
        precondition(rate.target == 8_000_000, "Idle must not inflate rate")
        precondition(rate.sample(bytes: 1_000_000, seconds: 2, stalledSeconds: 1, congested: false) == 3_200_000)
        for _ in 0..<3 { _ = rate.sample(bytes: 800_000, seconds: 2, stalledSeconds: 0, congested: false) }
        precondition(rate.target == 3_700_000, "Recovery must be slow")
        for _ in 0..<10 { _ = rate.sample(bytes: 0, seconds: 2, stalledSeconds: 2, congested: true) }
        precondition(rate.target == 2_000_000)
        for _ in 0..<2000 { _ = rate.sample(bytes: 50_000_000, seconds: 2, stalledSeconds: 0, congested: false) }
        precondition(rate.target == 100_000_000)
        print("PASS startup, idle, congestion decrease, slow recovery, lower/upper bounds")
    }
}
