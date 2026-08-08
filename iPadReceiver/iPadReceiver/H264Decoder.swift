import Foundation
import UIKit
import Combine
import AVFoundation
import CoreMedia
import VideoToolbox

final class ImageDecoder: ObservableObject {
    @Published var diagText = "等待画面"
    @Published var isH264 = false

    var onImageUpdate: ((UIImage?) -> Void)?

    private var frameCount = 0
    private var h264FormatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var h264Pts = CMTime(value: 0, timescale: 600)
    private let ciContext = CIContext()

    func setH264Serialized(_ payload: Data) {
        guard payload.count >= 5 else { return }
        let fdLen = Int(payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        let fdData = payload.copySlice(4, fdLen)
        guard !fdData.isEmpty else { return }
        guard let desc = deserializeFormatDescription(fdData) else {
            DispatchQueue.main.async { [weak self] in self?.diagText = "FD反序列化失败" }
            return
        }
        if let s = decompressionSession { VTDecompressionSessionInvalidate(s); decompressionSession = nil }
        let status = createDecompressionSession(desc)
        if status != noErr {
            DispatchQueue.main.async { [weak self] in self?.diagText = "VTDS:\(status)" }
            return
        }
        h264FormatDesc = desc
        h264Pts = CMTime(value: 0, timescale: 600)
        frameCount = 0
        isH264 = true
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        DispatchQueue.main.async { [weak self] in
            self?.diagText = "H264 OK \(dims.width)x\(dims.height)"
        }
    }

    func setH264Config(sps: Data, pps: Data) {}

    func decodeFrame(_ data: Data) {
        if isH264 {
            decodeH264(data)
        } else {
            decodeJPEG(data)
        }
    }

    private func decodeJPEG(_ data: Data) {
        guard let img = UIImage(data: data) else { return }
        frameCount += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onImageUpdate?(img)
            if self.frameCount % 60 == 0 {
                self.diagText = "JPEG 帧:\(self.frameCount)"
            }
        }
    }

    private func decodeH264(_ annexBData: Data) {
        guard let desc = h264FormatDesc, let session = decompressionSession else { return }
        let avcc = Self.annexBToAVCC(annexBData)
        guard !avcc.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.feedH264(data: avcc, formatDesc: desc, session: session)
        }
    }

    static func annexBToAVCC(_ data: Data) -> Data {
        let n = data.count
        guard n > 4 else { return Data() }
        var output = Data(capacity: n + 32)

        func nalTypeAt(_ i: Int) -> Int { Int(data[i]) & 0x1F }

        func isStartCode(at j: Int) -> Int {
            if j + 4 <= n, data[j] == 0, data[j + 1] == 0, data[j + 2] == 0, data[j + 3] == 1 { return 4 }
            if j + 3 <= n, data[j] == 0, data[j + 1] == 0, data[j + 2] == 1 { return 3 }
            return 0
        }

        func nextStartCode(from i: Int) -> Int? {
            var j = i
            while j + 3 <= n {
                if isStartCode(at: j) > 0 { return j }
                j += 1
            }
            return nil
        }

        var start = nextStartCode(from: 0) ?? 0
        while let end = nextStartCode(from: start + 4) {
            let nalStart = start + isStartCode(at: start)
            if end > nalStart {
                let nalLength = end - nalStart
                var len = UInt32(nalLength).bigEndian
                withUnsafeBytes(of: &len) { output.append(contentsOf: $0) }
                output.append(data[nalStart..<end])
            }
            start = end
        }
        let lastNalStart = start + isStartCode(at: start)
        if lastNalStart < n {
            let nalLength = n - lastNalStart
            var len = UInt32(nalLength).bigEndian
            withUnsafeBytes(of: &len) { output.append(contentsOf: $0) }
            output.append(data[lastNalStart..<n])
        }
        return output
    }

    private var enqueueCount = 0

    private func feedH264(data: Data, formatDesc: CMVideoFormatDescription, session: VTDecompressionSession) {
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &blockBuffer)
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

        data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!,
                blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: h264Pts, decodeTimeStamp: h264Pts)
        var sizes = [data.count]
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }

        h264Pts = CMTimeAdd(h264Pts, CMTime(value: 1, timescale: 60))

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self, status == noErr, let imageBuffer else {
                if status != noErr {
                    DispatchQueue.main.async { self?.diagText = "解码err:\(status)" }
                }
                return
            }
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            let img = UIImage(cgImage: cgImage)
            self.enqueueCount += 1
            DispatchQueue.main.async {
                self.onImageUpdate?(img)
                if self.enqueueCount == 1 || self.enqueueCount % 60 == 0 {
                    self.diagText = "H264 帧:\(self.enqueueCount) \(Int(img.size.width))x\(Int(img.size.height))"
                }
            }
        }
    }

    private func createDecompressionSession(_ desc: CMVideoFormatDescription) -> OSStatus {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, let session else { return status }
        decompressionSession = session
        return noErr
    }

    private func deserializeFormatDescription(_ data: Data) -> CMVideoFormatDescription? {
        var desc: CMFormatDescription?
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: nil,
                bigEndianImageDescriptionData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: data.count,
                stringEncoding: 0,
                flavor: .isoFamily,
                formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { return nil }
        return desc
    }

    func reset() {
        if let s = decompressionSession { VTDecompressionSessionInvalidate(s); decompressionSession = nil }
        isH264 = false
        h264FormatDesc = nil
        frameCount = 0
        enqueueCount = 0
        h264Pts = CMTime(value: 0, timescale: 600)
        DispatchQueue.main.async { [weak self] in
            self?.onImageUpdate?(nil)
            self?.diagText = "等待画面"
        }
    }
}
