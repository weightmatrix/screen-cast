import Foundation
import SwiftUI

/// Visible identity follows the installed app version on both native platforms.
enum AppPresentation {
    static var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "李知本·投屏管理·\(version)（\(build)）"
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
