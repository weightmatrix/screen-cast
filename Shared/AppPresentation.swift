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
                    Text(verbatim: request.nickname ?? "访客").font(.headline)
                    Text("接入申请 · 昵称由对方填写").font(.caption).foregroundStyle(.secondary)
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
    @ObservedObject private var room = RoomSession.shared
    let peers: [PeerDiagnostic]
    let disconnect: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConnectionLegalNotice()
            if peers.isEmpty { Text("暂无已连接设备").foregroundStyle(.secondary) }
            ForEach(peers) { peer in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room.peerNicknames[peer.id] ?? peer.nickname ?? "访客·" + peer.id.prefix(4).uppercased())
                        ConnectionEntryView(peer: peer)
                        ConnectionPathView(info: peer)
                        Text("网络 RTT \(ReceiveTiming.text(peer.rttMS))")
                    }.font(.system(size: 14, design: .monospaced))
                    Spacer(minLength: 4)
                    Button("断开", role: .destructive) { disconnect(peer.id) }
                }
            }
            Text(MediaPath.preference).font(.caption).foregroundStyle(.secondary)
            Text("RTT 为网络往返时间，约每 2 秒更新；不是端到端画面延迟。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// Native vector ornamentation shared by macOS and iOS; never decorates media pixels.
enum AppSkin {
    static let key = "appearance.skin"
    static func victorian(_ value: String) -> Bool { value != "minimal" }
    static let choices: [(String, String)] = [("minimal","极简皮肤"),("victorian","维多利亚花饰"),("tang","中国唐式"),("song","中国宋式"),("ming","中国明式"),("scifi","科幻式"),("gothic","哥特式"),("baroque","巴洛克式")]
    private static var selected: String { UserDefaults.standard.string(forKey: key) ?? "victorian" }
    static func colors(_ style: String) -> [Color] {
        switch style {
        case "tang": return [Color(red:1,green:0.96,blue:0.85), Color(red:0.96,green:0.86,blue:0.64), Color(red:0.68,green:0.39,blue:0.12), Color(red:0.53,green:0.12,blue:0.12)]
        case "song": return [Color(red:0.96,green:0.98,blue:0.93), Color(red:0.86,green:0.91,blue:0.84), Color(red:0.42,green:0.56,blue:0.45), Color(red:0.19,green:0.32,blue:0.27)]
        case "ming": return [Color(red:0.99,green:0.96,blue:0.88), Color(red:0.92,green:0.87,blue:0.76), Color(red:0.57,green:0.20,blue:0.17), Color(red:0.30,green:0.20,blue:0.16)]
        case "scifi": return [Color(red:0.94,green:0.98,blue:1), Color(red:0.81,green:0.91,blue:0.95), Color(red:0.12,green:0.51,blue:0.62), Color(red:0.08,green:0.24,blue:0.37)]
        case "gothic": return [Color(red:0.96,green:0.94,blue:0.98), Color(red:0.87,green:0.83,blue:0.91), Color(red:0.46,green:0.32,blue:0.52), Color(red:0.24,green:0.14,blue:0.30)]
        case "baroque": return [Color(red:1,green:0.97,blue:0.88), Color(red:0.96,green:0.86,blue:0.65), Color(red:0.66,green:0.43,blue:0.10), Color(red:0.35,green:0.23,blue:0.16)]
        default: return [Color(red:0.98,green:0.96,blue:0.91), Color(red:0.94,green:0.90,blue:0.81), Color(red:0.62,green:0.47,blue:0.25), Color(red:0.17,green:0.31,blue:0.27)]
        }
    }
    static var paper: Color { colors(selected)[0] }
    static var ivory: Color { colors(selected)[1] }
    static var brass: Color { colors(selected)[2] }
    static var ink: Color { colors(selected)[3] }
    static func ornament(_ style: String) -> String {
        switch style { case "tang": return "◌  云  ◌"; case "song": return "·  ❀  ·"; case "ming": return "回  ◇  回"; case "scifi": return "◇ ─ ◈ ─ ◇"; case "gothic": return "♧  ⟡  ♧"; case "baroque": return "❦  ◆  ❦"; default: return "❧  ❦  ❧" }
    }

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
    @AppStorage(AppSkin.key) private var skin = "victorian"
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
                corner.translateBy(x: 14, y: 14); corner.scaleBy(x: 0.55, y: 0.55)
                var scroll = Path()
                scroll.move(to: CGPoint(x: 0, y: 40)); scroll.addLine(to: .zero); scroll.addLine(to: CGPoint(x: 40, y: 0))
                scroll.move(to: CGPoint(x: 2, y: 30))
                scroll.addCurve(to: CGPoint(x: 20, y: 9), control1: CGPoint(x: 3, y: 6), control2: CGPoint(x: 31, y: 23))
                scroll.addCurve(to: CGPoint(x: 8, y: 19), control1: CGPoint(x: 10, y: -2), control2: CGPoint(x: -1, y: 15))
                scroll.addCurve(to: CGPoint(x: 30, y: 2), control1: CGPoint(x: 29, y: 25), control2: CGPoint(x: 7, y: 3))
                scroll.move(to: CGPoint(x: 6, y: 35))
                scroll.addCurve(to: CGPoint(x: 35, y: 6), control1: CGPoint(x: 31, y: 40), control2: CGPoint(x: 15, y: 13))
                if skin == "tang" {
                    scroll = Path()
                    for offset in [CGFloat(0), 12, 24] {
                        scroll.move(to: CGPoint(x: 1, y: offset + 10))
                        scroll.addCurve(to: CGPoint(x: offset + 14, y: 1), control1: CGPoint(x: offset + 22, y: offset + 22), control2: CGPoint(x: -4, y: -4))
                        scroll.addArc(center: CGPoint(x: offset + 14, y: 6), radius: 5, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: false)
                    }
                } else if skin == "song" {
                    scroll = Path(); scroll.move(to: CGPoint(x: 1,y: 42)); scroll.addQuadCurve(to: CGPoint(x: 28,y: 0), control: CGPoint(x: 6,y: 10))
                    for x in [CGFloat(8), 16, 24] {
                        scroll.move(to: CGPoint(x:x,y:34-x));scroll.addQuadCurve(to:CGPoint(x:x+13,y:16-x/2),control:CGPoint(x:x+17,y:34-x))
                    }
                    for center in [CGPoint(x:10,y:20),CGPoint(x:27,y:5)] {
                        for angle in stride(from: 0.0, to: 360.0, by:72) {
                            let r=angle * .pi/180
                            scroll.addEllipse(in:CGRect(x:center.x+cos(r)*4-2,y:center.y+sin(r)*4-2,width:4,height:4))
                        }
                    }
                } else if skin == "ming" {
                    scroll = Path(); scroll.move(to:CGPoint(x:0,y:40))
                    for point in [CGPoint(x:0,y:0),CGPoint(x:40,y:0),CGPoint(x:40,y:8),CGPoint(x:8,y:8),CGPoint(x:8,y:32),CGPoint(x:16,y:32),CGPoint(x:16,y:16),CGPoint(x:32,y:16),CGPoint(x:32,y:24),CGPoint(x:24,y:24)] {scroll.addLine(to:point)}
                } else if skin == "scifi" {
                    scroll = Path()
                    for offset in [CGFloat(0), 9] {scroll.move(to:CGPoint(x:offset,y:42));scroll.addLine(to:CGPoint(x:offset,y:14));scroll.addLine(to:CGPoint(x:14,y:offset));scroll.addLine(to:CGPoint(x:42,y:offset))}
                    scroll.addRect(CGRect(x:17,y:17,width:6,height:6));scroll.move(to:CGPoint(x:23,y:23));scroll.addLine(to:CGPoint(x:35,y:35))
                } else if skin == "gothic" {
                    scroll=Path();scroll.move(to:CGPoint(x:0,y:42));scroll.addLine(to:CGPoint(x:0,y:18));scroll.addQuadCurve(to:CGPoint(x:18,y:0),control:CGPoint(x:0,y:5));scroll.addQuadCurve(to:CGPoint(x:36,y:18),control:CGPoint(x:36,y:5));scroll.addLine(to:CGPoint(x:36,y:42));scroll.move(to:CGPoint(x:18,y:0));scroll.addLine(to:CGPoint(x:18,y:38));scroll.addEllipse(in:CGRect(x:9,y:13,width:18,height:18))
                } else if skin == "baroque" {
                    scroll.addEllipse(in:CGRect(x:8,y:8,width:27,height:27));scroll.addEllipse(in:CGRect(x:14,y:14,width:15,height:15))
                    scroll.move(to:CGPoint(x:2,y:47));scroll.addCurve(to:CGPoint(x:47,y:2),control1:CGPoint(x:55,y:55),control2:CGPoint(x:-5,y:-5))
                }
                corner.stroke(scroll, with: .color(AppSkin.brass.opacity(0.8)), lineWidth: skin == "baroque" ? 1.3 : 0.8)
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
    @AppStorage(AppSkin.key) private var skin = "victorian"
    let title: String
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Rectangle().frame(height: 0.5)
                Text(AppSkin.ornament(skin)).font(.system(size: 25, design: .serif))
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
            ForEach(AppSkin.choices, id: \.0) { value in Text(LocalizedStringKey(value.1)).tag(value.0) }
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

struct ReceiverAudioControls: View {
    @ObservedObject private var audio = RoomAudioSettings.shared
    @ObservedObject private var room = RoomSession.shared
    @Binding var sound: Bool
    @State private var inputDevices = false
    @State private var outputDevices = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("话筒").font(.caption).frame(width: 30, alignment: .leading)
                AudioActionButton(title: audio.microphoneEnabled ? "话筒已开启" : "话筒已关闭", active: audio.microphoneEnabled) { audio.setReceiverMicrophone(!audio.microphoneEnabled) }.disabled(!room.receiverCanSpeak)
                AudioActionButton(title: audio.testing ? "停止测试" : "测试话筒", active: audio.testing) { audio.setTesting(!audio.testing) }
                CompactAudioButton(kind: .devices, title: "选择话筒设备") { inputDevices = true }
                    .popover(isPresented: $inputDevices) { AudioDeviceSelectionPanel(input: true) }
            }
            HStack(spacing: 8) {
                Text("喇叭").font(.caption).frame(width: 30, alignment: .leading)
                AudioActionButton(title: sound ? "声音已开启" : "声音已关闭", active: sound) { sound.toggle() }
                AudioActionButton(title: "测试喇叭", active: false) { audio.testSpeaker() }
                CompactAudioButton(kind: .devices, title: "选择喇叭设备") { outputDevices = true }
                    .popover(isPresented: $outputDevices) { AudioDeviceSelectionPanel(input: false) }
            }
            if !room.receiverCanSpeak { Text("连接就绪后可开启话筒；测试和设备选择无需连接。").font(.caption).foregroundStyle(.secondary) }
            if !audio.error.isEmpty { Text(audio.error).font(.caption).foregroundStyle(.red) }
        }.onAppear { audio.beginMetering() }.onDisappear { audio.setTesting(false) }
    }
}

struct ConnectionPathView: View {
    let info: PeerDiagnostic?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前媒体路径：" + (info?.route ?? "等待实际路径统计"))
            if let value = info?.networkInterface { Text("本机接口：" + value) }
            if let info { Text("媒体地址/协议：\(info.localEndpoint) → \(info.remoteEndpoint)").foregroundStyle(.secondary) }
            if let value = info?.signals { Text("最近采样传输：" + value) }
            Text("文字聊天及诊断也共用此直连；服务器不转发媒体。")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.caption).textSelection(.enabled)
    }
}

enum AudioGlyphKind { case microphone, speaker, devices }

/// Monochrome engraved outlines, using the same palette as the ornamental controls.
struct AudioGlyph: Shape {
    let kind: AudioGlyphKind
    var off = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .microphone:
            path.addRoundedRect(in: CGRect(x: 9, y: 2, width: 6, height: 12), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 5, y: 10)); path.addCurve(to: CGPoint(x: 19, y: 10), control1: CGPoint(x: 4, y: 22), control2: CGPoint(x: 20, y: 22))
            path.move(to: CGPoint(x: 12, y: 18)); path.addLine(to: CGPoint(x: 12, y: 22))
            path.move(to: CGPoint(x: 8, y: 22)); path.addLine(to: CGPoint(x: 16, y: 22))
        case .speaker:
            path.move(to: CGPoint(x: 3, y: 9)); path.addLines([CGPoint(x: 7, y: 9), CGPoint(x: 12, y: 4), CGPoint(x: 12, y: 20), CGPoint(x: 7, y: 15), CGPoint(x: 3, y: 15)]); path.closeSubpath()
            for x: CGFloat in [16, 20] {
                path.move(to: CGPoint(x: x, y: x == 16 ? 8 : 5))
                path.addQuadCurve(to: CGPoint(x: x, y: x == 16 ? 16 : 19), control: CGPoint(x: x + 5, y: 12))
            }
        case .devices:
            path.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 14), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: CGPoint(x: 8, y: 21)); path.addLine(to: CGPoint(x: 16, y: 21))
            path.move(to: CGPoint(x: 12, y: 18)); path.addLine(to: CGPoint(x: 12, y: 21))
            for x: CGFloat in [8, 12, 16] { path.addEllipse(in: CGRect(x: x - 0.6, y: 10.4, width: 1.2, height: 1.2)) }
        }
        if off && kind != .devices { path.move(to: CGPoint(x: 3, y: 3)); path.addLine(to: CGPoint(x: 21, y: 21)) }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct CompactAudioButton: View {
    let kind: AudioGlyphKind
    let title: String
    var active = false
    var showsOff = false
    var level: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            AudioGlyph(kind: kind, off: showsOff).stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                .frame(width: 21, height: 21)
                .overlay {
                    AudioGlyph(kind: kind, off: showsOff)
                        .stroke(Color(red: 0.24, green: 0.72, blue: 0.37), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .mask(alignment: .bottom) { Rectangle().frame(height: 21 * CGFloat(active ? min(1, max(0, level) * 4) : 0)) }
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: level)
                }
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? Color(red: 0.17, green: 0.40, blue: 0.25) : AppSkin.ink)
                .background { StateOrnament(active: active) }
                .background { AppPaperBackground().clipShape(RoundedRectangle(cornerRadius: 4)) }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? Color.green.opacity(0.6) : AppSkin.brass.opacity(0.6), lineWidth: 0.7))
        }.buttonStyle(.plain).help(LocalizedStringKey(title)).accessibilityLabel(LocalizedStringKey(title))
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct AudioDeviceSelectionPanel: View {
    let input: Bool
    @ObservedObject private var audio = RoomAudioSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(input ? "选择话筒设备" : "选择喇叭设备").font(.headline)
            #if os(iOS)
            if input { options }
            else {
                Text("当前输出：" + audio.outputs.map(\.name).joined(separator: "、")).font(.caption)
                HStack { Text("打开系统音频设备列表").font(.caption); SystemAudioRoutePicker().frame(width: 32, height: 32) }
            }
            #else
            options
            #endif
            if !audio.error.isEmpty { Text(audio.error).font(.caption).foregroundStyle(.red) }
        }.padding(18).frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            .background(AppPaperBackground()).onAppear {
                audio.refreshDevices(); selected = input ? audio.inputID : audio.outputID
            }
    }
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                option("系统默认", id: "")
                ForEach(input ? audio.inputs : audio.outputs) { device in option(device.name, id: device.id) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 280)
    }
    private func option(_ title: String, id: String) -> some View {
        AudioActionButton(title: title, active: selected == id) {
            if input { audio.selectInput(id) } else { audio.selectOutput(id) }
            selected = id; dismiss()
        }
    }
}

struct SenderAudioQuickControls: View {
    @Binding var microphone: Bool
    var microphoneActive: Bool? = nil
    @ObservedObject private var audio = RoomAudioSettings.shared
    @State private var inputDevices = false
    @State private var outputDevices = false
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                CompactAudioButton(kind: .microphone, title: microphone ? ((microphoneActive ?? microphone) ? "话筒已开启" : "话筒待开启") : "话筒已关闭", active: microphoneActive ?? microphone, showsOff: !microphone, level: audio.inputLevel) { microphone.toggle() }
                CompactAudioButton(kind: .devices, title: "选择话筒设备") { inputDevices = true }
                    .popover(isPresented: $inputDevices) { AudioDeviceSelectionPanel(input: true) }
            }
            HStack(spacing: 7) {
                CompactAudioButton(kind: .speaker, title: audio.receivesVoices ? "回传声音已开启" : "回传声音已关闭", active: audio.receivesVoices, showsOff: !audio.receivesVoices, level: audio.outputLevel) { audio.receivesVoices.toggle() }
                CompactAudioButton(kind: .devices, title: "选择喇叭设备") { outputDevices = true }
                    .popover(isPresented: $outputDevices) { AudioDeviceSelectionPanel(input: false) }
            }
        }.onAppear { audio.beginMetering() }
    }
}

struct ConnectionEntryView: View {
    @ObservedObject private var room = RoomSession.shared
    let peer: PeerDiagnostic
    var body: some View {
        HStack(spacing: 7) {
            Text(room.peerOrigins[peer.id] ?? peer.source ?? "来源待识别")
            Text("❦").foregroundStyle(AppSkin.brass).accessibilityHidden(true)
            Text(peer.connectionLabel)
        }.font(.system(size: 13)).foregroundStyle(.secondary)
    }
}
