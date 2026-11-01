import Foundation
@main enum Check {
 static func main() {
  var edge = ScreenAudioEdge()
  let signal = [Int16](repeating: 20000, count: 480)
  let first = edge.apply(signal, frames:480)
  precondition(first[0] == 0 && first[240] == 20000)
  precondition(edge.apply(signal,frames:480) == signal, "Continuous blocks must remain unchanged")
  let empty = edge.apply([],frames:480)
  precondition(abs(Int(empty[0])-20000) < 100 && empty[239] == 0 && empty[479] == 0)
  precondition(zip(empty.dropFirst(),empty).allSatisfy { abs(Int($0)-Int($1)) < 100 })
  precondition(edge.apply([],frames:480).allSatisfy { $0 == 0 })
  precondition(edge.apply(signal,frames:480)[0] == 0)
  precondition(edge.apply([],frames:0).isEmpty)
  print("PASS starvation fade, restart fade, bounded step, silence and continuous-block identity")
 }
}
