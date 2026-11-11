import AppKit
import AVFoundation
import CoreImage
import Combine
import SwiftUI

struct RecordingNameFormat {
    var prefix = "录课"
    var year = true
    var month = true
    var time = true
    static func current() -> Self {
        let store = UserDefaults.standard
        return Self(prefix: store.string(forKey: "lesson.namePrefix") ?? "录课",
            year: store.object(forKey: "lesson.nameYear") as? Bool ?? true,
            month: store.object(forKey: "lesson.nameMonth") as? Bool ?? true,
            time: store.object(forKey: "lesson.nameTime") as? Bool ?? true)
    }
    func name(at date: Date, timeZone: TimeZone = .current) -> String {
        let allowed = prefix.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/:\\\"<>|?*".unicodeScalars.contains($0) }
        let clean = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let title = clean.isEmpty ? "录课" : String(clean.prefix(48))
        let format = (year ? "yyyy" : "") + (month ? "MM" : "") + (time ? "HHmm" : "")
        guard !format.isEmpty else { return title }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone; formatter.dateFormat = format
        return title + "·" + formatter.string(from: date)
    }
}

enum RecordingQuality: String, CaseIterable {
    case compact, high, ultra
    var title: String { switch self { case .compact: return "省空间 · 720p"; case .high: return "高清 · 1080p"; case .ultra: return "超清 · 原始画面（最高4K）" } }
    var edge: Double { switch self { case .compact: return 1280; case .high: return 1920; case .ultra: return 3840 } }
    var bitrate: Int { switch self { case .compact: return 3_000_000; case .high: return 8_000_000; case .ultra: return 20_000_000 } }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "lesson.quality") ?? "") ?? .high }
}

/// Records the received picture and the locally selected audio mix. Writer work
/// never blocks WebRTC or the audio render thread; only two pictures are retained.
final class LocalLessonRecorder: ObservableObject, @unchecked Sendable {
    @Published private(set) var isArmed = false
    @Published private(set) var isRecording = false
    @Published var automatic: Bool = false {
        didSet {
            UserDefaults.standard.set(automatic, forKey: automaticKey)
            if automatic { start() } else { stop() }
        }
    }
    private let automaticKey: String
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
    private var outputQuality = RecordingQuality.high
    private var lessonStem = "录课"
    private var partNumber = 0
    private let segmentByteLimit: Int64
    private var recordingSize: CGSize?
    private let namingOverride: RecordingNameFormat?
    private let cloudEligible: Bool
    private var finishing = 0
    private var folderSubscription: AnyCancellable?
    private var lastVideoTime = -Double.infinity
    private var lastSpaceCheck = -Double.infinity
    private let segmentDuration: TimeInterval
    private static let instances = NSHashTable<LocalLessonRecorder>.weakObjects()

    private final class Segment {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        let pixels: AVAssetWriterInputPixelBufferAdaptor
        let started: Double
        let size: CGSize
        let folder: URL
        let stem: String
        var audioTime = -Double.infinity
        init(folder: URL, size: CGSize, time: Double, stem: String, quality: RecordingQuality) throws {
            self.size = size; started = time
            self.stem = stem; self.folder = folder
            let cache = try RecordingFolderPreferences.cacheDirectory(in: folder)
            let url = cache.appendingPathComponent(UUID().uuidString + ".mp4")
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: quality.bitrate,
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
            writer.shouldOptimizeForNetworkUse = false
            writer.directoryForTemporaryFiles = cache
            guard writer.startWriting() else { throw writer.error ?? RecordingError.message("无法开始写入录课") }
            writer.startSession(atSourceTime: .zero)
        }
        func publish() throws -> URL {
            // moveItem refuses existing destinations; concurrent send/receive writers never overwrite a lesson.
            for suffix in 1...10000 {
                let name = suffix == 1 ? stem : "\(stem) (\(suffix))"
                let destination = folder.appendingPathComponent(name + ".mp4")
                do { try FileManager.default.moveItem(at: writer.outputURL, to: destination); return destination }
                catch {
                    if FileManager.default.fileExists(atPath: destination.path) { continue }
                    throw error
                }
            }
            throw RecordingError.message("录课文件重名过多，缓存已保留")
        }
    }
    private enum RecordingError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }

    init(folder: URL? = nil, segmentDuration: TimeInterval = .infinity, automaticKey: String = "lessonAutomatic.receive", naming: RecordingNameFormat? = nil, segmentByteLimit: Int64 = 3_500_000_000) {
        self.namingOverride = naming; self.cloudEligible = folder == nil
        self.automaticKey = automaticKey
        self.segmentDuration = segmentDuration
        self.segmentByteLimit = max(1, segmentByteLimit)
        Self.instances.add(self)
        if let folder { self.folder = folder; return }
        self.folder = RecordingFolderPreferences.shared.folder
        folderSubscription = RecordingFolderPreferences.shared.$folder.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] url in
            guard let self else { return }
            self.folder = url
            if self.automatic, url != nil { self.start() }
        }
        automatic = UserDefaults.standard.bool(forKey: automaticKey)
        if automatic, self.folder != nil { start() }
    }

    static var storageInUse: Bool { instances.allObjects.contains { $0.isArmed || $0.isSaving } }

    func start() {
        guard folder != nil else { message = "请先在设置中选择录课文件夹"; return }
        guard let folder, !isArmed, !isSaving else { return }
        let naming = namingOverride ?? RecordingNameFormat.current()
        let quality = RecordingQuality.current
        let token = UUID()
        lock.lock(); generation = token; accepting = true; lock.unlock()
        isArmed = true; message = "等待接收画面，连接后自动录课"
        queue.async {
            self.lessonStem = naming.name(at: Date()); self.partNumber = 0; self.recordingSize = nil
            self.outputFolder = folder; self.outputQuality = quality; self.lastSpaceCheck = -.infinity; self.lastVideoTime = -.infinity
        }
    }

    func stop() {
        guard isArmed else { return }
        lock.lock(); accepting = false; lock.unlock()
        isArmed = false; isRecording = false; isSaving = true; message = "正在保存录课…"
        queue.async {
            self.finishSegment()
            if self.finishing == 0 { self.publish("已停止录课"); DispatchQueue.main.async { self.isSaving = false } }
        }
    }

    /// Whole-lesson mode keeps its writer across transport interruptions.
    func endSegment() {
        guard segmentDuration.isFinite else { return }
        queue.async {
            self.finishSegment(); self.lastVideoTime = -.infinity
            if self.ticket() != nil { self.publish("等待接收画面，恢复连接后继续录课") }
        }
    }

    private func ticket() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return accepting ? generation : nil
    }
    var acceptsFrames: Bool { ticket() != nil }
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
                let scale = min(1, self.outputQuality.edge / max(extent.width, extent.height))
                let requestedSize = CGSize(width: max(2, floor(extent.width * scale / 2) * 2), height: max(2, floor(extent.height * scale / 2) * 2))
                if let current = self.segment, self.segmentDuration.isFinite, current.size != requestedSize || time - current.started >= self.segmentDuration { self.finishSegment() }
                if let current = self.segment {
                    let bytes = (try FileManager.default.attributesOfItem(atPath: current.writer.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let reserve = min(16 * 1024 * 1024, self.segmentByteLimit / 10)
                    if bytes >= self.segmentByteLimit - reserve { self.finishSegment() }
                }
                let size = self.segmentDuration.isFinite ? requestedSize : (self.recordingSize ?? requestedSize)
                if time - self.lastSpaceCheck >= 10 {
                    self.lastSpaceCheck = time
                    let free = (try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value
                    if let free, free <= 200 * 1024 * 1024 {
                        self.finishSegment()
                        throw RecordingError.message("剩余空间不足 200 MB，录课已停止")
                    }
                }
                if self.segment == nil {
                    guard self.finishing < 2 else { throw RecordingError.message("磁盘保存过慢，录课已停止") }
                    self.partNumber += 1; self.recordingSize = size
                    let stem = self.lessonStem + "·" + String(format: "%03d", self.partNumber)
                    self.segment = try Segment(folder: folder, size: size, time: time, stem: stem, quality: self.outputQuality)
                    self.publish("正在录课 · " + self.outputQuality.title)
                }
                guard let segment = self.segment else { return }
                guard segment.writer.status == .writing else { throw segment.writer.error ?? RecordingError.message("录课写入失败") }
                guard segment.video.isReadyForMoreMediaData, let pool = segment.pixels.pixelBufferPool else { return }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
                let fit = min(size.width / extent.width, size.height / extent.height)
                let picture = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                    .transformed(by: CGAffineTransform(translationX: (size.width - extent.width * fit) / 2, y: (size.height - extent.height * fit) / 2))
                let normalized = picture.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
                self.context.render(normalized, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
                guard segment.pixels.append(buffer, withPresentationTime: CMTime(seconds: time - segment.started, preferredTimescale: 60000)) else {
                    throw segment.writer.error ?? RecordingError.message("录课视频写入失败")
                }
                let firstFrame = self.lastVideoTime == -.infinity
                self.lastVideoTime = time
                if firstFrame { DispatchQueue.main.async { if self.isArmed { self.isRecording = true } } }
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
        segment = nil; finishing += 1; lastVideoTime = -.infinity
        DispatchQueue.main.async { self.isSaving = true; self.isRecording = false }
        current.video.markAsFinished(); current.audio.markAsFinished()
        current.writer.finishWriting {
            self.queue.async {
                if current.writer.status == .completed {
                    do {
                        let saved = try current.publish()
                        let lesson = self.lessonStem
                        DispatchQueue.main.async {
                            self.lastFile = saved
                            if self.cloudEligible { BaiduDrive.shared.enqueue(saved, lesson: lesson) }
                        }
                        if self.ticket() == nil, self.finishing == 1 { self.publish("录课已保存") }
                    } catch { self.fail(error) }
                } else { self.fail(current.writer.error ?? RecordingError.message("录课文件保存失败")) }
                self.finishing -= 1
                if self.finishing == 0 { DispatchQueue.main.async { self.isSaving = false } }

            }
        }
    }
    private func publish(_ text: String) { DispatchQueue.main.async { self.message = text } }
    private func fail(_ error: Error) {
        lock.lock(); accepting = false; generation = UUID(); lock.unlock()
        if let segment { segment.writer.cancelWriting(); self.segment = nil }
        DispatchQueue.main.async { self.isArmed = false; self.isRecording = false; self.message = error.localizedDescription }
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
}

final class RecordingAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CastingAppearanceIcon.shared.start()
        DispatchQueue.main.async {
            guard let services = NSApp.servicesMenu,
                  let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let item = appMenu.items.first(where: { $0.submenu === services }) else { return }
            appMenu.removeItem(item)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LocalLessonRecorder.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
            ? .terminateLater : .terminateNow
    }
}

struct LocalRecordingControls: View {
    @ObservedObject var recorder: LocalLessonRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AudioActionButton(title: "自动录课", active: recorder.automatic) { recorder.automatic.toggle() }
                Spacer()
                AudioActionButton(title: "", active: recorder.isRecording, symbol: recorder.isRecording ? "record.circle.fill" : "record.circle") {
                    if recorder.isArmed { recorder.stop() } else { recorder.start() }
                }.disabled(!recorder.isArmed && recorder.isSaving)
                    .help(recorder.isArmed ? "停止本次录课" : "直接录课")
                    .accessibilityLabel(recorder.isArmed ? "停止录课" : "直接录课")
            }
            if !recorder.isArmed && recorder.message != "未录课" && recorder.message != "录课已保存" && recorder.message != "已停止录课" {
                Text(recorder.message).font(.caption).foregroundStyle(.secondary)
            }
            if let url = recorder.lastFile, FileManager.default.fileExists(atPath: url.path) {
                Button("显示最近录课") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

/// One sandbox bookmark for all native Mac send/receive recorders.
final class RecordingFolderPreferences: ObservableObject {
    static let shared = RecordingFolderPreferences()
    @Published private(set) var folder: URL?
    @Published private(set) var errorMessage = ""
    private var scope: URL?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: "lessonFolderBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            scope = url; folder = url
            if stale {
                let renewed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(renewed, forKey: "lessonFolderBookmark")
            }
        } catch { errorMessage = "录课目录授权已失效，请重新选择" }
    }

    static func cacheDirectory(in folder: URL) throws -> URL {
        let cache = folder.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let values = try cache.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw NSError(domain: "ToupingRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "录课tmp必须是当前文件夹内的普通目录"])
        }
        return cache
    }

    @MainActor func chooseFolder() {
        guard !LocalLessonRecorder.storageInUse, BaiduDrive.shared.pendingCount == 0 else { errorMessage = "请先停止所有录课，等待保存和网盘待传队列处理完成，再修改目录"; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "保存录课到此处"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !LocalLessonRecorder.storageInUse, BaiduDrive.shared.pendingCount == 0 else { errorMessage = "仍有录课或网盘待传任务，请处理完成后再选择目录"; return }
        let granted = url.startAccessingSecurityScopedResource()
        do {
            _ = try Self.cacheDirectory(in: url)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: "lessonFolderBookmark")
            scope?.stopAccessingSecurityScopedResource(); scope = granted ? url : nil
            folder = url; errorMessage = ""
        } catch {
            if granted { url.stopAccessingSecurityScopedResource() }
            errorMessage = "无法使用此录课目录：\(error.localizedDescription)"
        }
    }
    deinit { scope?.stopAccessingSecurityScopedResource() }
}

struct RecordingFolderSettings: View {
    @ObservedObject private var preferences = RecordingFolderPreferences.shared
    @AppStorage("lesson.quality") private var quality = RecordingQuality.high.rawValue
    @AppStorage("lesson.namePrefix") private var prefix = "录课"
    @AppStorage("lesson.nameYear") private var year = true
    @AppStorage("lesson.nameMonth") private var month = true
    @AppStorage("lesson.nameTime") private var time = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("录课清晰度", selection: $quality) {
                ForEach(RecordingQuality.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Text("下次录课生效；不放大原画面。约3.5GB自动分段，同一课程放入同名网盘文件夹；完成的分段自动上传；上传成功自动删除本地文件，失败保留。百度上传当前支持单文件最多4GB。").font(.caption).foregroundStyle(.secondary)
            TextField("录课名字前缀", text: $prefix)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("年份", isOn: $year).toggleStyle(OrnamentalToggleStyle())
                Toggle("月份", isOn: $month).toggleStyle(OrnamentalToggleStyle())
                Toggle("时间（小时和分）", isOn: $time).toggleStyle(OrnamentalToggleStyle())
            }
            Text("示例：" + RecordingNameFormat(prefix: prefix, year: year, month: month, time: time).name(at: Date()) + ".mp4").font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("选择录课文件夹") { preferences.chooseFolder() }
            Text(preferences.folder?.path ?? "尚未选择录课文件夹").font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("录课中的文件缓存在此目录的tmp子文件夹；保存完成后移到主目录。更换目录前请先停止所有录课并等待保存完成。")
                .font(.caption).foregroundStyle(.secondary)
            if !preferences.errorMessage.isEmpty { Text(preferences.errorMessage).font(.caption).foregroundStyle(.red) }
        }
    }
}


@MainActor
final class CastingAppearanceIcon {
    static let shared = CastingAppearanceIcon()
    private var appearanceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func refresh() {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        let name = style == "Dark" ? "MacIcon-Night-1024" : "MacIcon-1024"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url), image.isValid else { return }
        NSApp.applicationIconImage = image
        NSLog("Casting appearance icon: %@", name)
    }
}
