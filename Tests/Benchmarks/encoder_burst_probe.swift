import Foundation
import VideoToolbox
import CoreImage
final class QPTicket {
 let qp: Int; let budget: Int
 init(_ qp:Int,_ budget:Int) {self.qp=qp;self.budget=budget}
}
final class Trace {
 let lock = NSLock()
 var samples: [[String: Double]] = []
 var quantizer = ScreenFrameQuantizer()
 var collectQuality = false
 var encoded: [CMSampleBuffer] = []
 var references: [Int64: CVPixelBuffer] = [:]
 var dropped = 0, errors = 0, pending = 0, maxPending = 0
 func submitted() { lock.lock(); pending += 1; maxPending = max(maxPending,pending); lock.unlock() }
 func output(_ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sample: CMSampleBuffer?, _ qp: Int?, _ budget: Int) {
  lock.lock(); defer { lock.unlock() }
  pending = max(0,pending-1)
  guard status == 0 else { errors += 1; return }
  guard !flags.contains(.frameDropped), let sample else { dropped += 1; return }
  if let qp {
   let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[CFString:Any]]
   quantizer.observe(bytes:CMSampleBufferGetTotalSampleSize(sample),budget:budget,usedQP:qp,key:attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true)
  }
  if collectQuality { encoded.append(sample) }
  samples.append(["pts": CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), "arrival": ProcessInfo.processInfo.systemUptime, "bytes": Double(CMSampleBufferGetTotalSampleSize(sample))])
 }
}
// Standalone encoder-only probe, not the application performance acceptance test.
// Usage: probe <window-seconds> <valid|invalid> <synthetic-document.png> [long-first|short-first|vbr]
@main enum EncoderBurstProbe {
static func main() throws {
let args = CommandLine.arguments
precondition(args.count >= 4, "window duration image [mode] required")
let seconds = Double(args[1])!, durationValid = args[2] == "valid"
let manual = args.count > 4 && args[4] == "manual"
let trace = Trace()
let quality = args.contains("--quality"); trace.collectQuality = quality
var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
if manual { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey:1440,kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
var session: VTCompressionSession?
let create = VTCompressionSessionCreate(allocator:nil,width:1920,height:1440,codecType:kCMVideoCodecType_H264,encoderSpecification:specification as CFDictionary,imageBufferAttributes:attributes as CFDictionary,compressedDataAllocator:nil,outputCallback:{ opaque,frame,status,flags,sample in
 let ticket = frame.map { Unmanaged<QPTicket>.fromOpaque($0).takeRetainedValue() }
 Unmanaged<Trace>.fromOpaque(opaque!).takeUnretainedValue().output(status,flags,sample,ticket?.qp,ticket?.budget ?? 0)
},refcon:Unmanaged.passUnretained(trace).toOpaque(),compressionSessionOut:&session)
guard create == 0, let session else { fatalError("session create \(create)") }
let limits: [Double] = args.count > 4 && ["long-first","short-first"].contains(args[4]) ? (args[4] == "long-first" ? [2812500,1,281250,0.1] : [281250,0.1,2812500,1]) : [15_000_000.0 / 8 * 1.5 * seconds,seconds]
var properties: [(CFString, CFTypeRef)] = [(kVTCompressionPropertyKey_RealTime,kCFBooleanTrue),(kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse),(kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),(kVTCompressionPropertyKey_AverageBitRate,15_000_000 as CFNumber),(kVTCompressionPropertyKey_ExpectedFrameRate,60 as CFNumber),(kVTCompressionPropertyKey_DataRateLimits,limits as CFArray)]
let vbr = args.count > 4 && args[4].hasPrefix("vbr")
let speed = vbr && args[4] == "vbr-speed"
if vbr {
 guard #available(macOS 26.0, *) else { fatalError("VBR probe requires macOS26+") }
 properties.removeAll { $0.0 == kVTCompressionPropertyKey_AverageBitRate || $0.0 == kVTCompressionPropertyKey_DataRateLimits }
 properties += [(kVTCompressionPropertyKey_VariableBitRate,15_000_000 as CFNumber),
  (kVTCompressionPropertyKey_VBVMaxBitRate,15_000_000 as CFNumber),
  (kVTCompressionPropertyKey_VBVBufferDuration,0.1 as CFNumber)]
}
if manual { properties.removeAll { $0.0 == kVTCompressionPropertyKey_AverageBitRate || $0.0 == kVTCompressionPropertyKey_DataRateLimits } }
if speed { properties.append((kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,kCFBooleanTrue)) }
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
  let pts = CMTime(seconds:now,preferredTimescale:1_000_000_000)
  if quality && n % 30 == 0 { trace.references[pts.value] = held! }
  trace.submitted()
  trace.lock.lock(); let qp = trace.quantizer.qp; trace.lock.unlock()
  let ticket = manual ? Unmanaged.passRetained(QPTicket(qp,max(256,15_000_000/8/60))).toOpaque() : nil
  let status=VTCompressionSessionEncodeFrame(session,imageBuffer:held!,presentationTimeStamp:pts,duration:durationValid ? CMTime(value:1,timescale:Int32(fps)) : .invalid,frameProperties:manual ? [kVTEncodeFrameOptionKey_BaseFrameQP:qp] as CFDictionary : nil,sourceFrameRefcon:ticket,infoFlagsOut:nil)
  if status != 0 { if let ticket { Unmanaged<QPTicket>.fromOpaque(ticket).release() }; trace.lock.lock(); trace.errors += 1; trace.pending = max(0,trace.pending-1); trace.lock.unlock() }
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
var output:[String:Any] = ["mode":manual ? "manual" : speed ? "vbr-speed" : vbr ? "vbr" : "average", "limit_seconds":seconds,"valid_duration":durationValid,"set_status":statuses,"vbv_readback":vbvReadback,"readback_status":copyStatus,"readback":readback,"hardware":hwStatus == 0 ? (hardware as Any) : NSNull(),"hardware_required":true,"hardware_status":hwStatus,"prepare":prepare,"errors":trace.errors,"max_inflight":trace.maxPending,"tail_output_ms":max(0,(trace.samples.map{$0["arrival"]!}.max() ?? start)-(phases.last!["end"] as! Double))*1000,"dropped":trace.dropped,"frames":trace.samples.count,"resume_first_second_frames":selected.count,"resume_max_frame_bytes":selected.map{$0["bytes"]!}.max() ?? 0,"resume_max_100ms_pts_bytes":window(selected,"pts"),"resume_max_100ms_arrival_bytes":window(selected,"arrival"),"requested_100ms_bytes":281250,"phases":phases.map{p -> [String:Any] in var v=p;v["start"]=(p["start"] as! Double)-start;v["end"]=(p["end"] as! Double)-start;return v}]
if quality {
 let measurement = LumaQuality(trace.references)
 var decoder: VTDecompressionSession?
 var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { opaque,_,status,_,pixel,pts,_ in
  guard let opaque else { return }
  Unmanaged<LumaQuality>.fromOpaque(opaque).takeUnretainedValue().observe(status,pixel,pts)
 }, decompressionOutputRefCon: Unmanaged.passUnretained(measurement).toOpaque())
 let format = CMSampleBufferGetFormatDescription(trace.encoded.first!)!
 let result = VTDecompressionSessionCreate(allocator:nil,formatDescription:format,decoderSpecification:nil,imageBufferAttributes:[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary,outputCallback:&callback,decompressionSessionOut:&decoder)
 var decodeErrors = 0
 if let decoder {
  for sample in trace.encoded {
   if VTDecompressionSessionDecodeFrame(decoder,sampleBuffer:sample,flags:[],frameRefcon:nil,infoFlagsOut:nil) != 0 { decodeErrors += 1 }
  }
  VTDecompressionSessionWaitForAsynchronousFrames(decoder)
  VTDecompressionSessionInvalidate(decoder)
 }
 output["quality"] = measurement.report(result,decodeErrors)
 output["encoded_bytes"] = trace.samples.reduce(0.0){$0 + $1["bytes"]!}
}
print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),encoding:.utf8)!)

}
}

// Decode after encoding so objective quality work does not perturb encode timing.
final class LumaQuality {
 let references: [Int64: CVPixelBuffer]
 let lock = NSLock()
 var samples = 0, errors = 0, sum: Double = 0, pixels: Double = 0, topSum: Double = 0, topPixels: Double = 0
 var minimum = Double.infinity
 init(_ references: [Int64: CVPixelBuffer]) { self.references = references }
 func observe(_ status: OSStatus, _ pixel: CVPixelBuffer?, _ pts: CMTime) {
  guard let source = references[pts.convertScale(1_000_000_000, method:.default).value] else { return }
  lock.lock(); defer { lock.unlock() }
  guard status == 0, let pixel, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
   CVPixelBufferGetWidth(pixel) == CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(pixel) == CVPixelBufferGetHeight(source) else { errors += 1; return }
  CVPixelBufferLockBaseAddress(source,.readOnly); CVPixelBufferLockBaseAddress(pixel,.readOnly)
  defer { CVPixelBufferUnlockBaseAddress(source,.readOnly); CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
  let a = CVPixelBufferGetBaseAddressOfPlane(source,0)!.assumingMemoryBound(to:UInt8.self)
  let b = CVPixelBufferGetBaseAddressOfPlane(pixel,0)!.assumingMemoryBound(to:UInt8.self)
  let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
  let strideA = CVPixelBufferGetBytesPerRowOfPlane(source,0), strideB = CVPixelBufferGetBytesPerRowOfPlane(pixel,0)
  var squared: Int64 = 0, top: Int64 = 0
  for y in 0..<height {
   let rowA = a.advanced(by:y*strideA), rowB = b.advanced(by:y*strideB)
   for x in 0..<width { let d = Int64(rowA[x])-Int64(rowB[x]); squared += d*d; if y < 256 { top += d*d } }
  }
  let count = Double(width*height)
  sum += Double(squared); pixels += count; topSum += Double(top); topPixels += Double(width*min(256,height)); samples += 1
  minimum = min(minimum,10*log10(65025*count/max(1,Double(squared))))
 }
 func report(_ create: OSStatus,_ decodeErrors: Int) -> [String:Any] {
  ["valid":create == 0 && decodeErrors == 0 && errors == 0 && samples == references.count,
   "samples":samples,"expected_samples":references.count,"create_status":create,"errors":errors+decodeErrors,
   "luma_psnr_db":10*log10(65025*max(1,pixels)/max(1,sum)),"top_256_rows_luma_psnr_db":10*log10(65025*max(1,topPixels)/max(1,topSum)),
   "minimum_frame_luma_psnr_db":minimum.isFinite ? minimum : 0,
   "scope":"Sampled luma PSNR and top strip only; not full color, text readability or subjective quality acceptance."]
 }
}
