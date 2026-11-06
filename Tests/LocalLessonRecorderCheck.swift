import Foundation
import AVFoundation
import CoreImage

@main enum LocalLessonRecorderCheck {
    @MainActor static func main() async throws {
        let reference = ISO8601DateFormatter().date(from: "2026-11-06T22:30:00Z")!
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        precondition(RecordingNameFormat(prefix: "课程", year: true, month: true, time: true).name(at: reference, timeZone: zone) == "课程·2026110630")
        precondition(RecordingNameFormat(prefix: "课程", year: false, month: true, time: false).name(at: reference, timeZone: zone) == "课程·11")
        precondition(RecordingNameFormat(prefix: "../课程:/", year: false, month: false, time: false).name(at: reference, timeZone: zone) == "课程")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("touping-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cache = try RecordingFolderPreferences.cacheDirectory(in: folder)
        let retained = cache.appendingPathComponent("retained-from-previous-session.txt")
        try Data("preserve".utf8).write(to: retained)
        let recorder = LocalLessonRecorder(folder: folder, segmentDuration: 1, naming: RecordingNameFormat(prefix: "课程", year: true, month: true, time: true))
        recorder.start()
        let start = CACurrentMediaTime()
        for n in 0..<100 {
            let size = n < 70 ? CGSize(width: 640, height: 480) : CGSize(width: 480, height: 640)
            let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
            recorder.appendVideo(image, time: start + Double(n) / 30)
            for block in 0..<3 {
                let offset = Double(n) / 30 + Double(block) / 100
                let samples = (0..<480).map { Float(sin((offset + Double($0) / 48000) * 440 * 2 * .pi) * 0.2) }
                recorder.appendAudio(samples, time: start + offset)
            }
            if n == 10 {
                // Cold hardware encoder initialization can outlive the first synthetic frames.
                for _ in 0..<100 {
                    if recorder.isRecording || !recorder.isArmed { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let staging = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
                precondition(!staging.isEmpty, "An in-progress segment must live in selected-folder/tmp: \(recorder.message), armed=\(recorder.isArmed), recording=\(recorder.isRecording)")
                let finished = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
                precondition(finished.isEmpty, "Incomplete MP4 must not be exposed as a finished lesson")
            }
            if n == 55 { recorder.endSegment() }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        recorder.stop()
        for _ in 0..<200 {
            if !recorder.isSaving { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(!recorder.isSaving && !recorder.isArmed)
        precondition(!recorder.isRecording)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        precondition(files.count >= 4, "Timed rollover, reconnect and rotation must produce separate files: \(recorder.message)")
        var totalVideo = 0, totalAudio = 0
        var sizes = Set<String>()
        for file in files {
            precondition(file.lastPathComponent.range(of: #"^课程·\d{10}( \(\d+\))?\.mp4$"#, options: .regularExpression) != nil)
            let asset = AVURLAsset(url: file)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            precondition(videos.count == 1 && audios.count == 1, "MP4 must contain video and audio")
            let size = try await videos[0].load(.naturalSize)
            sizes.insert("\(Int(size.width))x\(Int(size.height))")
            let duration = try await asset.load(.duration).seconds
            precondition(duration > 0 && duration < 1.2)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); precondition(reader.startReading())
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                count += 1
                if count == 1, let pixel = CMSampleBufferGetImageBuffer(sample) {
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let pointer = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                    precondition(pointer[2] > 180 && pointer[0] < 60, "Recorded picture must be red")
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                }
            }
            precondition(reader.status == .completed && count > 0)
            totalVideo += count
            let audioReader = try AVAssetReader(asset: asset)
            let audio = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            audioReader.add(audio); precondition(audioReader.startReading())
            while let sample = audio.copyNextSampleBuffer() { totalAudio += CMSampleBufferGetNumSamples(sample) }
            precondition(audioReader.status == .completed)
        }
        precondition(sizes.count == 2 && totalVideo > 30 && totalAudio > 48000)
        // No received picture must create no empty/corrupt MP4.
        let count = files.count
        recorder.start(); recorder.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterEmpty = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }.count
        precondition(afterEmpty == count)
        let retainedData = try Data(contentsOf: retained)
        let cacheFiles = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        precondition(retainedData == Data("preserve".utf8))
        precondition(cacheFiles == [retained.lastPathComponent])
        precondition(recorder.lastFile?.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
        let invalid = folder.appendingPathComponent("invalid-cache")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: invalid.appendingPathComponent("tmp"), withDestinationURL: cache)
        do { _ = try RecordingFolderPreferences.cacheDirectory(in: invalid); preconditionFailure("Symlink cache must be rejected") } catch {}

        print("PASS playable H264/AAC MP4, red pixels, \(totalVideo) frames, \(totalAudio) audio samples, timed/reconnect/rotation segments, stop/drain and empty session; files=\(folder.path)")
    }
}
