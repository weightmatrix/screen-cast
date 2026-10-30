import Foundation
@main enum Check {
 static func main() {
  var budget = NativeVideoBudget()
  precondition(budget.limit == 8_000_000)
  precondition(budget.sample(upper:100_000_000, available:80_000_000, sendWait:0.2, loss:0) >= 8_000_000, "Pacer delay alone is not network capacity")
  for _ in 0..<5 { _ = budget.sample(upper:100_000_000,available:2_000_000,sendWait:0.2,loss:0.05) }
  precondition(budget.limit == 2_000_000)
  precondition(budget.sample(upper:100_000_000,available:20_000_000,sendWait:0.4,loss:0) == 4_000_000,
               "Recovered independent capacity must raise a starved budget despite old pacer backlog")
  precondition(budget.sample(upper:100_000_000,available:5_000_000,sendWait:0.4,loss:0) == 4_000_000,
               "Do not repeatedly chase less than ten percent headroom")
  for _ in 0..<8 { _ = budget.sample(upper:100_000_000,available:20_000_000,sendWait:0.01,loss:0) }
  precondition(budget.limit > 10_000_000, "Recovery must use independent BWE, even when content output is low")
  for _ in 0..<50 { _ = budget.sample(upper:100_000_000,available:200_000_000,sendWait:0,loss:0) }
  precondition(budget.limit == 100_000_000)
  budget.clamp(upper:1_000_000); precondition(budget.limit == 1_000_000)
  _ = budget.sample(upper:1_000_000,available:100_000,sendWait:1,loss:0.1)
  precondition(budget.limit == 1_000_000)
  _ = budget.sample(upper:100_000_000,available:0,sendWait:0,loss:0)
  precondition(budget.limit == 1_000_000, "Missing stats are not capacity")
  print("PASS no output-derived bandwidth, no pacer-only backoff, recovery after starvation, user bounds, missing BWE")
 }
}
