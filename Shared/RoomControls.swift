import SwiftUI
#if os(iOS)
import AVKit
#endif

enum ChatCorner: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var title: String { switch self { case .bottomLeft: "左下角"; case .bottomRight: "右下角"; case .topLeft: "左上角"; case .topRight: "右上角" } }
    var alignment: Alignment { switch self { case .bottomLeft: .bottomLeading; case .bottomRight: .bottomTrailing; case .topLeft: .topLeading; case .topRight: .topTrailing } }
}

struct RoomPreferences: View {
    @AppStorage("room.nickname") private var nickname = ""
    @AppStorage("room.chatCorner") private var corner = ChatCorner.bottomLeft.rawValue
    @AppStorage("room.chatOpacity") private var opacity = 0.9
    var body: some View {
        Section("共用聊天室") {
            TextField("昵称（留空自动分配，最多32字）", text: $nickname)
                .onChange(of: nickname) { value in
                    if value.count > 32 { nickname = String(value.prefix(32)) }; RoomSession.shared.refreshNickname()
                }
            Picker("聊天位置", selection: $corner) {
                ForEach(ChatCorner.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value.rawValue) }
            }
            HStack { Text("透明度"); Slider(value: $opacity, in: 0.35...1) }
            Text("昵称由使用者自行填写，不代表真实身份。聊天仅保留当前会话最近200条，不上传服务器。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AudioLevelIcon: View {
    let symbol: String
    let level: Float
    var body: some View {
        Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(.secondary)
            .overlay(alignment: .bottom) {
                Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(.green)
                    .mask(alignment: .bottom) { Rectangle().frame(height: 30 * CGFloat(max(0, min(1, level)))) }
            }
            .frame(width: 34, height: 34)
            .accessibilityLabel("音量 \(Int(max(0, min(1, level)) * 100))%")
    }
}

struct RoomAudioControls: View {
    @ObservedObject private var audio = RoomAudioSettings.shared
    @ObservedObject private var room = RoomSession.shared
    @State private var input = UserDefaults.standard.string(forKey: "room.inputDevice") ?? ""
    @State private var output = UserDefaults.standard.string(forKey: "room.outputDevice") ?? ""
    var receiver = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("麦克风").font(.headline)
                HStack(spacing: 8) {
                    AudioLevelIcon(symbol: "mic.fill", level: audio.inputLevel)
                    if receiver {
                        AudioActionButton(title: audio.microphoneEnabled ? "关闭麦克" : "开启麦克", active: audio.microphoneEnabled) { audio.setMicrophone(!audio.microphoneEnabled) }.disabled(!room.receiverCanSpeak)
                    }
                    AudioActionButton(title: audio.testing ? "停止测试" : "测试麦克", active: audio.testing) { audio.setTesting(!audio.testing) }
                }
                Picker("麦克风设备", selection: $input) {
                    Text("系统默认").tag(""); ForEach(audio.inputs) { Text(verbatim: $0.name).tag($0.id) }
                }
                if !receiver { Text("投屏话筒请在对应投屏源的设置中开启。").font(.caption).foregroundStyle(.secondary) }
                if receiver && !room.receiverCanSpeak { Text("连接就绪后可开启麦克；测试和设备选择无需连接。").font(.caption).foregroundStyle(.secondary) }
            }.padding(16).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
            VStack(alignment: .leading, spacing: 12) {
                Text("喇叭").font(.headline)
                HStack(spacing: 8) {
                    AudioLevelIcon(symbol: "speaker.wave.2.fill", level: audio.outputLevel)
                    AudioActionButton(title: audio.receivesVoices ? "关闭声音" : "开启声音", active: audio.receivesVoices) { audio.receivesVoices.toggle() }
                    AudioActionButton(title: "测试喇叭", active: false) { audio.testSpeaker() }
                }
                #if os(macOS)
                Picker("声音输出设备", selection: $output) {
                    Text("系统默认").tag(""); ForEach(audio.outputs) { Text(verbatim: $0.name).tag($0.id) }
                }
                #else
                HStack { Text("声音输出由系统选择").font(.caption); SystemAudioRoutePicker().frame(width: 30, height: 30) }
                #endif
                Text("这里控制共用语音的播放；投屏原声由接收页喇叭控制。").font(.caption).foregroundStyle(.secondary)
            }.padding(16).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
            Button("刷新设备") { audio.refreshDevices() }
            Text("绿色音量图标表示当前音量。多人语音建议使用耳机，避免扬声器回声。").font(.caption).foregroundStyle(.secondary)
            if !audio.error.isEmpty { Text(audio.error).font(.caption).foregroundStyle(.red) }
        }.onAppear { audio.beginMetering() }.onDisappear { audio.setTesting(false) }
            .onChange(of: input) { audio.selectInput($0) }.onChange(of: output) { audio.selectOutput($0) }
    }
}

struct RoomChatPanel: View {
    @ObservedObject private var room = RoomSession.shared
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("共用聊天室").font(.headline); Spacer(); Text(verbatim: room.nickname).font(.caption).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(room.messages) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: message.author).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(verbatim: message.text).font(.body).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                        }
                    }
                }.frame(height: 145)
                .onChange(of: room.messages.last?.id) { _ in if let id = room.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack {
                TextField("输入文字，所有人可见", text: $draft).textFieldStyle(.roundedBorder).onSubmit { send() }
                Button("发送") { send() }.buttonStyle(.bordered).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !room.error.isEmpty { Text(room.error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func send() { if room.send(draft) { draft = "" } }
}

struct RoomChatOverlay: View {
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if open {
                RoomChatPanel().padding(14).frame(width: 290)
                    .background(.regularMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
            Button { open.toggle() } label: {
                Image(systemName: open ? "xmark" : "text.bubble").font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30).contentShape(Circle())
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(open ? "收起聊天" : "聊天")
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// A rooted vine graph: a main stem, secondary scrolls and tertiary tendrils.
/// Each child starts only after the drawing front reaches its attachment point.
private enum VineTopology {
    struct Branch {
        let path: Path
        let start: Double
        let duration: Double
        let width: CGFloat
        let depth: Int
    }
    static func point(_ path: Path, _ fraction: CGFloat) -> CGPoint {
        path.trimmedPath(from: 0, to: max(0.001, min(1, fraction))).currentPoint ?? .zero
    }
    static func scroll(from root: CGPoint, centre: CGPoint, radius: CGFloat, direction: CGFloat) -> Path {
        var path = Path(); path.move(to: root)
        let entry = CGPoint(x: centre.x + radius * direction, y: centre.y)
        path.addCurve(to: entry,
            control1: CGPoint(x: root.x + (centre.x - root.x) * 0.35, y: root.y - radius * 1.4),
            control2: CGPoint(x: entry.x, y: entry.y - radius * 1.3))
        // A tapering spiral, not a row of identical circular ornaments.
        for step in 1...44 {
            let phase = CGFloat(step) / 44
            let angle = phase * .pi * 2.7
            let r = radius * (1 - phase * 0.94)
            path.addLine(to: CGPoint(x: centre.x + cos(angle) * r * direction, y: centre.y + sin(angle) * r))
        }
        return path
    }
    static let branches: [Branch] = {
        var trunk = Path(); trunk.move(to: CGPoint(x: 101, y: 80))
        trunk.addCurve(to: CGPoint(x: 106, y: 43), control1: CGPoint(x: 87, y: 67), control2: CGPoint(x: 119, y: 58))
        trunk.addCurve(to: CGPoint(x: 98, y: 5), control1: CGPoint(x: 80, y: 27), control2: CGPoint(x: 116, y: 16))
        var result = [Branch(path: trunk, start: 0, duration: 0.54, width: 2.4, depth: 0)]
        for (tier, fraction) in [CGFloat(0.19), 0.39, 0.60, 0.80].enumerated() {
            let root = point(trunk, fraction)
            // Both sides sprout from the same growing stem, without a left-to-right sweep.
            for direction: CGFloat in [-1, 1] {
                let reach = CGFloat([55, 68, 58, 43][tier])
                let centre = CGPoint(x: min(181, max(19, root.x + direction * reach)), y: min(63, max(17, root.y - CGFloat(tier * 2 + 4))))
                let branch = Branch(path: scroll(from: root, centre: centre, radius: CGFloat(15 - tier), direction: direction),
                    start: 0.54 * Double(fraction) + 0.015, duration: 0.30, width: 1.45, depth: 1)
                result.append(branch)
                for (index, attachment) in [CGFloat(0.28), 0.57].enumerated() {
                    let joint = point(branch.path, attachment)
                    let centre = CGPoint(x: min(190, max(10, joint.x + direction * CGFloat(index == 0 ? -13 : 16))),
                                         y: min(70, max(10, joint.y + CGFloat(index == 0 ? -12 : 10))))
                    result.append(Branch(path: scroll(from: joint, centre: centre, radius: CGFloat(index == 0 ? 7 : 5), direction: -direction),
                        start: branch.start + branch.duration * Double(attachment) + 0.015, duration: 0.21, width: 0.85, depth: 2))
                }
            }
        }
        return result
    }()
    static func leaf(at point: CGPoint, angle: CGFloat, length: CGFloat, opening: CGFloat) -> Path {
        let side = length * 0.38 * opening
        var path = Path(); path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.4, y: -side))
        path.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.65, y: side))
        return path.applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
    }
}

/// One reversible animation clock keeps every child attached, including rapid toggles.
private struct VineGrowth: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.scaleBy(x: size.width / 200, y: size.height / 80)
            let ink = Color(red: 0.16, green: 0.43, blue: 0.25)
            for branch in VineTopology.branches {
                let grown = max(0, min(1, (progress - branch.start) / branch.duration))
                guard grown > 0 else { continue }
                context.stroke(branch.path.trimmedPath(from: 0, to: grown), with: .color(ink),
                               style: StrokeStyle(lineWidth: branch.width, lineCap: .round, lineJoin: .round))
                guard branch.depth > 0 else { continue }
                for (index, attachment) in [CGFloat(0.34), 0.72].enumerated() {
                    let opening = max(0, min(1, (grown - attachment) / 0.18))
                    guard opening > 0 else { continue }
                    let joint = VineTopology.point(branch.path, attachment)
                    let before = VineTopology.point(branch.path, attachment - 0.025)
                    let angle = atan2(joint.y - before.y, joint.x - before.x) + (index == 0 ? -0.9 : 0.9)
                    let leaf = VineTopology.leaf(at: joint, angle: angle, length: branch.depth == 1 ? 9 : 6, opening: opening)
                    context.fill(leaf, with: .color(ink.opacity(opening)))
                }
            }
        }
    }
}

struct StateOrnament: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VineGrowth(progress: active ? 1 : 0)
            .padding(3).opacity(0.40).clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.65), value: active)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AudioActionButton: View {
    let title: String
    let active: Bool
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                if !title.isEmpty { Text(LocalizedStringKey(title)) }
            }.font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(active ? Color(red: 0.17, green: 0.40, blue: 0.25) : Color.primary)
                .background { StateOrnament(active: active) }
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color(red: 0.20, green: 0.48, blue: 0.30).opacity(0.65) : Color.secondary.opacity(0.25)))
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct OrnamentalToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(configuration.isOn ? Color(red: 0.17, green: 0.40, blue: 0.25) : Color.primary)
                .background { StateOrnament(active: configuration.isOn) }
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(configuration.isOn ? Color(red: 0.20, green: 0.48, blue: 0.30).opacity(0.65) : Color.secondary.opacity(0.25)))
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

#if os(iOS)
struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
