import Foundation
import AVFoundation
import CoreGraphics
import AppKit

final class DiagLog {
    static let shared = DiagLog()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "diaglog", qos: .utility)
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleName = Bundle.main.bundleIdentifier ?? "MacCaster"
        let dir = base.appendingPathComponent(bundleName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("diagnostic.log")
        write("# MacCaster 诊断日志\n\n")
    }

    static func log(_ tag: String, _ msg: String) {
        shared.write("[\(tag)] \(msg)")
        NSLog("[\(tag)] \(msg)")
    }

    private func write(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = self.fmt.string(from: Date())
            let entry = "\(ts) \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: self.fileURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: self.fileURL)
            }
        }
    }

    var logPath: String { fileURL.path }
}

enum PermissionDiagnostics {
    static func logCurrent() {
        let screen = CGPreflightScreenCaptureAccess()
        let audioRaw = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        DiagLog.log("Permission", "screenCapture=\(screen) audioRaw=\(audioRaw)")
    }

    static func requestScreenCapture() {
        let granted = CGRequestScreenCaptureAccess()
        DiagLog.log("Permission", "requestScreenCapture result=\(granted)")
        logCurrent()
    }

    static func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
