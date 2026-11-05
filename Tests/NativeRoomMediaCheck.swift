import Foundation
import CoreMedia
import CoreImage

private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [[Float]] = [[], []]
    func append(_ index: Int, _ values: [Float]) { lock.lock(); buffers[index].append(contentsOf: values); if buffers[index].count > 96000 { buffers[index].removeFirst(buffers[index].count - 96000) }; lock.unlock() }
    func snapshot(_ index: Int) -> [Float] { lock.lock(); defer { lock.unlock() }; return buffers[index] }
}

@main @MainActor enum NativeRoomMediaCheck {
    static func sample(_ frequency: Double, offset: Int) -> CMSampleBuffer? {
        let values = (0..<480).map { Int16(6000 * sin(2 * .pi * frequency * Double(offset + $0) / 48000)) }
        let bytes = values.withUnsafeBytes { Data($0) }
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?, block: CMBlockBuffer?, sample: CMSampleBuffer?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block, let format else { return nil }
        bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48000), decodeTimeStamp: .invalid), size = 2
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
    static func amplitude(_ values: [Float], frequency: Double) -> Double {
        let data = Array(values.suffix(24000)); guard !data.isEmpty else { return 0 }
        var sine = 0.0, cosine = 0.0
        for (index, value) in data.enumerated() { let phase = 2 * .pi * frequency * Double(index) / 48000; sine += Double(value) * sin(phase); cosine += Double(value) * cos(phase) }
        return 2 * hypot(sine, cosine) / Double(data.count)
    }
    static func main() async {
        if ProcessInfo.processInfo.arguments.contains("--source-audio") { await NativeAudioVerification.run(); return }
        let source = NativeScreenSource(), a = NativeVideoPeer(source: source, internet: false), b = NativeVideoPeer(source: source, internet: false)
        let ra = NativeVideoPeer(internet: false), rb = NativeVideoPeer(internet: false)
        let ma = NativeAudioInput(), mb = NativeAudioInput(); ma.configure(page: false, microphone: true); mb.configure(page: false, microphone: true)
        a.configureRoomVerification(); b.configureRoomVerification(); ra.configureRoomVerification(microphone: ma); rb.configureRoomVerification(microphone: mb)
        func forward(_ packet: [String: Any], to target: NativeVideoPeer, label: String) {
            if let sdp = packet["sdp"] as? String {
                let audio = sdp.components(separatedBy: "m=").first { $0.hasPrefix("audio") } ?? ""
                let direction = audio.components(separatedBy: "\r\n").filter { ["a=sendrecv","a=sendonly","a=recvonly","a=inactive"].contains($0) }
                print("NativeRoom SDP \(label) audio=\(direction)")
            }
            target.receive(packet)
        }
        a.sendSignal = { [weak ra] in if let ra { forward($0, to: ra, label:"offer-a") } }; ra.sendSignal = { [weak a] in if let a { forward($0, to: a, label:"answer-a") } }
        b.sendSignal = { [weak rb] in if let rb { forward($0, to: rb, label:"offer-b") } }; rb.sendSignal = { [weak b] in if let b { forward($0, to: b, label:"answer-b") } }
        let captured = Samples(); ra.onVerificationAudio = { _, mixed in captured.append(0, mixed) }; rb.onVerificationAudio = { _, mixed in captured.append(1, mixed) }
        var errors: [String] = [], connected = 0
        for peer in [a,b,ra,rb] { peer.onError = { errors.append($0) }; peer.onConnected = { connected += 1 } }
        defer { for peer in [a,b,ra,rb] { peer.stop() } }
        a.offer(); b.offer()
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { exit(1) }; CIContext().render(CIImage(color: .black).cropped(to: CGRect(x:0,y:0,width:320,height:180)), to: pixel)
        for _ in 0..<300 { source.append(pixel); if connected == 4 { break }; if !errors.isEmpty { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
        guard connected == 4, errors.isEmpty else { print("FAIL room native negotiation", connected, errors); exit(1) }
        // Model two separate receiver processes without recording any real microphone.
        let alice = UUID().uuidString, bob = UUID().uuidString
        for _ in 0..<30 {
            _ = ra.sendRoomVerification(["kind":"hello","participant":alice,"nickname":"Alice-test"])
            _ = rb.sendRoomVerification(["kind":"hello","participant":bob,"nickname":"Bob-test"])
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        VoiceRoom.shared.identify(ra.diagnosticID, participant:"host-a-test")
        VoiceRoom.shared.identify(rb.diagnosticID, participant:"host-b-test")
        let id = UUID().uuidString
        var delivered = [false, false]
        ra.onVerificationRoomMessage = { if $0["id"] as? String == id { delivered[0] = true } }
        rb.onVerificationRoomMessage = { if $0["id"] as? String == id { delivered[1] = true } }
        guard ra.sendRoomVerification(["kind":"chat","id":id,"text":"Synthetic real SCTP room message"]) else { print("FAIL room data channel"); exit(1) }
        for _ in 0..<30 { if RoomSession.shared.messages.contains(where: { $0.id == id }) && delivered.allSatisfy({ $0 }) { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
        guard delivered.allSatisfy({ $0 }), RoomSession.shared.messages.contains(where: { $0.id == id && $0.author == "Alice-test" }) else { print("FAIL real SCTP nickname/message routing"); exit(1) }
        let start = ProcessInfo.processInfo.systemUptime; var offset = 0
        while ProcessInfo.processInfo.systemUptime - start < 4 {
            let due = Int((ProcessInfo.processInfo.systemUptime - start) * 48000)
            while offset + 480 <= due {
                if let sample = sample(440, offset: offset) { ma.append(sample, microphone: true) }
                if let sample = sample(880, offset: offset) { mb.append(sample, microphone: true) }
                offset += 480
            }
            source.append(pixel); try? await Task.sleep(nanoseconds: 10_000_000)
        }
        print("NativeRoom host-a", a.roomAudioVerificationSummary())
        print("NativeRoom host-b", b.roomAudioVerificationSummary())
        print("NativeRoom receiver-a", ra.roomAudioVerificationSummary())
        print("NativeRoom receiver-b", rb.roomAudioVerificationSummary())
        print("NativeRoom synthetic input peaks", ma.read(frames: 480, consumer: UUID()).map { abs(Int($0)) }.max() ?? 0, mb.read(frames: 480, consumer: UUID()).map { abs(Int($0)) }.max() ?? 0)
        let aliceSamples = captured.snapshot(0), bobSamples = captured.snapshot(1)
        let aa = amplitude(aliceSamples, frequency:440), ab = amplitude(aliceSamples, frequency:880)
        let ba = amplitude(bobSamples, frequency:440), bb = amplitude(bobSamples, frequency:880)
        print("NativeRoom sample counts a=\(aliceSamples.count) b=\(bobSamples.count)")
        print("NativeRoom spectral a-own=\(aa) a-other=\(ab) b-other=\(ba) b-own=\(bb)")
        guard ab > 0.002, ba > 0.002, ab > aa * 3, ba > bb * 3 else { print("FAIL Opus uplink/shared mix-minus"); exit(1) }
        func pump(seconds: Double) async {
            let start = ProcessInfo.processInfo.systemUptime
            var counter = 0
            while ProcessInfo.processInfo.systemUptime - start < seconds {
                let due = Int((ProcessInfo.processInfo.systemUptime - start) * 48000)
                while counter + 480 <= due {
                    if let value = sample(440, offset: offset) { ma.append(value, microphone: true) }
                    if let value = sample(880, offset: offset) { mb.append(value, microphone: true) }
                    counter += 480; offset += 480
                }
                source.append(pixel); try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        ra.configureRoomVerification(microphone: nil)
        await pump(seconds: 2)
        let closedA = amplitude(captured.snapshot(1), frequency: 440)
        let activeB = amplitude(captured.snapshot(0), frequency: 880)
        print("NativeRoom receiver mute a-to-b=\(closedA) b-to-a=\(activeB)")
        guard closedA < 0.002, activeB > 0.002 else { print("FAIL independent receiver microphone mute"); exit(1) }
        VoiceRoom.shared.setEnabled(false)
        await pump(seconds: 2)
        let mutedA = amplitude(captured.snapshot(0), frequency: 880), mutedB = amplitude(captured.snapshot(1), frequency: 440)
        print("NativeRoom owner mute a=\(mutedA) b=\(mutedB)")
        guard mutedA < 0.002, mutedB < 0.002 else { print("FAIL owner shared voice mute"); exit(1) }
        VoiceRoom.shared.setEnabled(true)
        print("PASS real local H264/Opus negotiation, bounded SCTP chat/nickname, two receiver microphone uplinks, mix-minus and independent/owner mute; no hardware microphone and muted hardware output")
    }
}
