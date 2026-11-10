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
    var senderMicrophone: Binding<Bool>? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("话筒").font(.headline)
                HStack(spacing: 8) {
                    AudioLevelIcon(symbol: "mic.fill", level: audio.inputLevel)
                    if let senderMicrophone {
                        AudioActionButton(title: senderMicrophone.wrappedValue ? "话筒已开启" : "话筒已关闭", active: senderMicrophone.wrappedValue) { senderMicrophone.wrappedValue.toggle() }
                    } else if receiver {
                        AudioActionButton(title: audio.microphoneEnabled ? "话筒已开启" : "话筒已关闭", active: audio.microphoneEnabled) { audio.setReceiverMicrophone(!audio.microphoneEnabled) }.disabled(!room.receiverCanSpeak)
                    }
                    AudioActionButton(title: audio.testing ? "停止测试" : "测试话筒", active: audio.testing) { audio.setTesting(!audio.testing) }
                }
                Picker("话筒设备", selection: $input) {
                    Text("系统默认").tag(""); ForEach(audio.inputs) { Text(verbatim: $0.name).tag($0.id) }
                }
                if !receiver && senderMicrophone == nil { Text("投屏话筒请在对应投屏源的设置中开启。").font(.caption).foregroundStyle(.secondary) }
                if receiver && !room.receiverCanSpeak { Text("连接就绪后可开启话筒；测试和设备选择无需连接。").font(.caption).foregroundStyle(.secondary) }
            }.padding(16).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
            VStack(alignment: .leading, spacing: 12) {
                Text("喇叭").font(.headline)
                HStack(spacing: 8) {
                    AudioLevelIcon(symbol: "speaker.wave.2.fill", level: audio.outputLevel)
                    AudioActionButton(title: audio.receivesVoices ? "声音已开启" : "声音已关闭", active: audio.receivesVoices) { audio.receivesVoices.toggle() }
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

/// Four corner tendrils curl inward; left-hand paths are drawn before right-hand paths.
struct StateFlourish: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (right, bottom) in [(false, false), (false, true), (true, false), (true, true)] {
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + (right ? 100 - x : x) * rect.width / 100,
                        y: rect.minY + (bottom ? 40 - y : y) * rect.height / 40)
            }
            path.move(to: pt(1, 2))
            path.addCurve(to: pt(48, 19), control1: pt(9, 0), control2: pt(19, 31))
            path.addCurve(to: pt(33, 12), control1: pt(59, 8), control2: pt(34, 2))
            path.addCurve(to: pt(43, 14), control1: pt(30, 22), control2: pt(48, 22))
            path.move(to: pt(4, 5))
            path.addCurve(to: pt(23, 8), control1: pt(15, -1), control2: pt(27, 0))
            path.addCurve(to: pt(15, 7), control1: pt(19, 16), control2: pt(10, 13))
            path.addCurve(to: pt(21, 7), control1: pt(13, 1), control2: pt(23, 2))
            path.move(to: pt(10, 11))
            path.addCurve(to: pt(9, 23), control1: pt(0, 9), control2: pt(1, 25))
            path.addCurve(to: pt(13, 16), control1: pt(17, 28), control2: pt(19, 15))
            path.addQuadCurve(to: pt(10, 21), control: pt(6, 16))
            path.move(to: pt(25, 17))
            path.addQuadCurve(to: pt(31, 25), control: pt(20, 27))
            path.addQuadCurve(to: pt(25, 17), control: pt(36, 19))
            path.move(to: pt(15, 11))
            path.addCurve(to: pt(28, 5), control1: pt(15, 0), control2: pt(32, 0))
            path.addCurve(to: pt(22, 6), control1: pt(29, 12), control2: pt(18, 12))
            path.addQuadCurve(to: pt(26, 5), control: pt(21, 1))
            path.move(to: pt(31, 19))
            path.addCurve(to: pt(40, 30), control1: pt(45, 15), control2: pt(49, 29))
            path.addCurve(to: pt(36, 25), control1: pt(31, 31), control2: pt(30, 20))
            path.addQuadCurve(to: pt(39, 27), control: pt(43, 22))
            path.move(to: pt(8, 23))
            path.addCurve(to: pt(20, 32), control1: pt(7, 33), control2: pt(25, 39))
            path.addQuadCurve(to: pt(17, 28), control: pt(13, 36))
            for (base, tip, bend) in [(pt(18, 8), pt(23, 1), pt(15, 1)), (pt(26, 17), pt(33, 13), pt(28, 11)), (pt(36, 20), pt(44, 24), pt(43, 17))] {
                path.move(to: base); path.addQuadCurve(to: tip, control: bend)
                path.addQuadCurve(to: base, control: CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2))
            }
        }
        return path
    }
}

struct StateOrnament: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        StateFlourish().trim(from: 0, to: active ? 1 : 0)
            .stroke(Color(red: 0.20, green: 0.48, blue: 0.30), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            .padding(3).opacity(0.36)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: active)
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
