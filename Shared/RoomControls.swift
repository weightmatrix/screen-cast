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

struct RoomChatOverlay: View {
    @ObservedObject private var room = RoomSession.shared
    @AppStorage("room.chatCorner") private var corner = ChatCorner.bottomLeft.rawValue
    @AppStorage("room.chatOpacity") private var opacity = 0.9
    @State private var open = false
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if open {
                HStack { Text("共用聊天室").font(.headline); Text(verbatim: room.nickname).font(.caption) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(room.messages) { message in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: message.author).font(.caption.bold())
                                    Text(verbatim: message.text).font(.body).textSelection(.enabled)
                                }.id(message.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 190)
                        .onChange(of: room.messages.last?.id) { _ in if let id = room.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                HStack {
                    TextField("输入文字，所有人可见", text: $draft).textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button("发送") { send() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !room.error.isEmpty { Text(room.error).font(.caption).foregroundStyle(.red) }
            }
            Button { open.toggle() } label: { Label(LocalizedStringKey(open ? "收起聊天" : "聊天"), systemImage: "text.bubble") }
        }
        .padding(12).frame(width: 310)
        .background(.regularMaterial.opacity(max(0.35, min(1, opacity))), in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: (ChatCorner(rawValue: corner) ?? .bottomLeft).alignment)
    }
    private func send() { if room.send(draft) { draft = "" } }
}

#if os(iOS)
private struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
