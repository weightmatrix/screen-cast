import Foundation
@main enum Check {
 static func main() {
  var q = ScreenFrameQuantizer()
  for _ in 0..<200 { q.observe(bytes:100,budget:10000,usedQP:q.qp,key:false) }
  precondition(q.qp == 28,"Static frames must not bank quality credit")
  q.observe(bytes:80000,budget:10000,usedQP:28,key:false)
  precondition(q.qp == 34)
  q.observe(bytes:80000,budget:10000,usedQP:28,key:false)
  precondition(q.qp == 34,"Late feedback must not repeatedly amplify a stale QP")
  for _ in 0..<50 { q.observe(bytes:80000,budget:10000,usedQP:q.qp,key:false) }
  precondition(q.qp == 51)
  for _ in 0..<100 { q.observe(bytes:5000,budget:10000,usedQP:q.qp,key:false) }
  precondition(q.qp == 10)
  q.observe(bytes:1000000,budget:10000,usedQP:10,key:true)
  precondition(q.qp == 10,"Startup keyframes are not steady-frame demand")
  print("PASS static hold, fast bounded backoff, stale feedback, recovery and keyframes")
 }
}
