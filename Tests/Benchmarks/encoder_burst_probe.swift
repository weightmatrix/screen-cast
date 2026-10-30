import Foundation
import VideoToolbox
import CoreImage
final class Trace {
 let lock = NSLock()
 var samples: [[String: Double]] = []
 var dropped = 0, errors = 0, pending = 0, maxPending = 0
 func submitted() { lock.lock(); pending += 1; maxPending = max(maxPending,pending); lock.unlock() }
 func output(_ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sample: CMSampleBuffer?) {
  lock.lock(); defer { lock.unlock() }
  pending = max(0,pending-1)
  guard status == 0 else { errors += 1; return }
  guard !flags.contains(.frameDropped), let sample else { dropped += 1; return }
  samples.append(["pts": CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), "arrival": ProcessInfo.processInfo.systemUptime, "bytes": Double(CMSampleBufferGetTotalSampleSize(sample))])
 }
}
// Standalone encoder-only probe, not the application performance acceptance test.
// Usage: probe <window-seconds> <valid|invalid> <synthetic-document.png> [long-first|short-first|vbr]
let args = CommandLine.arguments
precondition(args.count >= 4, "window duration image [mode] required")
let seconds = Double(args[1])!, durationValid = args[2] == "valid"
let trace = Trace()
let specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey:1440,kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
var session: VTCompressionSession?
let create = VTCompressionSessionCreate(allocator:nil,width:1920,height:1440,codecType:kCMVideoCodecType_H264,encoderSpecification:specification as CFDictionary,imageBufferAttributes:attributes as CFDictionary,compressedDataAllocator:nil,outputCallback:{ opaque,_,status,flags,sample in
 Unmanaged<Trace>.fromOpaque(opaque!).takeUnretainedValue().output(status,flags,sample)
},refcon:Unmanaged.passUnretained(trace).toOpaque(),compressionSessionOut:&session)
guard create == 0, let session else { fatalError("session create \(create)") }
let limits: [Double] = args.count > 4 ? (args[4] == "long-first" ? [2812500,1,281250,0.1] : [281250,0.1,2812500,1]) : [15_000_000.0 / 8 * 1.5 * seconds,seconds]
var properties: [(CFString, CFTypeRef)] = [(kVTCompressionPropertyKey_RealTime,kCFBooleanTrue),(kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse),(kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),(kVTCompressionPropertyKey_AverageBitRate,15_000_000 as CFNumber),(kVTCompressionPropertyKey_ExpectedFrameRate,60 as CFNumber),(kVTCompressionPropertyKey_DataRateLimits,limits as CFArray)]
let vbr = args.count > 4 && args[4] == "vbr"
if vbr {
 guard #available(macOS 26.0, *) else { fatalError("VBR probe requires macOS26+") }
 properties.removeAll { $0.0 == kVTCompressionPropertyKey_AverageBitRate || $0.0 == kVTCompressionPropertyKey_DataRateLimits }
 properties += [(kVTCompressionPropertyKey_VariableBitRate,15_000_000 as CFNumber),
  (kVTCompressionPropertyKey_VBVMaxBitRate,15_000_000 as CFNumber),
  (kVTCompressionPropertyKey_VBVBufferDuration,0.1 as CFNumber)]
}
var statuses: [String:Int32] = [:]
for (key,value) in properties { statuses[key as String] = VTSessionSetProperty(session,key:key,value:value) }
var copied: Unmanaged<CFTypeRef>?
let copyStatus = VTSessionCopyProperty(session,key:kVTCompressionPropertyKey_DataRateLimits,allocator:nil,valueOut:&copied)
let readback = copied?.takeRetainedValue() as? [Double] ?? []
var vbvReadback: [String: Any] = [:]
if #available(macOS 26.0, *), vbr {
 for key in [kVTCompressionPropertyKey_VariableBitRate,kVTCompressionPropertyKey_VBVMaxBitRate,kVTCompressionPropertyKey_VBVBufferDuration] {
  var value: Unmanaged<CFTypeRef>?
  let result = VTSessionCopyProperty(session,key:key,allocator:nil,valueOut:&value)
  vbvReadback[key as String] = ["status":result,"value":(value?.takeRetainedValue() as? NSNumber) ?? -1]
 }
}
var hw: Unmanaged<CFTypeRef>?
let hwStatus = VTSessionCopyProperty(session,key:kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,allocator:nil,valueOut:&hw)
let hardware = (hw?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
var pool: CVPixelBufferPool?
precondition(CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool) == 0)
let image = CIImage(contentsOf:URL(fileURLWithPath:args[3]))!
let context = CIContext(options:[.cacheIntermediates:false])
let start = ProcessInfo.processInfo.systemUptime
var held: CVPixelBuffer?, movement = 0
var phases: [[String:Any]] = []
for (name,count,fps,motion) in [("motion",180,60,true),("idle",80,20,false),("resume",240,60,true)] {
 let begin = ProcessInfo.processInfo.systemUptime
 statuses["ExpectedFrameRate-"+name] = VTSessionSetProperty(session,key:kVTCompressionPropertyKey_ExpectedFrameRate,value:fps as CFNumber)
 for n in 0..<count {
  if motion || held == nil {
   var pixel: CVPixelBuffer?
   precondition(CVPixelBufferPoolCreatePixelBuffer(nil,pool!,&pixel) == 0)
   movement += 1
   let x=Double(movement*13 % 1152), y=Double(movement*7 % 864)
   context.render(image.cropped(to:CGRect(x:x,y:y,width:1920,height:1440)).transformed(by:CGAffineTransform(translationX:-x,y:-y)),to:pixel!)
   held = pixel
  }
  let now=ProcessInfo.processInfo.systemUptime
  trace.submitted()
  let status=VTCompressionSessionEncodeFrame(session,imageBuffer:held!,presentationTimeStamp:CMTime(seconds:now,preferredTimescale:1_000_000_000),duration:durationValid ? CMTime(value:1,timescale:Int32(fps)) : .invalid,frameProperties:nil,sourceFrameRefcon:nil,infoFlagsOut:nil)
  if status != 0 { trace.lock.lock(); trace.errors += 1; trace.pending = max(0,trace.pending-1); trace.lock.unlock() }
  let wait=begin+Double(n+1)/Double(fps)-ProcessInfo.processInfo.systemUptime
  if wait>0 { Thread.sleep(forTimeInterval:wait) }
 }
 phases.append(["name":name,"start":begin,"end":ProcessInfo.processInfo.systemUptime,"submitted":count])
}
VTCompressionSessionCompleteFrames(session,untilPresentationTimeStamp:.invalid)
VTCompressionSessionInvalidate(session)
func window(_ samples:[[String:Double]], _ key:String) -> Double {
 let sorted=samples.sorted{$0[key]! < $1[key]!}; var begin=0, sum=0.0, maximum=0.0
 for end in sorted.indices {
  sum += sorted[end]["bytes"]!
  while sorted[end][key]!-sorted[begin][key]! >= 0.1-0.000001 {sum -= sorted[begin]["bytes"]!;begin += 1}
  maximum=max(maximum,sum)
 }
 return maximum
}
let resume=phases.last!["start"] as! Double
let selected=trace.samples.filter{$0["pts"]!>=resume && $0["pts"]!<resume+1}
let output:[String:Any] = ["mode":vbr ? "vbr" : "average", "limit_seconds":seconds,"valid_duration":durationValid,"set_status":statuses,"vbv_readback":vbvReadback,"readback_status":copyStatus,"readback":readback,"hardware":hardware,"hardware_status":hwStatus,"prepare":prepare,"errors":trace.errors,"max_inflight":trace.maxPending,"tail_output_ms":max(0,(trace.samples.map{$0["arrival"]!}.max() ?? start)-(phases.last!["end"] as! Double))*1000,"dropped":trace.dropped,"frames":trace.samples.count,"resume_first_second_frames":selected.count,"resume_max_frame_bytes":selected.map{$0["bytes"]!}.max() ?? 0,"resume_max_100ms_pts_bytes":window(selected,"pts"),"resume_max_100ms_arrival_bytes":window(selected,"arrival"),"requested_100ms_bytes":281250,"phases":phases.map{p -> [String:Any] in var v=p;v["start"]=(p["start"] as! Double)-start;v["end"]=(p["end"] as! Double)-start;return v}]
print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),encoding:.utf8)!)
