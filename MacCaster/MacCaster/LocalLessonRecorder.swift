import AppKit
import AVFoundation
import CoreImage
import Combine
import SwiftUI

/// Records the received picture and the locally selected audio mix. Writer work
/// never blocks WebRTC or the audio render thread; only two pictures are retained.
final class LocalLessonRecorder: ObservableObject, @unchecked Sendable {
    @Published private(set) var isArmed = false
    @Published private(set) var message = "未录课"
    @Published private(set) var folder: URL?
    @Published private(set) var lastFile: URL?
    @Published private(set) var isSaving = false
    private let queue = DispatchQueue(label: "casting.lesson.writer", qos: .utility)
    private let lock = NSLock()
    private var accepting = false
    private var generation = UUID()
    private let videoSlots = DispatchSemaphore(value: 2)
    private let audioSlots = DispatchSemaphore(value: 8)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var segment: Segment?
    private var outputFolder: URL?
    private var finishing = 0
    private var scope: URL?
    private var lastVideoTime = -Double.infinity
    private let segmentDuration: TimeInterval
    private static let instances = NSHashTable<LocalLessonRecorder>.weakObjects()

    private final class Segment {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        let pixels: AVAssetWriterInputPixelBufferAdaptor
        let started: Double
        let size: CGSize
        var audioTime = -Double.infinity
        init(folder: URL, size: CGSize, time: Double) throws {
            self.size = size; started = time
            let name = "录课-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).mp4"
            writer = try AVAssetWriter(outputURL: folder.appendingPathComponent(name), fileType: .mp4)
            video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 60]])
            audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
            video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
            pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            guard writer.canAdd(video), writer.canAdd(audio) else { throw RecordingError.message("无法创建录课音视频轨道") }
            writer.add(video); writer.add(audio)
            writer.shouldOptimizeForNetworkUse = true
            guard writer.startWriting() else { throw writer.error ?? RecordingError.message("无法开始写入录课") }
            writer.startSession(atSourceTime: .zero)
        }
    }
    private enum RecordingError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }

    init(folder: URL? = nil, segmentDuration: TimeInterval = 600) {
        self.segmentDuration = segmentDuration
        Self.instances.add(self)
        if let folder { self.folder = folder; return }
        if let data = UserDefaults.standard.data(forKey: "lessonFolderBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                scope = url; _ = url.startAccessingSecurityScopedResource(); self.folder = url
            }
        }
    }

    func chooseFolder() {
        guard !isArmed, !isSaving else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "保存录课到此处"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scope?.stopAccessingSecurityScopedResource(); scope = url
        _ = url.startAccessingSecurityScopedResource(); folder = url
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "lessonFolderBookmark")
        }
    }

    func start() {
        if folder == nil { chooseFolder() }
        guard let folder, !isArmed, !isSaving else { return }
        let token = UUID()
        lock.lock(); generation = token; accepting = true; lock.unlock()
        isArmed = true; message = "等待接收画面，连接后自动录课"
        queue.async {
            self.outputFolder = folder; self.lastVideoTime = -.infinity
        }
    }

    func stop() {
        guard isArmed else { return }
        lock.lock(); accepting = false; lock.unlock()
        isArmed = false; isSaving = true; message = "正在保存录课…"
        queue.async {
            self.finishSegment()
            if self.finishing == 0 { self.publish("已停止录课"); DispatchQueue.main.async { self.isSaving = false } }
        }
    }

    /// A reconnect/rotation starts a new independently playable file.
    func endSegment() {
        queue.async {
            self.finishSegment(); self.lastVideoTime = -.infinity
            if self.ticket() != nil { self.publish("等待接收画面，恢复连接后继续录课") }
        }
    }

    private func ticket() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return accepting ? generation : nil
    }
    private func valid(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }
    func appendVideo(_ image: CIImage, time: Double = CACurrentMediaTime()) {
        guard let token = ticket(), videoSlots.wait(timeout: .now()) == .success else { return }
        queue.async {
            defer { self.videoSlots.signal() }
            guard self.valid(token), let folder = self.outputFolder, time - self.lastVideoTime >= 1.0 / 30 else { return }
            do {
                let extent = image.extent
                guard extent.width.isFinite, extent.height.isFinite, extent.width > 1, extent.height > 1 else { return }
                let scale = min(1, 1920 / max(extent.width, extent.height))
                let size = CGSize(width: max(2, floor(extent.width * scale / 2) * 2), height: max(2, floor(extent.height * scale / 2) * 2))
                if let current = self.segment, current.size != size || time - current.started >= self.segmentDuration { self.finishSegment() }
                if self.segment == nil {
                    guard self.finishing < 2 else { throw RecordingError.message("磁盘保存过慢，录课已停止") }
                    let free = (try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value
                    if let free, free <= 200 * 1024 * 1024 { throw RecordingError.message("剩余空间不足 200 MB，录课已停止") }
                    self.segment = try Segment(folder: folder, size: size, time: time)
                    self.publish("正在录课 · 每 10 分钟自动分段")
                }
                guard let segment = self.segment else { return }
                guard segment.writer.status == .writing else { throw segment.writer.error ?? RecordingError.message("录课写入失败") }
                guard segment.video.isReadyForMoreMediaData, let pool = segment.pixels.pixelBufferPool else { return }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
                let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
                self.context.render(normalized, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
                guard segment.pixels.append(buffer, withPresentationTime: CMTime(seconds: time - segment.started, preferredTimescale: 60000)) else {
                    throw segment.writer.error ?? RecordingError.message("录课视频写入失败")
                }
                self.lastVideoTime = time
            } catch { self.fail(error) }
        }
    }

    func appendAudio(_ samples: [Float], time: Double) {
        guard let token = ticket(), !samples.isEmpty, audioSlots.wait(timeout: .now()) == .success else { return }
        queue.async {
            defer { self.audioSlots.signal() }
            guard self.valid(token), let segment = self.segment, segment.writer.status == .writing,
                  segment.audio.isReadyForMoreMediaData, time >= segment.started, time > segment.audioTime else { return }
            var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return }
            var block: CMBlockBuffer?
            let bytes = samples.count * MemoryLayout<Float>.size
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
            let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            guard copied == noErr else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                presentationTimeStamp: CMTime(seconds: time - segment.started, preferredTimescale: 48000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample) == noErr, let sample else { return }
            if segment.audio.append(sample) { segment.audioTime = time }
            else { self.fail(segment.writer.error ?? RecordingError.message("录课声音写入失败")) }
        }
    }

    func appendAudio(_ samples: UnsafeBufferPointer<Float>, time: Double) {
        guard ticket() != nil else { return }
        appendAudio(Array(samples), time: time)
    }

    private func finishSegment() {
        guard let current = segment else { return }
        segment = nil; finishing += 1
        DispatchQueue.main.async { self.isSaving = true }
        current.video.markAsFinished(); current.audio.markAsFinished()
        current.writer.finishWriting {
            self.queue.async {
                self.finishing -= 1
                if self.finishing == 0 { DispatchQueue.main.async { self.isSaving = false } }
                if current.writer.status == .completed {
                    DispatchQueue.main.async { self.lastFile = current.writer.outputURL }
                    if self.ticket() == nil, self.finishing == 0 { self.publish("录课已保存") }
                } else { self.fail(current.writer.error ?? RecordingError.message("录课文件保存失败")) }
            }
        }
    }
    private func publish(_ text: String) { DispatchQueue.main.async { self.message = text } }
    private func fail(_ error: Error) {
        lock.lock(); accepting = false; generation = UUID(); lock.unlock()
        if let segment { segment.writer.cancelWriting(); self.segment = nil }
        DispatchQueue.main.async { self.isArmed = false; self.message = error.localizedDescription }
    }
    /// Keep AppKit alive until all active files have written their MP4 indexes.
    static func prepareForTermination(_ reply: @escaping () -> Void) -> Bool {
        let pending = instances.allObjects.filter { $0.isArmed || $0.isSaving }
        guard !pending.isEmpty else { return false }
        pending.forEach { $0.stop() }
        Task { @MainActor in
            while pending.contains(where: { $0.isSaving }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            reply()
        }
        return true
    }
    deinit { scope?.stopAccessingSecurityScopedResource() }
}

final class RecordingAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LocalLessonRecorder.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
            ? .terminateLater : .terminateNow
    }
}

struct LocalRecordingControls: View {
    @ObservedObject var recorder: LocalLessonRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本地录课").font(.headline)
            Text(recorder.folder?.path ?? "请先选择录课文件夹").font(.caption).textSelection(.enabled)
            HStack {
                Button("选择文件夹") { recorder.chooseFolder() }.disabled(recorder.isArmed || recorder.isSaving)
                Button(recorder.isArmed ? "停止录课" : "开启自动录课") {
                    if recorder.isArmed { recorder.stop() } else { recorder.start() }
                }.disabled(!recorder.isArmed && recorder.isSaving)
            }
            Text(recorder.message).font(.caption)
            Text("保存接收到的画面及当前接收的声音；MP4，最长边 1920、最高 30 fps，每 10 分钟分段。断线后自动续录为新文件。").font(.caption).foregroundStyle(.secondary)
            if let url = recorder.lastFile {
                Button("显示最近录课") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}
