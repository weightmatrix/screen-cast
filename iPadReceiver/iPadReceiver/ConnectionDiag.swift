import Foundation
import Combine

final class ConnectionDiag: ObservableObject {
    static let shared = ConnectionDiag()

    @Published private(set) var text = "暂无连接日志"
    var relay: ((String) -> Void)?

    private let lock = NSLock()
    private let fileQueue = DispatchQueue(label: "com.witten.touping.connectiondiag", qos: .utility)
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let fileURL: URL
    private var lines: [String] = []
    private let maxLines = 200

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("ConnectionDiag.md")
        log("=== iPad Connection Diagnostic ===")
    }

    func log(_ message: String) {
        NSLog("[ConnectionDiag] %@", message)
        let entry = "\(fmt.string(from: Date())) \(message)"
        lock.lock()
        lines.append(entry)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        let snapshot = lines.joined(separator: "\n")
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.text = snapshot
        }

        fileQueue.async { [weak self] in
            guard let self, let data = (entry + "\n").data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: self.fileURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: self.fileURL)
            }
        }
        relay?(entry)
    }

    func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        text = "暂无连接日志"
        lock.unlock()
    }
}
