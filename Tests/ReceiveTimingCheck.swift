import Foundation
@main enum Check {
    static func main() {
        var sampler = ReceiveTimingSampler()
        let first = sampler.sample(rtt:0.02,jitter:1,emitted:100,decode:0.2,decoded:100)
        precondition(first.networkRTTMS == 20 && first.processingMS == nil)
        let next = sampler.sample(rtt:0.03,jitter:1.1,emitted:110,decode:0.22,decoded:110)
        precondition(abs(next.processingMS! - 12) < 0.001, "Use interval deltas, not lifetime averages")
        precondition(sampler.sample(rtt:0,jitter:1.1,emitted:110,decode:0.22,decoded:110).processingMS == nil, "Idle must not show stale processing latency")
        precondition(sampler.sample(rtt:0.02,jitter:0,emitted:0,decode:0,decoded:0).processingMS == nil, "Counter reset starts a fresh interval")
        let resumed = sampler.sample(rtt:0.02,jitter:0.1,emitted:10,decode:0.02,decoded:10)
        precondition(abs(resumed.processingMS! - 12) < 0.001)
        let invalid = sampler.sample(rtt:.nan,jitter:nil,emitted:nil,decode:nil,decoded:nil)
        precondition(invalid.networkRTTMS == nil && invalid.processingMS == nil)
        precondition(ReceiveTiming.text(nil) == "—" && ReceiveTiming.text(.infinity) == "—")
        print("PASS RTT units, per-window buffering/decode, idle, reset, missing and invalid values")
    }
}
