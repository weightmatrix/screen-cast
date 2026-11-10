import Foundation
import CoreMedia
#if os(macOS)
import SystemConfiguration
#endif

/// Capture-side compensation for the inverse quarter-turns reported on iPad.
/// Keep this separate from presentation and the generic pixel rotation API.
enum ReplaySampleOrientation {
    static func correction(_ captured: Int) -> Int {
        switch captured {
        case 6: return 8
        case 8: return 6
        default: return captured
        }
    }
}

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
            PerformanceDisk.shared.write("gap stage=\(name) event=\(event) ms=\(String(format: "%.2f", gap))")
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

/// Local receiver telemetry; neither value is glass-to-glass latency.
struct ReceiveTiming {
    var networkRTTMS: Double? = nil
    var processingMS: Double? = nil
    static func text(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.0f ms", value)
    }
}
struct ReceiveTimingSampler {
    private var previous: (jitter: Double, emitted: Double, decode: Double, decoded: Double)?
    mutating func sample(rtt: Double?, jitter: Double?, emitted: Double?, decode: Double?, decoded: Double?) -> ReceiveTiming {
        var result = ReceiveTiming(networkRTTMS: rtt.flatMap { $0.isFinite && $0 > 0 ? $0 * 1000 : nil })
        guard let jitter, let emitted, let decode, let decoded,
              [jitter, emitted, decode, decoded].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            previous = nil; return result
        }
        defer { previous = (jitter, emitted, decode, decoded) }
        guard let old = previous, jitter >= old.jitter, decode >= old.decode,
              emitted > old.emitted, decoded > old.decoded else { return result }
        let ms = ((jitter - old.jitter) / (emitted - old.emitted) +
                  (decode - old.decode) / (decoded - old.decoded)) * 1000
        if ms.isFinite && ms >= 0 { result.processingMS = ms }
        return result
    }
}

/// Hardware per-frame feedback without banking unused static-frame bitrate.
struct ScreenFrameQuantizer {
    // Start conservatively until real frame sizes establish the screen complexity.
    // Subsequent feedback recovers quality in bounded steps.
    private(set) var qp = 42
    private var startupRemaining = 90
    private var quietFrames = 0
    mutating func observe(bytes: Int, budget: Int, usedQP: Int, key: Bool) {
        guard !key, budget > 0 else { return }
        let ratio = Double(bytes) / Double(budget)
        // Keep static refinement available after later congestion too.
        // Expiring it after startup can leave a stationary screen stuck at QP51.
        let settling = startupRemaining <= 60
        startupRemaining = max(0, startupRemaining - 1)
        if usedQP == qp { quietFrames = ratio < 0.15 ? min(3, quietFrames + 1) : 0 }
        if settling && ratio < 0.15 && qp > 28 && usedQP == qp {
            // Three genuinely small outputs establish headroom. Recover a coarse
            // reference faster, without lowering the static QP floor or forcing
            // another large keyframe. Stale callbacks cannot spend this headroom.
            qp = max(28, qp - (quietFrames >= 3 ? 3 : 1))
        } else if ratio > 1.1 {
            quietFrames = 0
            let step = min(6, max(1, Int(ceil(6 * log2(ratio)))))
            qp = min(51, max(qp, usedQP + step))
        } else if ratio >= 0.15 && ratio < 0.8 && usedQP == qp {
            qp = max(10, qp - 1)
        }
    }
}

/// Smooth encoder demand only. Never lower the connection's BWE/probing ceiling.
struct NativeVideoBudget {
    private(set) var limit = 8_000_000
    mutating func clamp(upper: Int) { limit = min(limit, max(1, upper)) }
    mutating func sample(upper: Int, available: Double, sendWait: Double, loss: Double, utilization: Double = 1) -> Int {
        clamp(upper: upper)
        guard available.isFinite, available >= 0, sendWait.isFinite, loss.isFinite, utilization.isFinite else { return limit }
        // Zero alone can mean missing feedback. With measured backlog it must
        // not bypass congestion handling and leave a high encoder cap in place.
        if available == 0 {
            if sendWait > 0.08 { limit = max(min(200_000, upper), limit / 2) }
            return limit
        }
        let safe = min(Double(upper), available * 0.85)
        if loss > 0.02 || available < Double(limit) * 0.8 {
            limit = max(min(200_000, upper), Int(min(Double(limit) * 0.8, safe)))
        } else if utilization >= 0.35 && loss < 0.005 && safe > Double(limit) * 1.1 {
            // Idle content must not bank an unused encoder budget. Utilization gates
            // growth only; independent BWE remains the capacity estimate. Follow
            // independent capacity, with a bounded step rather than waiting for zero queue.
            let step = max(Double(limit) * 1.5, Double(limit) + 2_000_000)
            limit = min(upper, Int(min(safe, step)))
        }
        return limit
    }
}

/// Normalize declared LPCM bytes before handing them to AVAudioPCMBuffer.
/// In particular, packed24-bit, big-endian and fixed-point are not native Int32.
enum ScreenAudioPCM {
    static func mono(_ format: AudioStreamBasicDescription, buffers: UnsafePointer<AudioBufferList>, frames: Int) -> [Float]? {
        let channels = Int(format.mChannelsPerFrame), bits = Int(format.mBitsPerChannel)
        let flags = format.mFormatFlags
        let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate.isFinite,
              format.mSampleRate > 0, (1...8).contains(channels), (1...64).contains(bits),
              (1...192000).contains(frames), format.mBytesPerFrame > 0 else { return nil }
        let stride = Int(format.mBytesPerFrame)
        guard planar || stride % channels == 0 else { return nil }
        let bytes = stride / (planar ? 1 : channels)
        let floating = flags & kAudioFormatFlagIsFloat != 0
        guard (1...8).contains(bytes), bits <= bytes * 8,
              !floating || ((bits == 32 || bits == 64) && bits == bytes * 8) else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard list.count >= (planar ? channels : 1) else { return nil }
        for channel in 0..<(planar ? channels : 1) {
            guard list[channel].mData != nil,
                  Int(list[channel].mDataByteSize) >= (frames - 1) * stride + (planar ? bytes : channels * bytes) else { return nil }
        }
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let high = flags & kAudioFormatFlagIsAlignedHigh != 0
        let signed = flags & kAudioFormatFlagIsSignedInteger != 0
        let fractional = Int((flags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift)
        let scale = pow(2.0, Double(fractional > 0 ? fractional : bits - 1))
        var result = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum = 0.0
            for channel in 0..<channels {
                let data = list[planar ? channel : 0].mData!.assumingMemoryBound(to: UInt8.self)
                let offset = frame * stride + (planar ? 0 : channel * bytes)
                var raw: UInt64 = 0
                for byte in 0..<bytes { raw |= UInt64(data[offset + byte]) << ((bigEndian ? bytes - 1 - byte : byte) * 8) }
                let value: Double
                if floating { value = bits == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw) }
                else {
                    if high { raw >>= bytes * 8 - bits }
                    if bits < 64 { raw &= (UInt64(1) << bits) - 1 }
                    if signed { value = Double(Int64(bitPattern: raw << (64 - bits)) >> (64 - bits)) / scale }
                    else { value = (Double(raw) - scale) / scale }
                }
                sum += value.isFinite ? value : 0
            }
            result[frame] = Float(max(-1, min(1, sum / Double(channels))))
        }
        return result
    }
}

/// Smooth only actual starvation/restart boundaries, never normal audio blocks.
struct ScreenAudioEdge {
    private var last: Int16 = 0
    private var restarting = true
    mutating func apply(_ samples: [Int16], frames: Int) -> [Int16] {
        guard frames > 0 else { return [] }
        let count = min(frames, samples.count)
        var result = [Int16](repeating: 0, count: frames)
        if count == 0 {
            let ramp = min(frames, 240)
            for n in 0..<ramp { result[n] = Int16(Int(last) * (ramp - n - 1) / ramp) }
            last = 0; restarting = true
            return result
        }
        for n in 0..<count { result[n] = samples[n] }
        if restarting {
            let ramp = min(count, 240)
            for n in 0..<ramp { result[n] = Int16(Int(result[n]) * n / ramp) }
            restarting = false
        }
        last = result[count - 1]
        return result
    }
}

/// Bounded local diagnostics. Ports here are selected ICE media endpoints, not signaling listeners.
struct PeerDiagnostic: Codable, Identifiable {
    let id: String
    var device: String
    var route: String
    var localEndpoint: String
    var remoteEndpoint: String
    var rttMS: Double?
    var networkInterface: String? = nil
    var signals: String? = nil
    var source: String? = nil
    var nickname: String? = nil
    var connectionLabel: String { MediaPath.connectionLabel(route: route, interface: networkInterface ?? "") }
}

enum HostIdentity {
    static var description: String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return model + " · " + ProcessInfo.processInfo.operatingSystemVersionString
    }
}

/// Describes only the selected ICE pair; the invitation mode is deliberately ignored.
enum MediaPath {
    static let preference = "优先顺序：USB可用网络 → 局域网 → 公网；以实际可达路径和链路质量为准"
    struct Interface {
        var name: String
        var detail: String
        var deviceUSB = false
        var tunnel = false
        var sameSubnet = false
    }
    static func bytes(_ address: String) -> [UInt8]? {
        let text = address.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").split(separator: "%").first.map(String.init) ?? ""
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return Array(bytes.suffix(4)) }
            return bytes
        }
        return nil
    }
    static func nonPublic(_ address: String) -> Bool? {
        guard let ip = bytes(address) else { return nil }
        if ip.count == 4 {
            return ip[0] == 10 || ip[0] == 127 || ip[0] == 0 || (ip[0] == 172 && (16...31).contains(ip[1])) || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 169 && ip[1] == 254) || (ip[0] == 100 && (64...127).contains(ip[1])) || ip[0] >= 224
        }
        return ip.allSatisfy { $0 == 0 } || (ip.dropLast().allSatisfy { $0 == 0 } && ip.last == 1) || ip[0] & 0xfe == 0xfc || (ip[0] == 0xfe && ip[1] & 0xc0 == 0x80) || ip[0] == 0xff
    }
    static func address(_ candidate: [String: Any]) -> String {
        candidate["address"] as? String ?? candidate["ip"] as? String ?? ""
    }
    static func route(local: [String: Any], remote: [String: Any], interface: Interface?) -> String {
        let lt = local["candidateType"] as? String, rt = remote["candidateType"] as? String
        if lt == "relay" || rt == "relay" { return "中继路径" }
        if let ip = bytes(address(remote)), (ip.count == 4 && ip[0] == 127) || (ip.count == 16 && ip.dropLast().allSatisfy({ $0 == 0 }) && ip.last == 1) { return "本机回环直连" }
        if interface?.tunnel == true || local["networkType"] as? String == "vpn" { return "VPN/隧道直连（底层网络未知）" }
        if lt == "host", rt == "host", interface?.sameSubnet == true {
            return interface?.deviceUSB == true ? "USB设备网络直连" : "局域网直连（同子网）"
        }
        if nonPublic(address(local)) == true && nonPublic(address(remote)) == true { return "内网直连（局域网/VPN待确认）" }
        if nonPublic(address(remote)) == false { return "公网地址直连（可能同网回环）" }
        if lt == "srflx" || rt == "srflx" || lt == "prflx" || rt == "prflx" { return "公网候选直连（范围待确认）" }
        return "直连（地址隐藏或接口未确认）"
    }
    static func interface(local: [String: Any], remote: [String: Any]) -> Interface? {
        guard let localIP = bytes(address(local)) else { return nil }
        let remoteIP = bytes(address(remote))
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var item = list
        while let current = item {
            defer { item = current.pointee.ifa_next }
            let value = current.pointee
            guard let addr = value.ifa_addr, addr.pointee.sa_family == AF_INET || addr.pointee.sa_family == AF_INET6 else { continue }
            func numeric(_ pointer: UnsafePointer<sockaddr>) -> String? {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            guard let text = numeric(UnsafePointer(addr)), bytes(text) == localIP else { continue }
            let name = String(cString: value.ifa_name)
            var result = Interface(name: name, detail: name, tunnel: name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tun"))
            if let mask = value.ifa_netmask, let maskText = numeric(UnsafePointer(mask)), let maskIP = bytes(maskText), let remoteIP, maskIP.count == localIP.count, remoteIP.count == localIP.count, maskIP.contains(where: { $0 != 0 }) {
                result.sameSubnet = zip(zip(localIP, remoteIP), maskIP).allSatisfy { ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }
            }
            #if os(macOS)
            if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
               let found = interfaces.first(where: { (SCNetworkInterfaceGetBSDName($0) as String?) == name }) {
                let label = (SCNetworkInterfaceGetLocalizedDisplayName(found) as String?) ?? name
                let type = (SCNetworkInterfaceGetInterfaceType(found) as String?) ?? ""
                result.detail = "\(label)（\(name)）"
                // USB Ethernet dongles do not prove a direct USB connection to the receiver.
                result.deviceUSB = label.localizedCaseInsensitiveContains("USB") && (label.localizedCaseInsensitiveContains("iPhone") || label.localizedCaseInsensitiveContains("iPad"))
                if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { result.detail = "Wi-Fi · " + result.detail }
            }
            #endif
            return result
        }
        return nil
    }
    static func interfaceText(_ interface: Interface?, candidate: [String: Any]) -> String {
        if let interface { return interface.detail }
        switch candidate["networkType"] as? String {
        case "wifi": return "Wi-Fi（统计报告）"
        case "ethernet": return "有线网络（USB未确认）"
        case "cellular": return "蜂窝网络（统计报告）"
        case "vpn": return "VPN/隧道"
        default: return "接口未公开（不能确认USB/Wi-Fi）"
        }
    }
}

/// Client-declared entry point, distinct from the selected ICE media path.
enum ConnectionOrigin: String, CaseIterable {
    case publicWeb, localWeb, appPublicIP, appPublicCode, appLocalIP, appLocalCode
    var title: String {
        switch self {
        case .publicWeb: return "公网网页"
        case .localWeb: return "局域网网页"
        case .appPublicIP: return "app公网直连"
        case .appPublicCode: return "app公网邀请码"
        case .appLocalIP: return "app局域网直连"
        case .appLocalCode: return "app局域网邀请码"
        }
    }
}
extension MediaPath {
    static func connectionLabel(route: String, interface: String) -> String {
        if route.contains("USB设备") { return "USB电缆" }
        if route.contains("回环") && !route.contains("公网") { return "本机回环" }
        if route.contains("VPN") && !route.contains("待确认") { return "VPN/隧道" }
        if route.contains("中继") { return "中继路径" }
        if route.contains("局域网直连（同子网）") {
            if interface.localizedCaseInsensitiveContains("wi-fi") || interface.localizedCaseInsensitiveContains("wifi") { return "Wi-Fi局域网" }
            if interface.localizedCaseInsensitiveContains("ethernet") || interface.contains("以太") || interface.contains("有线") { return "有线局域网" }
            return "局域网（介质未确认）"
        }
        if route.contains("公网") { return "公网直连" }
        if route.contains("内网") { return "内网（介质未确认）" }
        return "连接方式待确认"
    }
}
