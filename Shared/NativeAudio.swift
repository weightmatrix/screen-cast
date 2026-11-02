import Foundation
import AVFoundation
import CoreMedia
import WebRTC

/// Two mono buses remain separate until local playback: page on left, mic on right.
/// Bounded PCM queues prevent audio from accumulating behind the live video.
final class NativeAudioInput {
    private let lock = NSLock()
    private var page: [Int16] = [], mic: [Int16] = []
    private let perf = StreamPerformance("native.audio.input")
    private var converters: [Bool: AVAudioConverter] = [:]
    private var inputFormats: [Bool: AVAudioFormat] = [:]
    private var pageReady = Set<UUID>()
    private var pageEdges: [UUID: ScreenAudioEdge] = [:]
    private var cursors: [UUID: (Int, Int)] = [:]
    private var pageBase = 0, micBase = 0
    private var pageEnabled = false, micEnabled = false
    private let conversion = DispatchQueue(label: "casting.audio.convert")
    private let slots = DispatchSemaphore(value: 2)
    func configure(page: Bool, microphone: Bool) {
        lock.lock(); pageEnabled = page; micEnabled = microphone
        if !page { pageBase += self.page.count; self.page.removeAll(); pageReady.removeAll() }; if !microphone { micBase += mic.count; mic.removeAll() }; lock.unlock()
    }
    func append(_ sample: CMSampleBuffer, microphone: Bool) {
        lock.lock(); let enabled = microphone ? micEnabled : pageEnabled; lock.unlock()
        guard enabled else { return }
        guard slots.wait(timeout: .now()) == .success else { perf.record(microphone ? "micCaptureDrop" : "pageCaptureDrop"); return }
        conversion.async {
            defer { self.slots.signal() }
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd),
                  let normalized = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true) else { return }
            if self.inputFormats[microphone] != format {
                self.inputFormats[microphone] = format
                self.converters[microphone] = AVAudioConverter(from: normalized, to: target)
                self.converters[microphone]?.primeMethod = .none
                PerformanceDisk.shared.write("audio.input bus=\(microphone ? "mic" : "page") rate=\(format.sampleRate) channels=\(format.channelCount) interleaved=\(format.isInterleaved) format=\(format.commonFormat.rawValue) fourcc=\(asbd.pointee.mFormatID) flags=\(String(asbd.pointee.mFormatFlags, radix: 16)) bits=\(asbd.pointee.mBitsPerChannel) bytesPerFrame=\(asbd.pointee.mBytesPerFrame)")
            }
            guard let converter = self.converters[microphone] else { return }
            var needed = 0
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
                bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: 0, blockBufferOut: nil) == noErr else { return }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
            var retained: CMBlockBuffer?
            defer { withExtendedLifetime(retained) {} }
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
                bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retained) == noErr,
                  let values = ScreenAudioPCM.mono(asbd.pointee, buffers: list, frames: CMSampleBufferGetNumSamples(sample)),
                  let input = AVAudioPCMBuffer(pcmFormat: normalized, frameCapacity: AVAudioFrameCount(values.count)),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(values.count) * 48000 / format.sampleRate + 32)) else { return }
            input.frameLength = AVAudioFrameCount(values.count)
            guard let samples = input.floatChannelData?[0] else { return }
            values.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: $0.count) }
            var supplied = false; var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard status != .error, error == nil, let pcm = output.int16ChannelData?[0] else { return }
            let converted = Array(UnsafeBufferPointer(start: pcm, count: Int(output.frameLength)))
            self.lock.lock(); defer { self.lock.unlock() }
            if microphone, self.micEnabled { self.mic.append(contentsOf: converted); let drop = max(0, self.mic.count - 4800); self.mic.removeFirst(drop); self.micBase += drop }
            if !microphone, self.pageEnabled { self.page.append(contentsOf: converted); let drop = max(0, self.page.count - 4800); self.page.removeFirst(drop); self.pageBase += drop }
        }
    }
    func read(frames: Int, consumer: UUID) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let old = cursors[consumer] ?? (pageBase + max(0, page.count - 2880), micBase + max(0, mic.count - frames))
        var p = max(0, min(page.count, old.0 - pageBase))
        let m = max(0, min(mic.count, old.1 - micBase))
        if !pageReady.contains(consumer), page.count - p >= 2880 {
            p = max(p, page.count - 2880); pageReady.insert(consumer)
        }
        let pageAvailable = page.count - p
        let pn = pageReady.contains(consumer) && pageAvailable >= frames ? frames : 0
        let mn = min(frames, mic.count - m)
        if pageEnabled, pageReady.contains(consumer), pn == 0 {
            pageReady.remove(consumer); perf.record("pageUnderrun")
        }
        var out = [Int16](repeating: 0, count: frames * 2)
        var edge = pageEdges[consumer] ?? ScreenAudioEdge()
        let softened = edge.apply(pn > 0 ? Array(page[p..<(p + pn)]) : [], frames: frames)
        pageEdges[consumer] = edge
        for n in 0..<frames { out[n * 2] = pageEnabled ? softened[n] : 0 }
        for n in 0..<mn { out[n * 2 + 1] = mic[m + n] }
        cursors[consumer] = (pageBase + p + pn, micBase + m + mn)
        return out
    }
    func remove(consumer: UUID) { lock.lock(); cursors.removeValue(forKey: consumer); pageReady.remove(consumer); pageEdges.removeValue(forKey: consumer); lock.unlock() }

}

private final class AudioRenderStorage {
    let capacity = 8192
    let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: 16384)
    init() { pcm.initialize(repeating: 0, count: 16384) }
    deinit { pcm.deallocate() }
}

final class NativeAudioDevice: NSObject, RTCAudioDevice {
    #if DEBUG
    var onVerificationPCM: (([Int16], [Float]) -> Void)?
    #endif
    let input: NativeAudioInput?
    private let consumer = UUID()
    private let queue = DispatchQueue(label: "casting.audio.clock", qos: .userInteractive)
    private var delegate: (any RTCAudioDeviceDelegate)?
    private var timer: DispatchSourceTimer?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let state = NSLock()
    #if os(macOS)
    private var recordingHandler: ((UnsafeBufferPointer<Float>, Double) -> Void)?
    func recordPlayback(_ handler: ((UnsafeBufferPointer<Float>, Double) -> Void)?) {
        state.lock(); recordingHandler = handler; state.unlock()
    }
    #endif
    private var page = true, mic = true
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isRecordingInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecording = false
    var deviceInputSampleRate: Double { 48000 }
    var deviceOutputSampleRate: Double { 48000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 2 }
    var outputNumberOfChannels: Int { 2 }
    var inputLatency: TimeInterval { 0.01 }
    var outputLatency: TimeInterval { 0.01 }
    init(input: NativeAudioInput?) { self.input = input; super.init() }
    func receive(page: Bool, microphone: Bool) { state.lock(); self.page = page; mic = microphone; state.unlock() }
    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        queue.sync { self.delegate = delegate; isInitialized = true
            guard input != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        }; return true
    }
    func terminateDevice() -> Bool {
        queue.sync { timer?.cancel(); timer = nil; engine?.stop(); sourceNode = nil; engine = nil
            input?.remove(consumer: consumer); delegate = nil; isInitialized = false; isPlaying = false; isRecording = false
        }; return true
    }
    func initializePlayout() -> Bool { queue.sync { isPlayoutInitialized = true }; return true }
    func initializeRecording() -> Bool { queue.sync { isRecordingInitialized = true }; return true }
    func startRecording() -> Bool { queue.sync { isRecording = true }; return true }
    func stopRecording() -> Bool { queue.sync { isRecording = false }; return true }
    func startPlayout() -> Bool {
        queue.sync {
            guard input == nil else { return }
            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { PerformanceDisk.shared.write("audio.playback sessionError=\(error)"); return }
            #endif
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return }
            let engine = AVAudioEngine(), storage = AudioRenderStorage()
            // Pull PCM only when the hardware requests it. Never consume and
            // discard decoded audio because a software-scheduled queue is full.
            let node = AVAudioSourceNode(format: format) { [weak self, storage] silence, timestamp, frames, output in
                guard let self, let delegate = self.delegate, frames <= storage.capacity else {
                    for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                    silence.pointee = true; return noErr
                }
                var flags = AudioUnitRenderActionFlags()
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: frames * 4, mData: storage.pcm))
                let status = delegate.getPlayoutData(&flags, timestamp, 0, frames, &list)
                self.state.lock(); let page = self.page, mic = self.mic; self.state.unlock()
                let gain: Float = page && mic ? 0.5 : 1
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    guard let target = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for n in 0..<Int(frames) {
                        let value = status == noErr ? (page ? Int(storage.pcm[n * 2]) : 0) + (mic ? Int(storage.pcm[n * 2 + 1]) : 0) : 0
                        target[n] = Float(value) / 32768 * gain
                    }
                }
                silence.pointee = ObjCBool(!page && !mic)
                #if os(macOS)
                self.state.lock(); let record = self.recordingHandler; self.state.unlock()
                if status == noErr, let record, let buffer = UnsafeMutableAudioBufferListPointer(output).first,
                   let floats = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    let time = timestamp.pointee.mFlags.contains(.hostTimeValid)
                        ? AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) : CACurrentMediaTime()
                    record(UnsafeBufferPointer(start: floats, count: Int(frames)), time)
                }
                #endif
                #if DEBUG
                if let verify = self.onVerificationPCM, let buffer = UnsafeMutableAudioBufferListPointer(output).first,
                   let floats = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    verify(Array(UnsafeBufferPointer(start: storage.pcm, count: Int(frames) * 2)), Array(UnsafeBufferPointer(start: floats, count: Int(frames))))
                }
                #endif
                return noErr
            }
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
            do { try engine.start(); self.engine = engine; sourceNode = node; isPlaying = true }
            catch { PerformanceDisk.shared.write("audio.playback startError=\(error)") }
        }; return isPlaying || input != nil
    }
    func stopPlayout() -> Bool { queue.sync { isPlaying = false; engine?.stop(); sourceNode = nil; engine = nil }; return true }
    private func tick() {
        guard let delegate else { return }
        var flags = AudioUnitRenderActionFlags(); var timestamp = AudioTimeStamp()
        if isRecording, let input {
            var pcm = input.read(frames: 480, consumer: consumer)
            pcm.withUnsafeMutableBytes { bytes in
                // The SDK's prefilled-buffer path sizes stereo as frameCount,
                // losing half the PCM. Its render callback allocates channels*frames.
                _ = delegate.deliverRecordedData(&flags, &timestamp, 0, 480, nil, nil) { _, _, _, _, list, _ in
                    guard let target = list.pointee.mBuffers.mData else { return -1 }
                    memcpy(target, bytes.baseAddress!, min(Int(list.pointee.mBuffers.mDataByteSize), bytes.count))
                    return noErr
                }
            }
        }
    }
}
