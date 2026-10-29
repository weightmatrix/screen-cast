import Foundation
@main enum Check {
 static func main() {
  var rate = NativeInternetRate()
  for _ in 0..<20 { _ = rate.sample(upper: 100_000_000, outputBps: 100_000, targetBps: 100_000, sendWait: 0) }
  precondition(rate.limit == 8_000_000)
  for _ in 0..<4 { _ = rate.sample(upper: 100_000_000, outputBps: Double(rate.limit), targetBps: Double(rate.limit), sendWait: 0.01) }
  precondition(rate.limit == 11_520_000)
  precondition(rate.sample(upper: 100_000_000, outputBps: 8_000_000, targetBps: 11_520_000, sendWait: 0.15) == 6_000_000)
  for _ in 0..<30 { _ = rate.sample(upper: 100_000_000, outputBps: 100_000, targetBps: 100_000, sendWait: 1) }
  precondition(rate.limit == 2_000_000)
  for _ in 0..<200 { _ = rate.sample(upper: 100_000_000, outputBps: Double(rate.limit), targetBps: Double(rate.limit), sendWait: 0.01) }
  precondition(rate.limit == 100_000_000)
  rate.clamp(to: 1_000_000); precondition(rate.limit == 1_000_000)
  print("PASS idle, gradual growth, queue backoff, user bounds, recovery")
 }
}
