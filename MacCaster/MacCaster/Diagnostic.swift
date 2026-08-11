import Foundation

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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacCasterLogs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("diagnostic.log")
        write("=== MacCaster Diagnostic Log ===\n")
    }

    static func log(_ tag: String, _ msg: String) {
        shared.write("[\(tag)] \(msg)")
        NSLog("[\(tag)] \(msg)")
    }

    private func write(_ line: String) {
        let ts = fmt.string(from: Date())
        let entry = "\(ts) \(line)\n"
        queue.async { [weak self] in
            guard let self, let data = entry.data(using: .utf8) else { return }
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
