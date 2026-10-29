import Foundation
import CoreMedia

// Shared by native macOS and iOS targets; contains no UI-framework dependencies.
enum StreamFormat {
    static func deserialize(_ data: Data) -> CMVideoFormatDescription? {
        var desc: CMFormatDescription?
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: nil,
                bigEndianImageDescriptionData: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: data.count,
                stringEncoding: 0,
                flavor: .isoFamily,
                formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { return nil }
        return desc
    }

    static func annexB(_ sb: CMSampleBuffer) -> (Data, Bool)? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let len = CMBlockBufferGetDataLength(bb)
        var raw = [UInt8](repeating: 0, count: len)
        raw.withUnsafeMutableBytes { p in if let b = p.baseAddress { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: b) } }
        var out = Data(capacity: len + 64)
        var isKey = false; var off = 0
        while off + 4 <= len {
            var sz = 0
            for i in 0..<4 { sz = sz << 8 | Int(raw[off + i]) }
            off += 4
            guard off + sz <= len, sz > 0 else { break }
            if raw[off] & 0x1F == 5 { isKey = true }
            out.append(contentsOf: [0,0,0,1])
            out.append(contentsOf: raw[off..<off+sz])
            off += sz
        }
        return out.isEmpty ? nil : (out, isKey)
    }

    static func serialize(_ fmt: CMFormatDescription) -> Data? {
        var bb: CMBlockBuffer?
        guard CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(allocator: nil, videoFormatDescription: fmt, stringEncoding: 0, flavor: .isoFamily, blockBufferOut: &bb) == noErr, let bb else { return nil }
        let len = CMBlockBufferGetDataLength(bb)
        var d = Data(count: len)
        d.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
        return d
    }
}

extension Data {
    mutating func append(uint32: Int) {
        var value = UInt32(uint32).bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    func copySlice(_ offset: Int, _ length: Int) -> Data {
        guard offset >= 0, length > 0, offset + length <= count else { return Data() }
        return withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return Data() }
            return Data(bytes: base.advanced(by: offset), count: length)
        }
    }
}

/// Aggregated timings use one device's monotonic clock, never cross-device clock subtraction.
final class StreamPerformance {
    private let name: String
    private let lock = NSLock()
    private var start = ProcessInfo.processInfo.systemUptime
    private var counts: [String: Int] = [:]
    private var totals: [String: Double] = [:]
    private var maxima: [String: Double] = [:]
    private var previousEvents: [String: Double] = [:]
    private var lastGapReports: [String: Double] = [:]
    init(_ name: String) { self.name = name }
    /// Intervals stay within a single clock domain; gaps may also represent idle screen capture.
    func interval(_ event: String, at timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let previous = previousEvents.updateValue(timestamp, forKey: event)
        let gap = previous.map { (timestamp - $0) * 1000 }
        let report = gap.map { $0 > 40 && now - (lastGapReports[event] ?? 0) >= 1 } ?? false
        if report { lastGapReports[event] = now }
        lock.unlock()
        guard let gap, gap >= 0 else { return }
        record(event, milliseconds: gap)
        if report {
            PerformanceDisk.shared.write("gap stage=\(name) event=\(event) ms=\(String(format: "%.2f", gap)) uptime=\(String(format: "%.6f", now))")
        }
    }

    func record(_ event: String, milliseconds: Double = 0, bytes: Int = 0, count: Int = 1) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        counts[event, default: 0] += count
        totals[event, default: 0] += milliseconds
        maxima[event] = max(maxima[event] ?? 0, milliseconds)
        counts["bytes", default: 0] += bytes
        guard now - start >= 2 else { lock.unlock(); return }
        let duration = now - start
        let fields = counts.keys.sorted().filter { $0 != "bytes" }.map { key in
            "\(key)=\(counts[key]!) avgMs=\(String(format: "%.2f", (totals[key] ?? 0) / Double(counts[key]!))) maxMs=\(String(format: "%.2f", maxima[key] ?? 0))"
        }.joined(separator: " ")
        let line = "\(name) windowSec=\(String(format: "%.2f", duration)) Mbps=\(String(format: "%.2f", Double(counts["bytes"] ?? 0) * 8 / duration / 1_000_000)) \(fields)"
        counts.removeAll(keepingCapacity: true); totals.removeAll(keepingCapacity: true); maxima.removeAll(keepingCapacity: true); start = now
        lock.unlock()
        PerformanceDisk.shared.write(line)
    }
}

final class PerformanceDisk {
    static let shared = PerformanceDisk()
    /// Set before starting a broadcast; delivers diagnostics to the receiver for collection.
    private let relayLock = NSLock()
    private var forwarding: ((String) -> Void)?
    var relay: ((String) -> Void)? {
        get { relayLock.lock(); defer { relayLock.unlock() }; return forwarding }
        set { relayLock.lock(); forwarding = newValue; relayLock.unlock() }
    }
    private let queue = DispatchQueue(label: "casting.performance.disk", qos: .utility)
    private let url: URL = {
        let fm = FileManager.default
        #if os(macOS)
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Touping", isDirectory: true)
        #else
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("performance.log")
    }()
    func write(_ message: String, forward: Bool = true) {
        let entry = "\(Date().timeIntervalSince1970) \(message)"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: self.url.path)[.size]) as? NSNumber, size.intValue > 4 * 1024 * 1024 {
                let previous = self.url.appendingPathExtension("previous")
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: self.url, to: previous)
            }
            let data = Data((entry + "\n").utf8)
            if let file = try? FileHandle(forWritingTo: self.url) {
                file.seekToEndOfFile(); file.write(data); try? file.close()
            } else { try? data.write(to: self.url) }
            if forward { self.relay?(entry) }
        }
    }
}

/// Shared by discovery, authentication and both platforms' standard text fields.
enum MatchingCode {
    static func isValid(_ value: String?) -> Bool {
        guard let value, (6...36).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func generate() -> String {
        (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
    }
}

/// Byte credits are returned only after the receiver has delivered data locally.
/// This bounds bursts without losing or reordering the framed video byte stream.
struct PeerByteWindow {
    static let capacity = 256 * 1024
    private(set) var limit = 0
    private(set) var available = 0
    private(set) var outstanding = 0
    mutating func announce(_ count: Int) -> Bool {
        guard limit == 0, (8192...1_048_576).contains(count) else { return false }
        limit = count; available = count
        return true
    }
    mutating func sent(_ count: Int) -> Bool {
        guard count > 0, count <= available else { return false }
        available -= count; outstanding += count
        return true
    }
    mutating func acknowledge(_ count: Int) -> Bool {
        guard count > 0, count <= outstanding, count <= limit - available else { return false }
        outstanding -= count; available += count
        return true
    }
}

/// AIMD for the P2P sender. Idle screens never trigger an upward probe.
struct InternetRateController {
    private(set) var target = 8_000_000
    private var stableWindows = 0
    mutating func sample(bytes: Int, seconds: Double, stalledSeconds: Double, congested: Bool) -> Int {
        guard seconds > 0 else { return target }
        let delivered = Double(bytes) * 8 / seconds
        if congested || stalledSeconds / seconds > 0.2 {
            target = max(2_000_000, min(target * 3 / 4, Int(delivered * 0.8)))
            stableWindows = 0
        } else if delivered > Double(target) * 0.65 {
            stableWindows += 1
            if stableWindows >= 3 {
                target = min(100_000_000, target + max(500_000, target / 20))
                stableWindows = 0
            }
        } else { stableWindows = 0 }
        return target
    }
}

/// Observe actual encoder drops, not the source's idle-screen frame cadence.
struct EncoderFramePacer {
    private(set) var target = 60
    private var start: Double?
    private var count = 0, dropped = 0, bad = 0, good = 0
    mutating func reset(upper: Int) {
        target = upper; start = nil; count = 0; dropped = 0; bad = 0; good = 0
    }
    mutating func observe(drop: Bool, now: Double, upper: Int, enabled: Bool) -> Int {
        guard enabled else { reset(upper: upper); return target }
        target = min(target, upper)
        if start == nil { start = now }
        count += 1
        if drop { dropped += 1 }
        let elapsed = now - start!
        guard elapsed >= 2 else { return target }
        defer { start = now; count = 0; dropped = 0 }
        guard count >= 12 else { bad = 0; good = 0; return target }
        let ratio = Double(dropped) / Double(count)
        if ratio > 0.15 {
            bad += 1; good = 0
            if bad >= 2 {
                target = [30, 20, 15].first { $0 < target } ?? min(15, upper)
                bad = 0
            }
        } else if ratio < 0.03 && Double(count - dropped) / elapsed >= Double(target) * 0.8 {
            good += 1; bad = 0
            if good >= 3 {
                target = min(upper, [20, 30, 60].first { $0 > target } ?? upper)
                good = 0
            }
        } else { good = 0; bad = 0 }
        return target
    }
}

/// Smooth encoder demand only. Never lower the connection's BWE/probing ceiling.
struct NativeVideoBudget {
    private(set) var limit = 8_000_000
    mutating func clamp(upper: Int) { limit = min(limit, max(1, upper)) }
    mutating func sample(upper: Int, available: Double, sendWait: Double, loss: Double) -> Int {
        clamp(upper: upper)
        guard available.isFinite, available > 0, sendWait.isFinite, loss.isFinite else { return limit }
        let safe = min(Double(upper), available * 0.85)
        if loss > 0.02 || (sendWait > 0.08 && available < Double(limit) * 0.8) {
            limit = max(min(2_000_000, upper), Int(min(Double(limit) * 0.8, safe)))
        } else if loss < 0.005 && sendWait < 0.05 && safe > Double(limit) * 1.1 {
            limit = min(upper, Int(min(safe, Double(limit) * 1.25)))
        }
        return limit
    }
}
