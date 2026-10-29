// Compile with CastingServer.swift, Shared/StreamFormat.swift, Shared/InternetConnection.swift and the WebRTC macOS framework (-F/-framework); see README.
import Foundation
import Network
final class DiagLog { static func log(_ tag: String, _ message: String) {} }
@main struct Check {
 static func main() {
  let server = CastingServer(port: 18319, accessCode: "67890123")
  var requests = 0
  var received = Data()
  var video = [UInt8]()
  server.onNeedsKeyFrame = { requests += 1 }
  server.start()
  func tick(_ duration: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
  func packet(_ type: UInt8, _ payload: Data) -> Data {
   var length = UInt32(payload.count).bigEndian
   var result = withUnsafeBytes(of: &length) { Data($0) }
   result.append(type); result.append(payload); return result
  }
  let client = NWConnection(host: "127.0.0.1", port: 18319, using: .tcp)
  var configurations = 0
  func read() {
   client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
    DispatchQueue.main.async {
    if let data { received.append(data) }
    while received.count >= 5 {
     let count = Int(received.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
     guard received.count >= count + 5 else { break }
     if received[4] == 0 { configurations += 1 }
     if received[4] == 1 { video.append(received[5]) }
     received = Data(received.dropFirst(count + 5))
    }
    if !done && error == nil { read() }
    }
   }
  }
  client.start(queue: .main); read(); tick()
  let feedback = packet(10, Data([1]))
  client.send(content: feedback, completion: .contentProcessed { _ in }); tick()
  precondition(requests == 0, "Unauthenticated feedback accepted")
  client.send(content: packet(5, Data("67890123".utf8)), completion: .contentProcessed { _ in }); tick()
  precondition(requests == 1)
  client.send(content: feedback + feedback + feedback, completion: .contentProcessed { _ in }); tick(0.05)
  precondition(requests == 2, "Keyframe requests not throttled")
  tick()
  server.sendConfig(Data([11]))
  server.sendFrame(Data([90]), isKeyFrame: true)
  tick()
  precondition(configurations == 1)
  server.sendConfig(Data([11]))
  server.sendFrame(Data([91]), isKeyFrame: false)
  tick()
  precondition(configurations == 1 && video.contains(91), "Unchanged format reset the video chain")
  server.sendConfig(Data([12]))
  server.sendFrame(Data([92]), isKeyFrame: false)
  server.sendFrame(Data([93]), isKeyFrame: true)
  tick()
  precondition(configurations == 2 && !video.contains(92) && video.contains(93), "Changed format did not wait for a keyframe")
  server.sendFrame(Data([100]), isKeyFrame: true)
  for n in 1...12 { server.sendFrame(Data([UInt8(n)]), isKeyFrame: false) }
  tick()
  precondition(requests >= 3, "Backlog did not request recovery")
  precondition(!video.contains(12), "Dependent frames survived queue overflow")
  server.sendFrame(Data([200]), isKeyFrame: true)
  server.sendFrame(Data([201]), isKeyFrame: false)
  tick()
  precondition(video.suffix(2) == [200,201], "Keyframe recovery failed")
  precondition(server.touchEnabled == false)
  for (code, accepted) in [("001234", true), (String(repeating: "0", count: 30) + "123456", true),
                            ("12345", false), (String(repeating: "1", count: 37), false),
                            ("１２３４５６", false), ("abc123", false)] {
   precondition(MatchingCode.isValid(code) == accepted)
   server.accessCode = code
   let probe = NWConnection(host: "127.0.0.1", port: 18319, using: .tcp)
   var responseType: UInt8?
   probe.start(queue: .main)
   probe.receive(minimumIncompleteLength: 5, maximumLength: 65536) { data, _, _, _ in
    DispatchQueue.main.async { if let data, data.count >= 5 { responseType = data[4] } }
   }
   probe.send(content: packet(5, Data(code.utf8)), completion: .idempotent)
   tick(0.5)
   precondition(responseType == (accepted ? 8 : 7), "Boundary authentication failed length=\(code.count)")
   probe.cancel(); tick(0.05)
  }
  for _ in 0..<100 { let code = MatchingCode.generate(); precondition(code.count == 8 && MatchingCode.isValid(code)) }
  client.cancel(); server.stop()
  print("PASS 6/36-digit boundaries, invalid code rejection, authentication, feedback throttling, unchanged/changed format handling, queue overflow, H264 recovery order, touch remains disabled")
 }
}
