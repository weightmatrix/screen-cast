import Foundation
import CoreImage
import AVFoundation

// Standalone CLI: isolated ports/random matching code, no normal broadcast.
final class DiagLog { static func log(_ tag: String, _ text: String) {} }

@main enum NativeRecoveryRecordingCheck {
    @MainActor static func main() async throws {
        let code = MatchingCode.generate()
        let server = CastingServer(port: 19346, accessCode: code)
        server.configureNative(bitrate: 8_000_000, fps: 30)
        server.nativeSource.audio.configure(page: true, microphone: false)
        server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("touping-native-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The CLI injects its directory without touching the user's saved choice.
        let recorder = LocalLessonRecorder(folder: folder)
        let client = MacReceiverClient(recorder: recorder)
        defer { client.disconnect() }
        recorder.start()
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { fatalError("pixel allocation") }
        CIContext().render(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)), to: pixel)
        var audioOffset = 0
        func pump(frames: Int) async {
            for _ in 0..<frames {
                server.nativeSource.append(pixel)
                for _ in 0..<3 {
                    let pcm = (0..<480).map { Int16(6000 * sin(2 * .pi * 440 * Double(audioOffset + $0) / 48000)) }
                    if let sample = audioSample(pcm, offset: audioOffset) { server.nativeSource.audio.append(sample, microphone: false) }
                    audioOffset += 480
                }
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
        client.connect(host: "127.0.0.1", port: 19346, code: code)
        for _ in 0..<20 {
            await pump(frames: 30)
            if client.frameCount >= 60 { break }
        }
        NSLog("NativeCheck initial frames=%ld status=%@", client.frameCount, String(describing: client.status))
        precondition(client.frameCount >= 60, "Initial native receive failed: \(client.status)")
        await pump(frames: 60)
        server.stop()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        server.start()
        for _ in 0..<20 {
            await pump(frames: 30)
            if client.frameCount >= 60 { break }
        }
        NSLog("NativeCheck recovered frames=%ld status=%@", client.frameCount, String(describing: client.status))
        precondition(client.frameCount >= 60 && client.status == .connected, "Automatic reconnect failed: \(client.status)")
        client.disconnect()
        await pump(frames: 60)
        precondition(client.status == .idle && client.frameCount == 0 && client.recoveryMessage.isEmpty, "Manual stop revived")
        recorder.stop(); server.stop()
        for _ in 0..<200 {
            if !recorder.isSaving { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        precondition(files.count == 1, "Reconnect must keep one whole lesson: \(recorder.message)")
        let asset = AVURLAsset(url: files[0])
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        precondition(audio.count == 1 && video.count == 1 && !recorder.isSaving)
        let range = try await audio[0].load(.timeRange)
        precondition(range.duration.seconds > 1, "Actual WebRTC playback must reach AAC track")
        print("PASS native H264 receive, transport loss/reconnect, manual stop and WebRTC playback→AAC MP4; files=\(folder.path)")
    }

    static func audioSample(_ values: [Int16], offset: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?, block: CMBlockBuffer?, sample: CMSampleBuffer?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format,
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: values.count * 2, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: values.count * 2, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48000), decodeTimeStamp: .invalid)
        var size = 2
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: values.count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
