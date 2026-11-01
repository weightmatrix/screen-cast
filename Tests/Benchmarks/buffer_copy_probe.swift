import Foundation
import CoreVideo

// Synthetic cost of an optional whole-frame CPU copy. Not an app power benchmark.
@main enum Probe {
 static func main() {
  var results: [[String: Any]] = []
  for (width,height) in [(1920,1440),(3840,2160)] {
   var original: CVPixelBuffer?, copied: CVPixelBuffer?
   let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
   precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,attrs,&original) == 0)
   precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,attrs,&copied) == 0)
   let src = original!, dst = copied!
   CVPixelBufferLockBaseAddress(src,[])
   var bytes = 0
   for plane in 0..<CVPixelBufferGetPlaneCount(src) {
    let size = CVPixelBufferGetBytesPerRowOfPlane(src,plane)*CVPixelBufferGetHeightOfPlane(src,plane)
    memset(CVPixelBufferGetBaseAddressOfPlane(src,plane)!,plane == 0 ? 80 : 128,size);bytes += size
   }
   CVPixelBufferUnlockBaseAddress(src,[])
   var ms:[Double] = []
   for _ in 0..<140 {
    let t = ProcessInfo.processInfo.systemUptime
    CVPixelBufferLockBaseAddress(src,.readOnly);CVPixelBufferLockBaseAddress(dst,[])
    for plane in 0..<CVPixelBufferGetPlaneCount(src) {
     let rows = CVPixelBufferGetHeightOfPlane(src,plane), sb = CVPixelBufferGetBytesPerRowOfPlane(src,plane), db = CVPixelBufferGetBytesPerRowOfPlane(dst,plane)
     for row in 0..<rows { memcpy(CVPixelBufferGetBaseAddressOfPlane(dst,plane)!.advanced(by:row*db),CVPixelBufferGetBaseAddressOfPlane(src,plane)!.advanced(by:row*sb),min(sb,db)) }
    }
    CVPixelBufferUnlockBaseAddress(dst,[]);CVPixelBufferUnlockBaseAddress(src,.readOnly)
    ms.append((ProcessInfo.processInfo.systemUptime-t)*1000)
   }
   CVPixelBufferLockBaseAddress(dst,.readOnly)
   precondition(CVPixelBufferGetBaseAddressOfPlane(dst,0)!.load(as:UInt8.self) == 80)
   precondition(CVPixelBufferGetBaseAddressOfPlane(dst,1)!.load(as:UInt8.self) == 128)
   CVPixelBufferUnlockBaseAddress(dst,.readOnly)
   let measured = Array(ms.dropFirst(20)).sorted()
   results.append(["width":width,"height":height,"bytesPerCopy":bytes,"copyMeanMs":measured.reduce(0,+)/Double(measured.count),"copyP95Ms":measured[Int(Double(measured.count-1)*0.95)],"extraReadWriteMBpsAt60fps":Double(bytes)*2*60/1_000_000,"pixelCheck":"PASS"])
  }
  let out:[String:Any] = ["scope":"Optional CPU full-frame copy only; current matching-size native path already bypasses it. No before/after app or power saving claim.","results":results]
  print(String(data:try! JSONSerialization.data(withJSONObject:out,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
