// Native control/auth regression; actual media is verified inside the signed app (--verify-native-routes). Compile with CastingServer.swift, Shared/{StreamFormat,InternetConnection,NativeVideo}.swift and WebRTC.
import Foundation
import Network
final class DiagLog { static func log(_ tag: String, _ message: String) {} }
@main struct Check {
 static func main() {
  let server = CastingServer(port: 18319, accessCode: "001234")
  server.configureNative(bitrate: 8_000_000, fps: 30)
  server.start()
  defer { server.stop() }
  func tick(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
  func packet(_ type: UInt8, _ payload: Data) -> Data {
   var result = Data(); result.append(uint32: payload.count); result.append(type); result.append(payload); return result
  }
  tick()
  for (code, valid) in [("001234",true), (String(repeating:"0",count:30)+"123456",true),
                        ("12345",false), (String(repeating:"1",count:37),false), ("１２３４５６",false), ("abc123",false)] {
   precondition(MatchingCode.isValid(code) == valid)
   server.accessCode = code
   let probe = NWConnection(host: "127.0.0.1", port: 18319, using: .tcp)
   var type: UInt8?
   probe.start(queue: .main)
   probe.receive(minimumIncompleteLength: 5, maximumLength: 65536) { data, _, _, _ in
    DispatchQueue.main.async { if let data, data.count >= 5 { type = data[4] } }
   }
   probe.send(content: packet(5, Data(code.utf8)), completion: .idempotent)
   tick(0.5)
   precondition(type == (valid ? 8 : 7), "Authentication boundary failed")
   probe.cancel(); tick(0.05)
  }
  server.accessCode = "001234"
  let client = NWConnection(host: "127.0.0.1", port: 18319, using: .tcp)
  defer { client.cancel() }
  var buffer = Data(), offer = false, legacyVideo = false
  func read() {
   client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
    DispatchQueue.main.async {
     if let data { buffer.append(data) }
     while buffer.count >= 5 {
      let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
      guard buffer.count >= count + 5 else { break }
      let type = buffer[4], payload = buffer.copySlice(5,count)
      if type == 0 || type == 1 { legacyVideo = true }
      if type == 20, let object = try? JSONSerialization.jsonObject(with: payload) as? [String:Any] {
       if let sdp = object["sdp"] as? String { offer = sdp.contains("m=video") && !sdp.contains("m=audio") }
      }
      buffer = Data(buffer.dropFirst(count+5))
     }
     if !done && error == nil { read() }
    }
   }
  }
  client.start(queue:.main); read(); tick()
  // A hello without authentication must not start SDP negotiation.
  NativeVideo.send(["type":"hello","version":3], over:client); tick()
  precondition(!offer)
  client.send(content:packet(5,Data("001234".utf8)),completion:.idempotent)
  NativeVideo.send(["type":"hello","version":3], over:client)
  for _ in 0..<40 { tick(0.05); if offer { break } }
  precondition(offer && !legacyVideo, "Authenticated video+bounded-diagnostics SDP negotiation failed")
  precondition(server.touchEnabled == false)
  print("PASS code boundaries, authentication gate, video+bounded-diagnostics SDP, no byte-video fallback, touch disabled")
 }
}
