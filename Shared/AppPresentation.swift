import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplified = "zh-Hans", traditional = "zh-Hant"
    case english = "en", spanish = "es", german = "de", french = "fr"
    case italian = "it", japanese = "ja", korean = "ko"
    static let storageKey = "appearance.language"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .system: return "跟随系统"
        case .simplified: return "简体中文"
        case .traditional: return "繁體中文"
        case .english: return "English"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
    static func locale(_ value: String) -> Locale {
        guard let choice = Self(rawValue: value), choice != .system else { return .autoupdatingCurrent }
        return Locale(identifier: choice.rawValue)
    }
}

struct AppLanguagePicker: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    var body: some View {
        Picker("语言", selection: $language) {
            ForEach(AppLanguage.allCases) { choice in
                if choice == .system { Text("跟随系统").tag(choice.rawValue) }
                else { Text(verbatim: choice.nativeName).tag(choice.rawValue) }
            }
        }
    }
}

/// Visible identity follows the installed app version on both native platforms.
enum AppPresentation {
    static let privacyURL = URL(string: "https://zhibenwang.com/touping/privacy.html")!
    static let supportURL = URL(string: "https://zhibenwang.com/touping/support.html")!
    static var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "李知本·投屏自由·V\(version)（\(build)）"
    }
    static let receiveWorkbench = "接收工作台"
}

struct ConnectionLegalNotice: View {
    var body: some View {
        Text("请勿利用本工具传播违法信息或侵犯他人合法权益。公网接入须经投送者确认，必要连接日志依法留存。违法使用者依法承担相应责任。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct PendingConnectionsView: View {
    let requests: [PendingConnection]
    let respond: (String, Bool) -> Void
    var body: some View {
        ForEach(requests) { request in
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("接入申请").font(.headline)
                    Text("来源 IP：\(request.ip)").font(.caption.monospaced()).textSelection(.enabled)
                    Text(verbatim: request.application).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text("\(request.route) · \(request.id.prefix(8))").font(.caption)
                }
                Spacer()
                Button("拒绝", role: .destructive) { respond(request.id, false) }
                Button("接受") { respond(request.id, true) }
            }
        }
    }
}

struct ConnectionPrivacyNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("公网服务依法留存必要连接日志，包括来源IP、随机应用标识、审批与连接状态；客户端报告的连接时长不代表服务器核验。画面与声音不上传。详情及权利申请方式见隐私政策。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("隐私政策", destination: AppPresentation.privacyURL)
                Link("技术支持", destination: AppPresentation.supportURL)
            }.font(.caption)
        }
    }
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
            ConnectionLegalNotice()
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

// Native vector ornamentation shared by macOS and iOS; never decorates media pixels.
enum AppSkin {
    static let key = "appearance.skin"
    static func victorian(_ value: String) -> Bool { value != "minimal" }
    static let paper = Color(red: 0.98, green: 0.96, blue: 0.91)
    static let ivory = Color(red: 0.94, green: 0.90, blue: 0.81)
    static let brass = Color(red: 0.62, green: 0.47, blue: 0.25)
    static let ink = Color(red: 0.17, green: 0.31, blue: 0.27)
}

struct AppPaperBackground: View {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    var body: some View {
        if AppSkin.victorian(skin) {
            LinearGradient(colors: [AppSkin.paper, AppSkin.ivory.opacity(0.9), AppSkin.paper], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else { Color.primary.opacity(0.035) }
    }
}

struct VictorianFrame: View {
    var body: some View {
        Canvas { context, size in
            guard size.width > 40, size.height > 40 else { return }
            for inset in [3.0, 7.0, 11.0] {
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                context.stroke(Path(rect), with: .color(AppSkin.brass.opacity(inset == 7 ? 0.7 : 0.35)), lineWidth: inset == 7 ? 0.8 : 0.5)
            }
            for (x, y, sx, sy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0, -1, 1), (0, size.height, 1, -1), (size.width, size.height, -1, -1)] {
                var corner = context
                corner.translateBy(x: x, y: y); corner.scaleBy(x: sx, y: sy)
                corner.translateBy(x: 14, y: 14)
                var scroll = Path()
                scroll.move(to: CGPoint(x: 0, y: 40)); scroll.addLine(to: .zero); scroll.addLine(to: CGPoint(x: 40, y: 0))
                scroll.move(to: CGPoint(x: 2, y: 30))
                scroll.addCurve(to: CGPoint(x: 20, y: 9), control1: CGPoint(x: 3, y: 6), control2: CGPoint(x: 31, y: 23))
                scroll.addCurve(to: CGPoint(x: 8, y: 19), control1: CGPoint(x: 10, y: -2), control2: CGPoint(x: -1, y: 15))
                scroll.addCurve(to: CGPoint(x: 30, y: 2), control1: CGPoint(x: 29, y: 25), control2: CGPoint(x: 7, y: 3))
                scroll.move(to: CGPoint(x: 6, y: 35))
                scroll.addCurve(to: CGPoint(x: 35, y: 6), control1: CGPoint(x: 31, y: 40), control2: CGPoint(x: 15, y: 13))
                corner.stroke(scroll, with: .color(AppSkin.brass.opacity(0.8)), lineWidth: 0.8)
                for point in [CGPoint(x: 8, y: 8), CGPoint(x: 23, y: 22)] {
                    corner.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 3, height: 3)), with: .color(AppSkin.brass.opacity(0.65)))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct AppPanelStyle: ViewModifier {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    func body(content: Content) -> some View {
        if AppSkin.victorian(skin) {
            content.padding(.vertical, 24).background(AppPaperBackground()).overlay { VictorianFrame() }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

extension View {
    func appPanelStyle() -> some View { modifier(AppPanelStyle()) }
}

struct VictorianHeading: View {
    let title: String
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Rectangle().frame(height: 0.5)
                Text("❧  ❦  ❧").font(.system(size: 25, design: .serif))
                Rectangle().frame(height: 0.5)
            }.foregroundStyle(AppSkin.brass)
            Text(LocalizedStringKey(title)).font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(AppSkin.ink)
        }.padding(.vertical, 8)
    }
}

struct AppSkinPicker: View {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    var body: some View {
        Picker("当前皮肤", selection: $skin) {
            Text("极简皮肤").tag("minimal")
            Text("维多利亚花饰").tag("victorian")
        }
        .onAppear { if skin == "icons3d" { skin = "victorian" } }
    }
}

private struct AppSettingsPaper: ViewModifier {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            content.scrollContentBackground(AppSkin.victorian(skin) ? .hidden : .visible).background(AppPaperBackground())
        } else { content.background(AppPaperBackground()) }
    }
}
extension View {
    func appSettingsPaper() -> some View { modifier(AppSettingsPaper()) }
}
