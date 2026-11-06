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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AudioLevelIcon(symbol: "mic.fill", level: audio.inputLevel)
                Picker("麦克风设备", selection: $input) {
                    Text("系统默认").tag("")
                    ForEach(audio.inputs) { Text(verbatim: $0.name).tag($0.id) }
                }
            }
            if receiver {
                Toggle("向所有人发送麦克风", isOn: Binding(get: { audio.microphoneEnabled }, set: { audio.setMicrophone($0) }))
                    .disabled(!room.receiverCanSpeak)
                if !room.receiverCanSpeak { Text("连接到新版投送端后可开启共用麦克风").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Toggle("测试麦克风（仅看音量，不发送）", isOn: Binding(get: { audio.testing }, set: { audio.setTesting($0) }))
                Button("刷新设备") { audio.refreshDevices() }
            }
            HStack {
                AudioLevelIcon(symbol: "speaker.wave.2.fill", level: audio.outputLevel)
                #if os(macOS)
                Picker("声音输出设备", selection: $output) {
                    Text("系统默认").tag("")
                    ForEach(audio.outputs) { Text(verbatim: $0.name).tag($0.id) }
                }
                #else
                Text("声音输出由系统路由选择")
                SystemAudioRoutePicker().frame(width: 36, height: 36)
                #endif
                Button("测试喇叭") { audio.testSpeaker() }
            }
            if !receiver { Toggle("接收接收方麦克风（全员共用）", isOn: $audio.receivesVoices) }
            Text("绿色表示当前音量；设备权限、蓝牙及输出切换以系统支持为准。多人语音建议使用耳机，避免扬声器回声。")
                .font(.caption).foregroundStyle(.secondary)
            if !audio.error.isEmpty { Text(audio.error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { audio.beginMetering() }
        .onDisappear { audio.setTesting(false) }
        .onChange(of: input) { audio.selectInput($0) }
        .onChange(of: output) { audio.selectOutput($0) }
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

private struct AudioVine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        for x in stride(from: CGFloat(4), to: rect.width, by: 11) {
            p.move(to: CGPoint(x: x, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: x + 6, y: 0), control: CGPoint(x: x, y: 0))
            p.addQuadCurve(to: CGPoint(x: x, y: rect.midY), control: CGPoint(x: x + 6, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: x + 7, y: rect.maxY), control: CGPoint(x: x + 7, y: rect.midY))
        }; return p
    }
}

struct AudioActionButton: View {
    let title: String
    let active: Bool
    var symbol: String? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol) }
                    if !title.isEmpty { Text(LocalizedStringKey(title)) }
                }.font(.system(size: 14, weight: .medium))
                AudioVine().trim(from: 0, to: active ? 1 : 0).stroke(Color.green, lineWidth: 1)
                    .frame(height: 6).animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: active)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(active ? Color.green : Color.primary)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color.green.opacity(0.7) : Color.secondary.opacity(0.25)))
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }
}


#if os(iOS)
struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
