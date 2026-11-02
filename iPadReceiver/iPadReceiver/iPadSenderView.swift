import SwiftUI
import Combine
import ReplayKit

struct iPadSenderView: View {
    @AppStorage("appMode") private var appMode = "cast"
    @State private var code = ""
    @State private var showDiagnostics = false
    @State private var peers: [PeerDiagnostic] = []
    @State private var localIPs = ""
    @State private var signalPort = 0
    @State private var internetPort = 0
    @State private var pageAudio = false
    @State private var micAudio = false
    @State private var bitrate = 8_000_000
    @State private var internetEnabled = false
    @State private var internetMatchingEnabled = true
    @State private var internetStatus = ""
    @State private var fps = 30
    @State private var resolution = 1600
    @State private var loadedConfiguration = false
    @State private var resolutionStatus = ""
    @State private var configurationReady = false
    @State private var active = false
    @State private var status = "等待开始"
    @State private var saveGeneration = UUID()
    @State private var queuedConfiguration = ""
    @State private var refreshing = false
    private static let settingsQueue = DispatchQueue(label: "casting.sender.settings", qos: .userInitiated)
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppPresentation.title).font(.system(size: 20, weight: .semibold))
                        Text("投屏工作台").font(.system(size: 32, weight: .semibold))
                        Text("将这台 iPad 的画面分享给 Mac 或另一台 iPad")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { appMode = "receive" } label: { Label(AppPresentation.receiveWorkbench, systemImage: "arrow.down.left") }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 24) {
                    Label(active ? "正在投屏" : "整屏投屏", systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 23, weight: .semibold))
                    Text("匹配码").foregroundStyle(.secondary)
                    TextField("6–36 位数字", text: $code)
                        .font(.system(size: 42, weight: .medium, design: .monospaced))
                        .keyboardType(.default)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260).disabled(active)
                        .onChange(of: code) { value in
                            saveConfiguration()
                        }
                    Text("接收设备选择匹配码连接。投屏包含屏幕上的所有可采集内容，请先关闭不想分享的信息。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("码率").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(bitrate / 1_000_000) Mbps")
                                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                            }
                            Slider(value: Binding(get: { Double(bitrate) / 1_000_000 },
                                                  set: { bitrate = BroadcastSettings.clampedBitrate(Int($0 * 1_000_000)) }),
                                   in: 8...100, step: 2)
                                .accessibilityLabel("广播码率")
                        }.frame(maxWidth: 360)
                        Picker("帧率", selection: $fps) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }.pickerStyle(.segmented).frame(maxWidth: 200)
                    }.disabled(active)
                    Picker("分辨率", selection: Binding(get: { resolution }, set: { value in
                        resolution = value
                        saveConfiguration()
                        PerformanceDisk.shared.write("resolution.selected requestedLimit=\(value) stored=\(BroadcastSettings.store.string(forKey: "broadcastResolution") ?? "missing")")
                    })) {
                        Text("流畅 · 1600").tag(1600)
                        Text("高清 · 1920").tag(1920)
                        Text("原生采集").tag(0)
                    }.pickerStyle(.segmented).disabled(active)
                    Text("按最长边限制，保持画面比例。原生使用系统提供的尺寸；更高分辨率会增加设备和网络负担。设置在下次广播生效。")
                        .foregroundStyle(.secondary)
                    if active, !resolutionStatus.isEmpty {
                        Text(resolutionStatus).font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Toggle("允许广域网直连", isOn: $internetEnabled).toggleStyle(.switch).disabled(active)
                    if internetEnabled {
                        Toggle("允许广域网匹配码", isOn: $internetMatchingEnabled).toggleStyle(.switch).disabled(active)
                        Text(active ? internetStatus : "公网 IP 使用端口 9318；匹配码仅交换连接信息，视频不经服务器。")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("发送页面声音", isOn: $pageAudio).toggleStyle(.switch)
                    Toggle("发送话筒声音", isOn: $micAudio).toggleStyle(.switch)
                    Text("话筒需先在系统广播面板打开麦克风；此处可随时静音或恢复。").foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        SystemBroadcastButton().frame(width: 64, height: 64)
                            .allowsHitTesting(MatchingCode.isValid(code) && configurationReady).opacity(MatchingCode.isValid(code) && configurationReady ? 1 : 0.35)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(active ? "停止屏幕广播" : "开始屏幕广播").font(.system(size: 21, weight: .semibold))
                            Text("点击左侧系统录屏按钮").foregroundStyle(.secondary)
                        }
                    }
                    Text(status).foregroundStyle(active ? .green : .secondary)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 16) {
                    Button { showDiagnostics.toggle() } label: { Label("诊断", systemImage: "waveform.path.ecg") }
                    if showDiagnostics {
                        Text("本机地址：\(localIPs.isEmpty ? "—" : localIPs)")
                        Text("局域网信令端口 \(active && signalPort > 0 ? String(signalPort) : "未监听") · 广域网 IP 信令端口 \(active && internetPort > 0 ? String(internetPort) : "未监听")")
                            .font(.system(size: 14, design: .monospaced))
                        PeerDiagnosticsView(peers: peers) { id in BroadcastSettings.store.set(id, forKey: "broadcastKick") }
                            .disabled(!active)
                    }
                }
                Text("在系统弹窗中确认开始后，可以切换到其他应用继续投屏。系统不允许静默启动录屏；受保护的视频可能不会显示。声音可分别选择页面与话筒。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 18)).padding(32).frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.035, green: 0.05, blue: 0.075).ignoresSafeArea())
        .tint(Color(red: 0.34, green: 0.70, blue: 1))
        .onReceive(timer) { _ in refreshStatus() }
        .task {
            loadedConfiguration = false
            let initial = await Self.readSettings()
            guard !Task.isCancelled else { return }
            pageAudio = initial.pageAudio
            micAudio = initial.micAudio
            let storedResolution = initial.resolution
            PerformanceDisk.shared.write("resolution.loaded stored=\(storedResolution ?? "missing") screen=\(Int(UIScreen.main.nativeBounds.width))x\(Int(UIScreen.main.nativeBounds.height))")
            let savedCode = initial.code
            code = MatchingCode.isValid(savedCode) ? savedCode! : MatchingCode.generate()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--verify-sender-code"), index + 1 < args.count,
               MatchingCode.isValid(args[index + 1]) { code = args[index + 1] }
            #endif
            let storedBitrate = initial.bitrate
            bitrate = BroadcastSettings.clampedBitrate(storedBitrate)
            fps = initial.fps == 60 ? 60 : 30
            resolution = BroadcastSettings.resolutionLimit(Int(storedResolution ?? "1600") ?? 1600)
            internetEnabled = initial.internetEnabled
            internetMatchingEnabled = initial.internetMode != "ipOnly"
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-internet-sender") {
                internetEnabled = true; internetMatchingEnabled = true
            }
            #endif
            loadedConfiguration = true
            saveConfiguration()
            refreshStatus()
        }
        .onChange(of: pageAudio) { _ in saveConfiguration() }
        .onChange(of: micAudio) { _ in saveConfiguration() }
        .onChange(of: bitrate) { _ in saveConfiguration() }
        .onChange(of: fps) { _ in saveConfiguration() }
        .onChange(of: internetEnabled) { _ in saveConfiguration() }
        .onChange(of: internetMatchingEnabled) { _ in saveConfiguration() }
    }

    private func saveConfiguration() {
        guard loadedConfiguration else { return }
        guard MatchingCode.isValid(code) else {
            saveGeneration = UUID(); queuedConfiguration = ""
            configurationReady = false
            status = "请输入 6–36 位数字匹配码"
            return
        }
        let values: [(String, Any)] = [("broadcastPageAudio", pageAudio), ("broadcastMicAudio", micAudio),
            ("broadcastInternetMode", internetMatchingEnabled ? "both" : "ipOnly"),
            ("broadcastInternetEnabled", internetEnabled), ("broadcastCode", code),
            ("broadcastBitrate", bitrate), ("broadcastFPS", fps), ("broadcastResolution", String(resolution)),
            ("broadcastScreenPixels", "\(Int(UIScreen.main.nativeBounds.width))x\(Int(UIScreen.main.nativeBounds.height))")]
        let fingerprint = values.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
        guard fingerprint != queuedConfiguration else { return }
        queuedConfiguration = fingerprint
        let generation = UUID(); saveGeneration = generation
        configurationReady = false
        Self.settingsQueue.async {
            let store = BroadcastSettings.store
            let saved = values.map { store.set($0.1, forKey: $0.0) }.allSatisfy { $0 }
            DispatchQueue.main.async {
                guard saveGeneration == generation else { return }
                configurationReady = saved
                if !saved { queuedConfiguration = ""; status = "投屏配置无法共享，请检查应用签名" }
                else { refreshStatus() }
            }
        }
    }

    private func refreshStatus() {
        guard configurationReady, !refreshing else { return }
        refreshing = true
        Self.settingsQueue.async {
            let snapshot = SenderLiveStatus()
            DispatchQueue.main.async {
                refreshing = false
                active = snapshot.active; peers = snapshot.peers; localIPs = snapshot.localIPs
                signalPort = snapshot.signalPort; internetPort = snapshot.internetPort
                internetStatus = snapshot.internetStatus; resolutionStatus = snapshot.resolutionStatus
                status = !snapshot.active && snapshot.status == "正在投屏" ? "投屏已结束" : snapshot.status
            }
        }
    }

    private struct SenderInitialSettings {
        let pageAudio = BroadcastSettings.store.bool(forKey: "broadcastPageAudio")
        let micAudio = BroadcastSettings.store.bool(forKey: "broadcastMicAudio")
        let code = BroadcastSettings.store.string(forKey: "broadcastCode")
        let bitrate = BroadcastSettings.store.integer(forKey: "broadcastBitrate")
        let fps = BroadcastSettings.store.integer(forKey: "broadcastFPS")
        let resolution = BroadcastSettings.store.string(forKey: "broadcastResolution")
        let internetEnabled = BroadcastSettings.store.bool(forKey: "broadcastInternetEnabled")
        let internetMode = BroadcastSettings.store.string(forKey: "broadcastInternetMode")
    }
    private static func readSettings() async -> SenderInitialSettings {
        await withCheckedContinuation { continuation in
            settingsQueue.async { continuation.resume(returning: SenderInitialSettings()) }
        }
    }
    private struct SenderLiveStatus {
        let active: Bool
        let peers: [PeerDiagnostic]
        let localIPs: String
        let signalPort: Int
        let internetPort: Int
        let internetStatus: String
        let resolutionStatus: String
        let status: String
        init() {
            active = BroadcastSettings.isActive
            let store = BroadcastSettings.store
            peers = active ? (store.string(forKey: "broadcastPeers").flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([PeerDiagnostic].self, from: $0) } ?? []) : []
            localIPs = store.string(forKey: "broadcastLocalIPs") ?? ""
            signalPort = store.integer(forKey: "broadcastSignalPort")
            internetPort = store.integer(forKey: "broadcastInternetPort")
            internetStatus = store.string(forKey: "broadcastInternetStatus") ?? "等待广域网匹配"
            resolutionStatus = store.string(forKey: "broadcastResolutionStatus") ?? ""
            status = store.string(forKey: "broadcastStatus") ?? "等待开始"
        }
    }
}

private struct SystemBroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        picker.showsMicrophoneButton = true
        picker.tintColor = .systemBlue
        picker.accessibilityLabel = "开始或停止屏幕投屏"
        return picker
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
