import Foundation
import AVFoundation
import Combine
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

struct RoomAudioDevice: Identifiable { let id: String; let name: String }

final class RoomAudioSettings: ObservableObject {
    static let shared = RoomAudioSettings()
    @Published var inputs: [RoomAudioDevice] = []
    @Published var outputs: [RoomAudioDevice] = []
    @Published var microphoneEnabled = false
    @Published var testing = false
    @Published var error = ""
    @Published var inputLevel: Float = 0
    @Published var outputLevel: Float = 0
    @Published var receivesVoices = true {
        didSet {
            VoiceRoom.shared.setEnabled(receivesVoices); UserDefaults.standard.set(receivesVoices, forKey: "room.receiveVoices")
            #if os(iOS)
            if Bundle.main.bundleURL.pathExtension != "appex" { BroadcastSettings.store.set(receivesVoices, forKey: "room.receiveVoices") }
            #endif
        }
    }
    private let lock = NSLock()
    private var uplink = false
    var sendsMicrophone: Bool { lock.lock(); defer { lock.unlock() }; return uplink }
    private var measuredInput: Float = 0, measuredOutput: Float = 0
    private var timer: Timer?
    let microphone = NativeAudioInput()
    private let captureQueue = DispatchQueue(label: "casting.room.microphone")
    private var capture: AVCaptureSession?
    private var senderMicrophones = Set<String>()
    func requestSenderMicrophone(_ id: String, enabled: Bool) {
        guard senderMicrophones.contains(id) != enabled else { return }
        if enabled { senderMicrophones.insert(id) } else { senderMicrophones.remove(id) }; updateCapture()
    }
    private var captureGeneration = UUID()
    private var captureDelegate: MicrophoneSamples?
    var inputID: String { UserDefaults.standard.string(forKey: "room.inputDevice") ?? "" }
    var outputID: String { UserDefaults.standard.string(forKey: "room.outputDevice") ?? "" }
    private init() {
        microphone.configure(page: false, microphone: true)
        if UserDefaults.standard.object(forKey: "room.receiveVoices") != nil { receivesVoices = UserDefaults.standard.bool(forKey: "room.receiveVoices") }
        VoiceRoom.shared.setEnabled(receivesVoices)
    }
    func measure(_ level: Float, input: Bool) {
        lock.lock(); if input { measuredInput = max(measuredInput, level) } else { measuredOutput = max(measuredOutput, level) }; lock.unlock()
    }
    func beginMetering() {
        refreshDevices()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let input = self.measuredInput, output = self.measuredOutput
            self.measuredInput = 0; self.measuredOutput = 0; self.lock.unlock()
            self.inputLevel = min(1, max(input, self.inputLevel * 0.7)); self.outputLevel = min(1, max(output, self.outputLevel * 0.7))
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func refreshDevices() {
        #if os(macOS)
        inputs = AVCaptureDevice.devices(for: .audio).map { RoomAudioDevice(id: $0.uniqueID, name: $0.localizedName) }
        outputs = Self.macOutputs()
        #else
        inputs = (AVAudioSession.sharedInstance().availableInputs ?? []).map { RoomAudioDevice(id: $0.uid, name: $0.portName) }
        outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { RoomAudioDevice(id: $0.uid, name: $0.portName) }
        #endif
    }
    func selectInput(_ id: String) {
        UserDefaults.standard.set(id, forKey: "room.inputDevice")
        #if os(iOS)
        BroadcastSettings.store.set(id, forKey: "room.inputDevice")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredInput(id.isEmpty ? nil : session.availableInputs?.first { $0.uid == id })
        } catch { self.error = "iPad麦克风路由由系统控制，当前设备选择未生效" }
        #endif
        NotificationCenter.default.post(name: .roomAudioDevicesChanged, object: nil)
        if microphoneEnabled || testing || !senderMicrophones.isEmpty { updateCapture() }
    }
    func selectOutput(_ id: String) {
        UserDefaults.standard.set(id, forKey: "room.outputDevice")
        if let hostEngine { do { try Self.applyOutput(hostEngine) } catch { self.error = "切换共用语音输出失败，请选择系统默认" } }
        NotificationCenter.default.post(name: .roomAudioDevicesChanged, object: nil)
    }
    func setMicrophone(_ value: Bool) { lock.lock(); uplink = value; lock.unlock(); microphoneEnabled = value; updateCapture() }
    func setTesting(_ value: Bool) { testing = value; updateCapture() }
    private func isCurrentCapture(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return captureGeneration == value }
    private func captureFailed(_ message: String) {
        lock.lock(); uplink = false; lock.unlock(); microphoneEnabled = false; testing = false; senderMicrophones.removeAll(); error = message; updateCapture()
    }
    func updateCapture() {
        let generation = UUID(); lock.lock(); captureGeneration = generation; lock.unlock()
        let needed = microphoneEnabled || testing || !senderMicrophones.isEmpty
        guard needed else {
            captureQueue.async { [weak self] in self?.capture?.stopRunning(); self?.capture = nil; self?.captureDelegate = nil }
            inputLevel = 0; return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async { if allowed, self.isCurrentCapture(generation) { self.updateCapture() } else if self.isCurrentCapture(generation) { self.captureFailed("未获得麦克风权限") } }
            }; return
        }
        guard status == .authorized else { captureFailed("请在系统设置允许麦克风访问"); return }
        let inputID = self.inputID
        captureQueue.async { [weak self] in
            guard let self, self.isCurrentCapture(generation) else { return }
            self.capture?.stopRunning(); self.capture = nil
            do {
                #if os(iOS)
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                try audio.setActive(true)
                try audio.setPreferredInput(inputID.isEmpty ? nil : audio.availableInputs?.first { $0.uid == inputID })
                let device = AVCaptureDevice.default(for: .audio)
                #else
                let device = inputID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice.devices(for: .audio).first { $0.uniqueID == inputID }
                #endif
                guard let device else { throw NSError(domain: "RoomAudio", code: 1) }
                let session = AVCaptureSession()
                #if os(iOS)
                session.automaticallyConfiguresApplicationAudioSession = false
                #endif
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput(), delegate = MicrophoneSamples(input: self.microphone)
                guard session.canAddInput(input), session.canAddOutput(output) else { throw NSError(domain: "RoomAudio", code: 2) }
                session.addInput(input); session.addOutput(output)
                output.setSampleBufferDelegate(delegate, queue: self.captureQueue)
                self.captureDelegate = delegate; self.capture = session; session.startRunning()
                guard session.isRunning else { throw NSError(domain: "RoomMicrophoneStart", code: 1) }
                DispatchQueue.main.async { self.error = ""; self.refreshDevices() }
            } catch { DispatchQueue.main.async { if self.isCurrentCapture(generation) { self.captureFailed("麦克风设备启动失败，请刷新设备或选择系统默认") } } }
        }
    }
    func prepareBroadcastPreferences() {
        #if os(iOS)
        BroadcastSettings.store.set(UserDefaults.standard.string(forKey: "room.nickname") ?? "", forKey: "room.nickname")
        BroadcastSettings.store.set(receivesVoices, forKey: "room.receiveVoices")
        BroadcastSettings.store.set(inputID, forKey: "room.inputDevice")
        #endif
    }
    #if os(iOS)
    private var appliedBroadcastInput: String?
    func applyBroadcastInput() {
        guard Bundle.main.bundleURL.pathExtension == "appex" else { return }
        let id = BroadcastSettings.store.string(forKey: "room.inputDevice") ?? ""
        guard id != appliedBroadcastInput else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            if !id.isEmpty, session.availableInputs?.contains(where: { $0.uid == id }) != true { return }
            try session.setPreferredInput(id.isEmpty ? nil : session.availableInputs?.first { $0.uid == id }); appliedBroadcastInput = id
        } catch { appliedBroadcastInput = id; BroadcastSettings.store.set("广播麦克风路由未能切换，请使用系统音频路由", forKey: "room.audioError") }
    }
    #endif
    private var hostPlaybackUsers = Set<String>()
    private var hostEngine: AVAudioEngine?
    private var hostNode: AVAudioSourceNode?
    func startHostPlayback(_ peer: String) {
        hostPlaybackUsers.insert(peer)
        guard hostEngine == nil, let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return }
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth]); try AVAudioSession.sharedInstance().setActive(true) }
        catch { self.error = "共用语音播放路由不可用"; return }
        #endif
        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: format) { _, _, frames, output in
            let samples = VoiceRoom.shared.mix(excluding: "room-owner-speaker", frames: Int(frames))
            var peak: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                guard let target = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<Int(frames) { let value = index < samples.count ? Float(samples[index]) / 32768 : 0; target[index] = value; peak = max(peak, abs(value)) }
            }
            RoomAudioSettings.shared.measure(peak, input: false)
            return noErr
        }
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try Self.applyOutput(engine); try engine.start(); hostNode = node; hostEngine = engine }
        catch { self.error = "共用语音播放失败，请检查声音输出设备" }
    }
    func stopHostPlayback(_ peer: String) {
        hostPlaybackUsers.remove(peer)
        if hostPlaybackUsers.isEmpty { hostEngine?.stop(); hostEngine = nil; hostNode = nil; VoiceRoom.shared.remove("room-owner-speaker") }
    }
    private var testEngine: AVAudioEngine?
    private var testNode: AVAudioPlayerNode?
    func testSpeaker() {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000), let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 12000
        for n in 0..<12000 { samples[n] = sin(Float(n) * 2 * .pi * 440 / 48000) * 0.08 * min(1, Float(n) / 480) * min(1, Float(12000 - n) / 480) }
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try Self.applyOutput(engine); try engine.start(); testEngine = engine; testNode = node
            node.scheduleBuffer(buffer, completionHandler: nil); node.play(); measure(0.4, input: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak engine] in if self?.testEngine === engine { self?.testNode?.stop(); self?.testEngine?.stop(); self?.testNode = nil; self?.testEngine = nil } }
        } catch { self.error = "声音设备测试失败，请选择系统默认输出" }
    }
    static func applyOutput(_ engine: AVAudioEngine) throws {
        #if os(macOS)
        let uid = UserDefaults.standard.string(forKey: "room.outputDevice") ?? ""
        let device: AudioDeviceID?
        if uid.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
            device = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
        } else { device = macOutputIDs().first { deviceUID($0) == uid } }
        guard let device, let unit = engine.outputNode.audioUnit else { throw NSError(domain: "RoomAudioOutput", code: 1) }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        #endif
    }
    #if os(macOS)
    private static func property(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value as String
    }
    private static func deviceUID(_ device: AudioDeviceID) -> String { property(device, selector: kAudioDevicePropertyDeviceUID) }
    private static func macOutputIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            var stream = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &stream, 0, nil, &bytes) == noErr && bytes > 0
        }
    }
    private static func macOutputs() -> [RoomAudioDevice] { macOutputIDs().map { RoomAudioDevice(id: deviceUID($0), name: property($0, selector: kAudioObjectPropertyName)) }.filter { !$0.id.isEmpty } }
    #endif
}

private final class MicrophoneSamples: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let input: NativeAudioInput
    init(input: NativeAudioInput) { self.input = input }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { input.append(sampleBuffer, microphone: true) }
}
extension Notification.Name { static let roomAudioDevicesChanged = Notification.Name("touping.roomAudioDevicesChanged") }
