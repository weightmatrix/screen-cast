import Foundation
import SwiftUI

/// Visible identity follows the installed app version on both native platforms.
enum AppPresentation {
    static var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "李知本·投屏管理·让画面自由连接·V\(version)（\(build)）"
    }
    static let receiveWorkbench = "接收工作台"
}

struct ReceiveTimingView: View {
    let timing: ReceiveTiming
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("网络延迟（RTT） \(ReceiveTiming.text(timing.networkRTTMS))")
            Text("接收处理 \(ReceiveTiming.text(timing.processingMS))")
            Text("非端到端总延迟").font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 15, design: .monospaced))
        .help("RTT是设备间网络往返时间；接收处理是最近采样期间每帧的缓冲与解码平均耗时。均不是端到端总延迟；无有效样本时显示—。")
        .accessibilityHint("网络往返与接收处理耗时，不是端到端总延迟")
    }
}

struct PeerDiagnosticsView: View {
    let peers: [PeerDiagnostic]
    let disconnect: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if peers.isEmpty { Text("暂无已连接设备").foregroundStyle(.secondary) }
            ForEach(peers) { peer in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(peer.device) · \(peer.id.prefix(8)) · \(peer.route)")
                        Text("本机媒体 \(peer.localEndpoint) → 对方 \(peer.remoteEndpoint)")
                            .textSelection(.enabled).foregroundStyle(.secondary)
                        Text("网络 RTT \(ReceiveTiming.text(peer.rttMS))")
                    }.font(.system(size: 14, design: .monospaced))
                    Spacer(minLength: 4)
                    Button("断开", role: .destructive) { disconnect(peer.id) }
                }
            }
            Text("RTT 为网络往返时间，约每 2 秒更新；不是端到端画面延迟。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
