import SwiftUI
import AppKit
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = streamer.contentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            StreamListView(streamer: streamer, onAdd: onAdd)
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AppPaperBackground()

                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .task { streamer.loadShareableContent() }
    }


}

// Shared native styling; no changes to capture or transport behavior.
enum CastStyle {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let accent = Color.accentColor
}

/// A symbolic sharing illustration, never a simulated screen preview.
private struct SharingIllustration: View {
    var compact = false
    @AppStorage("appearance.skin") private var skin = "victorian"
    var body: some View {
        ZStack {
            if AppSkin.victorian(skin) {
                VStack(spacing: 12) {
                    Text("❦").font(.system(size: 38, design: .serif)).foregroundStyle(AppSkin.brass)
                    Image(systemName: "display.2").font(.system(size: compact ? 28 : 36, weight: .ultraLight)).foregroundStyle(AppSkin.ink)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).appPanelStyle()
            } else {
            RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous)
                .fill(LinearGradient(colors: [Color.blue.opacity(0.14), Color.indigo.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "display.2")
                .font(.system(size: compact ? 40 : 56, weight: .light))
                .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .blue.opacity(0.16), radius: 12, y: 6)
            }
        }
        .frame(width: compact ? 112 : 144, height: compact ? 100 : 128)
        .accessibilityHidden(true)
    }
}

private struct StreamListView: View {
    @ObservedObject var streamer: ScreenStreamer
    let onAdd: () -> Void
    @State private var editSession: StreamSession? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if streamer.sessions.isEmpty {
                    VStack(spacing: 16) {
                        SharingIllustration().padding(.bottom, 8)
                        Text("让画面，自由连接").font(.system(size: 27, weight: .semibold))
                        Text("选择屏幕、应用或窗口，连接你的另一块屏幕。")
                            .font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 42)
                    .appPanelStyle()
                }
                ForEach(streamer.sessions) { session in
                    SessionRow(session: session, streamer: streamer, onStop: { streamer.removeSession(session) }, onEdit: { editSession = session })
                }
                if streamer.sessions.isEmpty { Button(action: onAdd) {
                    Label("添加投屏", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(AppGlassButtonStyle()) }
            }
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .sheet(item: $editSession) { session in
            EditStreamSheet(session: session, streamer: streamer)
        }
    }
}

private struct CodeEditorFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct BrowserSenderAddresses: View {
    @ObservedObject var server: CastingServer
    let code: String
    let internet: Bool
    @State private var copied = ""
    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                if let port = server.browserListeningPort,
                   let ip = CastingServer.localIPs.first(where: BrowserReceiverServer.isLocalAddress) {
                    address("局域网", InternetSettings.localBrowserAddress(ip: ip, port: port, code: code))
                } else {
                    Button {} label: {
                        Label("复制局域网地址", systemImage: "wifi")
                    }
                    .controlSize(.large)
                    .disabled(true)
                    .help(server.browserListeningPort == nil ? "局域网接收服务准备中，请稍候" : "未检测到局域网地址，请连接 Wi-Fi 或有线网络")
                }
            }
            if internet { address("公网", InternetSettings.browserAddress(code: code)) }
        }
    }
    private func address(_ title: String, _ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            copied = value
        } label: {
            Label(copied == value ? "已复制\(title)地址" : "复制\(title)地址", systemImage: copied == value ? "checkmark" : (title == "公网" ? "globe" : "wifi"))
        }
        .controlSize(.large)
        .help(value).accessibilityLabel("复制\(title)网页接收地址")
    }
}

private struct SessionRow: View {
    @ObservedObject var session: StreamSession
    @ObservedObject var streamer: ScreenStreamer
    let onStop: () -> Void
    let onEdit: () -> Void
    @State private var editingCode = false
    @State private var codeDraft = ""
    @State private var codeError = false
    @FocusState private var codeFocused: Bool
    @State private var codeEditorFrame = CGRect.zero
    @StateObject private var codeSuggestion = MatchingCodeSuggestion()
    @State private var localCodeSuggestion: String?
    @State private var showSettings = false
    @State private var showConnections = false

    @State private var controlsCollapsed = false
    var body: some View {
        VStack(spacing: 12) {
            if controlsCollapsed {
                HStack {
                    Text(session.contentName).lineLimit(1)
                    Spacer()
                    Text("\(session.clientCount) 台已连接").font(.caption).foregroundStyle(.secondary)
                    Button("展开") { controlsCollapsed = false }
                    Button(action: onStop) { Image(systemName: "stop.fill").foregroundStyle(.red) }
                }.padding(12).background(AppPaperBackground())
            } else { expandedControls }
            RoomChatPanel().padding(22).appPanelStyle()
        }.onReceive(session.server.$pendingConnections) { if !$0.isEmpty { controlsCollapsed = false; showConnections = true } }
    }
    private var expandedControls: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                Button { controlsCollapsed = true } label: { Image(systemName: "chevron.up") }.help("收成一行")
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.contentName).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                    if case .failed(let message) = session.phase {
                        Text(message).foregroundStyle(.red).lineLimit(2)
                    } else if session.phase == .starting {
                        Text("正在连接画面…").foregroundStyle(.orange)
                    } else {
                        Text("正在共享").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        statusDot
                        Text(session.clientCount == 0 ? "等待接收" : "\(session.clientCount) 台已连接")
                            .font(.system(size: 18, weight: .semibold))
                    }.padding(.horizontal, 16).frame(minHeight: 46)
                        .background(.primary.opacity(0.04), in: Capsule())
                    Button { showConnections.toggle() } label: { Label("连接", systemImage: "link") }
                        .buttonStyle(AppGlassButtonStyle())
                        .popover(isPresented: $showConnections) {
                            SessionDiagnosticsView(session: session, server: session.server)
                                .buttonStyle(AppGlassButtonStyle()).focusEffectDisabled()
                        }
                }
            }
            if session.internetEnabled && session.internetCodeConflict {
                Text(session.internetStatus).font(.system(size: 14))
                    .foregroundStyle(session.internetCodeConflict ? Color.red : Color.secondary)
                if session.internetCodeConflict {
                    Text("另一台发送设备正在使用这个邀请编号。请停止那台设备的广播，或为本机换码后让接收端输入新码。")
                        .font(.system(size: 14)).foregroundStyle(.red)
                    if codeSuggestion.isLoading {
                        ProgressView("正在查找未占用的新码…")
                    } else if let candidate = codeSuggestion.code {
                        Text("建议新码：\(candidate)").font(.system(size: 20, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("采用建议码并重试") { codeDraft = candidate; commitCode() }
                            Button("换一个建议") { requestSuggestion(force: true) }
                        }
                        Text("服务器检查时未被占用；采用后请让接收端输入新码。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        Text(codeSuggestion.errorText ?? "正在准备建议码").font(.system(size: 14)).foregroundStyle(.secondary)
                        Button("重新获取建议码") { requestSuggestion(force: true) }
                    }
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("邀请编号 · 邀请设备连接").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    if editingCode {
                        HStack {
                            TextField("6–36 位数字", text: $codeDraft).textFieldStyle(.roundedBorder)
                                .font(.system(size: 24, design: .monospaced)).frame(width: 230)
                                .onChange(of: codeDraft) { _, newValue in
                                    codeError = !streamer.canChangeCode(session, to: codeDraft) && codeDraft != session.code
                                }.focused($codeFocused)
                                .background(GeometryReader { proxy in
                                    Color.clear.preference(key: CodeEditorFrameKey.self, value: proxy.frame(in: .named("code-card")))
                                })
                                .onAppear { codeFocused = true }
                                .onSubmit { commitCode() }
                                .onExitCommand { editingCode = false; codeError = false }
                        }
                    } else {
                        Button { codeDraft = session.code; editingCode = true } label: {
                            Text(session.code).font(.system(size: 36, weight: .medium, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.35)
                                .tracking(3).foregroundStyle(.primary)
                        }.buttonStyle(AppGlassButtonStyle()).help("修改邀请编号")
                    }
                    if codeError {
                        Text("邀请编号已占用或格式有误").font(.system(size: 13)).foregroundStyle(.red)
                        if let candidate = localCodeSuggestion {
                            Button("采用本机未使用的新码 \(candidate)") { codeDraft = candidate; commitCode() }
                                .font(.system(size: 13))
                        }
                    }
                }
                Spacer()
                VStack(spacing: 10) {
                    SharingIllustration(compact: true)
                    SenderAudioQuickControls(microphone: $session.sendsMicrophone, microphoneActive: session.microphoneActive)
                }
            }
            .padding(.vertical, 8)
            Text(AdmissionCredentials.validPassword(streamer.connectionPassword) ? "邀请链接不含密码；请另行告知接收者连接密码" : "请先在设置中设置连接密码")
                .font(.caption).foregroundStyle(.secondary)
            BrowserSenderAddresses(server: session.server, code: session.code, internet: session.internetEnabled && session.internetMatchingEnabled)
            Divider()
            HStack(spacing: 12) {
                Button { showSettings.toggle() } label: { Label("投屏设置", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $showSettings) {
                        ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("投屏设置").font(.headline)
                            RoomAudioControls()
                            Toggle("显示光标", isOn: $session.showsCursor)
                            Toggle(session.sendsPageAudio ? "声音已开启" : "声音已关闭", isOn: $session.sendsPageAudio)
                            Toggle(session.sendsMicrophone ? "话筒已开启" : "话筒已关闭", isOn: $session.sendsMicrophone)
                            Divider()
                            Toggle("允许公网直连", isOn: $session.internetEnabled)
                            Toggle("允许公网邀请", isOn: $session.internetMatchingEnabled).disabled(!session.internetEnabled)
                            Divider()
                            Text("\(session.encWidth) × \(session.encHeight) · \(Int(session.currentFPS)) fps")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HStack {
                                Text("码率")
                                Spacer()
                                Text("\(session.bitrate / 1_000_000) Mbps").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(get: { Double(session.bitrate) / 1_000_000 },
                                      set: { session.updateQuality(bitrate: Int($0 * 1_000_000)) }),
                                   in: 8...100, step: 2).accessibilityLabel("投屏码率")
                            Picker("帧率", selection: Binding(get: { session.fps }, set: { session.updateQuality(fps: $0) })) {
                                Text("30 fps").tag(30)
                                Text("60 fps").tag(60)
                            }.pickerStyle(.segmented)
                            Text(session.internetStatus).font(.caption).foregroundStyle(.secondary)
                            ConnectionPrivacyNotice()
                            Divider()
                            LocalRecordingControls(recorder: session.recorder)
                        }.toggleStyle(.switch).padding(20).frame(width: 480)
                        }.frame(maxHeight: 680)
                    }
                Spacer()
                Button { session.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新画面").accessibilityLabel("刷新画面")
                Button(action: onEdit) { Label("换源", systemImage: "rectangle.2.swap") }
                Button(action: onStop) { Label("停止", systemImage: "stop.fill").foregroundStyle(.red.opacity(0.85)) }
            }
        }
        .onReceive(session.server.$pendingConnections) { if !$0.isEmpty { showConnections = true } }
        .onChange(of: codeFocused) { _, focused in if !focused && editingCode { commitCode() } }
        .onChange(of: codeError) { _, invalid in localCodeSuggestion = invalid ? streamer.suggestedLocalCode() : nil }
        .onChange(of: session.internetCodeConflict) { _, conflict in if conflict { requestSuggestion() } }
        .onChange(of: session.code) { _, _ in codeSuggestion.reset() }
        .onAppear { if session.internetCodeConflict { requestSuggestion() } }
        .onDisappear { codeSuggestion.reset() }
        .onPreferenceChange(CodeEditorFrameKey.self) { codeEditorFrame = $0 }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("code-card")).onEnded { event in
            if codeFocused && !codeEditorFrame.contains(event.location) { codeFocused = false }
        })
        .coordinateSpace(name: "code-card")
        .padding(28)
        .appPanelStyle()
        .shadow(color: .black.opacity(0.04), radius: 18, y: 8)
    }

    private func commitCode() {
        guard MatchingCode.isValid(codeDraft) else { codeError = true; editingCode = false; return }
        if streamer.canChangeCode(session, to: codeDraft) {
            session.code = codeDraft
            streamer.lastCode = codeDraft
            codeError = false
            editingCode = false
            streamer.refreshBroadcast()
        } else {
            codeError = true
            editingCode = false
        }
    }

    private func requestSuggestion(force: Bool = false) {
        codeSuggestion.request(for: session.code, excluding: streamer.sessions.map(\.code), force: force)
    }

    private var statusDot: some View {
        Circle().fill(session.phase == .streaming ? (session.clientCount > 0 ? Color.green : Color.orange) : Color.red).frame(width: 7, height: 7)
    }
}

struct AddStreamSheet: View {
    @ObservedObject var streamer: ScreenStreamer
    @Binding var isPresented: Bool

    @State private var selected: Set<String> = []
    @State private var selectedApps: [(String, SCRunningApplication)] = []
    @State private var selectedWindows: [(String, SCWindow)] = []
    @State private var selectedDisplays: [(String, SCDisplay)] = []
    @State private var expandedApps: Set<String> = []
    @State private var showOptions = false
    @State private var bitrate: Int
    @State private var fps: Int
    @State private var showsCursor: Bool = true
    @State private var code: String = ""

    init(streamer: ScreenStreamer, isPresented: Binding<Bool>) {
        self.streamer = streamer
        self._isPresented = isPresented
        self._bitrate = State(initialValue: streamer.defaultBitrate)
        self._fps = State(initialValue: streamer.defaultFPS)
        self._code = State(initialValue: streamer.lastCode)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择共享内容").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("共享整个屏幕，或只分享需要的应用与窗口。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: { streamer.loadShareableContent() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(AppGlassButtonStyle())
                .controlSize(.large)
                .help("刷新应用列表")
                Text("已选 \(selected.count) 项").font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 14).frame(minHeight: 46).background(.primary.opacity(0.04), in: Capsule())
                Button("取消") { isPresented = false }
                    .buttonStyle(AppGlassButtonStyle())
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("整个屏幕").font(.system(size: 20, weight: .bold, design: .rounded)).padding(.bottom, 4)
                    ForEach(streamer.displays, id: \.displayID) { display in
                        let key = "display-\(display.displayID)"
                        HStack(spacing: 8) {
                            Image(systemName: "display").font(.system(size: 32, weight: .medium)).foregroundStyle(.secondary).frame(width: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("显示器").font(.system(size: 20, weight: .semibold))
                                Text("\(Int(display.width)) × \(Int(display.height))").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(selected.contains(key) ? "已选" : "选择") {
                                toggleDisplay(key: key, name: "显示器 \(Int(display.width))×\(Int(display.height))", display: display)
                            }
                            .buttonStyle(AppGlassButtonStyle(selected: selected.contains(key))).controlSize(.large)
                        }
                        .padding(14)
                        .background(selected.contains(key) ? Color.green.opacity(0.035) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                    }

                    Text("应用与窗口").font(.system(size: 20, weight: .bold, design: .rounded)).padding(.top, 16).padding(.bottom, 4)

                    ForEach(streamer.appGroups.filter { !$0.isUnnamed }) { group in
                        AppGroupPicker(group: group, selected: $selected, selectedApps: $selectedApps, selectedWindows: $selectedWindows, streamer: streamer)
                    }
                    if streamer.appGroups.contains(where: \.isUnnamed) {
                        Text("其他项目 · 系统未提供应用名称").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                        ForEach(streamer.appGroups.filter(\.isUnnamed)) { group in
                            AppGroupPicker(group: group, selected: $selected, selectedApps: $selectedApps, selectedWindows: $selectedWindows, streamer: streamer)
                        }
                    }
                }
                .padding(.vertical, 8).padding(.trailing, 8)
            }

            if !selected.isEmpty {
                Divider()

                let allNames = selectedApps.map(\.0) + selectedWindows.map(\.0) + selectedDisplays.map(\.0)
                Text(allNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(1)

                DisclosureGroup("画质与连接", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Menu("画质预设") {
                        Button("均衡 · 12 Mbps / 30 fps") { bitrate = 12_000_000; fps = 30 }
                        Button("文字清晰 · 24 Mbps / 30 fps") { bitrate = 24_000_000; fps = 30 }
                        Button("动态流畅 · 20 Mbps / 60 fps") { bitrate = 20_000_000; fps = 60 }
                    }.fixedSize()
                    HStack(spacing: 4) {
                        Text("码率").font(.system(size: 15))
                        Slider(value: Binding(get: { Double(bitrate)/1_000_000 }, set: { bitrate = Int($0 * 1_000_000) }), in: 8...100, step: 2).frame(width: 100)
                        Text("\(Int(Double(bitrate)/1_000_000))M").font(.system(size: 15))
                    }
                    Picker("FPS", selection: $fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }.pickerStyle(.segmented).frame(width: 120)
                }
                HStack(spacing: 24) {
                    Toggle("光标", isOn: $showsCursor).toggleStyle(.switch)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("邀请编号").font(.system(size: 15))
                        TextField("6–36 位数字", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                    }
                }
                }.padding(.top, 8)
                }.padding(.vertical, 4)

                HStack {
                    Spacer()
                    Button("开始投屏") {
                        let useCode = code.isEmpty ? MatchingCode.generate() : code
                        streamer.lastCode = useCode
                        streamer.defaultBitrate = bitrate
                        streamer.defaultFPS = fps
                        if !selectedApps.isEmpty {
                            let apps = selectedApps.map(\.1)
                            let name = selectedApps.map(\.0).joined(separator: " + ")
                            if let display = streamer.bestDisplay(for: apps) {
                                for app in apps { streamer.recordUsage(bundleIdentifier: app.bundleIdentifier) }
                                streamer.addSession(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []), name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor, code: useCode)
                            }
                        }
                        for (name, window) in selectedWindows {
                            let origin = window.frame.origin
                            if let app = window.owningApplication { streamer.recordUsage(bundleIdentifier: app.bundleIdentifier) }
                            streamer.addSession(filter: SCContentFilter(desktopIndependentWindow: window), name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor, screenOrigin: origin, code: useCode)
                        }
                        for (name, display) in selectedDisplays {
                            streamer.addSession(filter: SCContentFilter(display: display, excludingWindows: []), name: name, bitrate: bitrate, fps: fps, showsCursor: showsCursor, code: useCode)
                        }
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                        isPresented = false
                    }
                    .buttonStyle(AppGlassButtonStyle(prominent: true))
                    .disabled(!code.isEmpty && !MatchingCode.isValid(code))
                    Button("清除选择") {
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                    }
                    .buttonStyle(AppGlassButtonStyle())
                }
            }
        }
        .padding(28)
        .frame(width: 800, height: 660)
        .background(AppPaperBackground())
        .buttonStyle(AppGlassButtonStyle())
        .controlSize(.large)
    }

    private func toggleApp(key: String, name: String, app: SCRunningApplication) {
        if selected.contains(key) {
            selected.remove(key)
            selectedApps.removeAll { $0.1 === app }
        } else {
            selected.insert(key)
            selectedApps.append((name, app))
        }
    }

    private func toggleWindow(key: String, name: String, window: SCWindow) {
        if selected.contains(key) {
            selected.remove(key)
            selectedWindows.removeAll { $0.1 === window }
        } else {
            selected.insert(key)
            selectedWindows.append((name, window))
        }
    }

    private func toggleDisplay(key: String, name: String, display: SCDisplay) {
        if selected.contains(key) {
            selected.remove(key)
            selectedDisplays.removeAll { $0.1 === display }
        } else {
            selected.insert(key)
            selectedDisplays.append((name, display))
        }
    }
}

private struct EditStreamSheet: View {
    let session: StreamSession
    @ObservedObject var streamer: ScreenStreamer
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var selectedApps: [(String, SCRunningApplication)] = []
    @State private var selectedWindows: [(String, SCWindow)] = []
    @State private var selectedDisplays: [(String, SCDisplay)] = []

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("更改投屏内容").font(.title2.bold())
                Spacer()
                Text("当前：\(session.contentName)").font(.system(size: 15)).foregroundStyle(.secondary)
                Text("已选 \(selected.count) 个").font(.system(size: 16)).foregroundStyle(.blue)
                Button("取消") { dismiss() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示器").font(.system(size: 15)).foregroundStyle(.secondary)
                    ForEach(streamer.displays, id: \.displayID) { display in
                        let key = "display-\(display.displayID)"
                        HStack(spacing: 8) {
                            Image(systemName: "display").frame(width: 20)
                            Text("显示器 \(Int(display.width))×\(Int(display.height))").font(.system(size: 16))
                            Spacer()
                            Button(selected.contains(key) ? "已选" : "选择") {
                                toggleDisplay(key: key, name: "显示器 \(Int(display.width))×\(Int(display.height))", display: display)
                            }
                            .buttonStyle(AppGlassButtonStyle(selected: selected.contains(key))).controlSize(.large)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected.contains(key) ? Color.green.opacity(0.035) : Color.clear))
                    }

                    Text("应用与窗口").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 8)
                    ForEach(streamer.appGroups) { group in
                        AppGroupPicker(group: group, selected: $selected, selectedApps: $selectedApps, selectedWindows: $selectedWindows, streamer: streamer)
                    }
                }
            }

            if !selected.isEmpty {
                Divider()

                let allNames = selectedApps.map(\.0) + selectedWindows.map(\.0) + selectedDisplays.map(\.0)
                Text("已选：\(allNames.joined(separator: "、"))").font(.system(size: 16)).lineLimit(2)

                HStack {
                    Spacer()
                    Button("确认切换 (\(selected.count)个)") {
                        applyChanges()
                    }
                    .buttonStyle(AppGlassButtonStyle(prominent: true))
                    Button("清除选择") {
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                    }
                    .buttonStyle(AppGlassButtonStyle())
                }
            }
        }
        .padding(28)
        .frame(width: 860, height: 720)
        .background(AppPaperBackground())
    }

    private func applyChanges() {
        if selectedWindows.isEmpty, selectedDisplays.isEmpty, !selectedApps.isEmpty {
            let apps = selectedApps.map(\.1)
            if let display = streamer.bestDisplay(for: apps) {
                let name = selectedApps.map(\.0).joined(separator: " + ")
                session.changeFilter(SCContentFilter(display: display, including: apps, exceptingWindows: []), name: name)
                dismiss()
                return
            }
        }

        if selectedApps.isEmpty, selectedDisplays.isEmpty, selectedWindows.count == 1 {
            let item = selectedWindows[0]
            session.changeFilter(SCContentFilter(desktopIndependentWindow: item.1), name: item.0)
            dismiss()
            return
        }

        if selectedApps.isEmpty, selectedWindows.isEmpty, selectedDisplays.count == 1 {
            let item = selectedDisplays[0]
            session.changeFilter(SCContentFilter(display: item.1, excludingWindows: []), name: item.0)
            dismiss()
            return
        }

        streamer.replaceSession(session,
                                apps: selectedApps.map(\.1),
                                windows: selectedWindows,
                                displays: selectedDisplays)
        dismiss()
    }

    private func toggleDisplay(key: String, name: String, display: SCDisplay) {
        if selected.contains(key) {
            selected.remove(key)
            selectedDisplays.removeAll { $0.1 === display }
        } else {
            selected.insert(key)
            selectedDisplays.append((name, display))
        }
    }
}

private struct AppGroupPicker: View {
    let group: ScreenStreamer.AppGroup
    @Binding var selected: Set<String>
    @Binding var selectedApps: [(String, SCRunningApplication)]
    @Binding var selectedWindows: [(String, SCWindow)]
    @ObservedObject var streamer: ScreenStreamer
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 12)
                if let icon = group.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 36, weight: .medium)).foregroundStyle(.secondary).frame(width: 42, height: 42)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName).font(.system(size: 20, weight: .semibold)).lineLimit(1).help(group.displayName)
                    Text("\(group.windows.count) 个窗口").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if let display = streamer.bestDisplay(for: [group.application]) {
                    let key = "app-\(group.application.bundleIdentifier)-\(display.displayID)"
                    Button(selected.contains(key) ? "已选择" : "选择应用") {
                        if selected.contains(key) { selected.remove(key); selectedApps.removeAll { $0.1 === group.application } }
                        else { selected.insert(key); selectedApps.append((group.displayName, group.application)) }
                    }
                    .buttonStyle(AppGlassButtonStyle(selected: selected.contains(key))).controlSize(.large)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }

            if isExpanded {
                ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                    let trimmedTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = trimmedTitle.isEmpty ? "未命名窗口 · \(window.windowID)" : trimmedTitle
                    let key = "window-\(window.windowID)"
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                        Text(title).font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Button(selected.contains(key) ? "已选" : "选择") {
                            if selected.contains(key) { selected.remove(key); selectedWindows.removeAll { $0.1 === window } }
                            else { selected.insert(key); selectedWindows.append((title, window)) }
                        }
                        .buttonStyle(AppGlassButtonStyle(selected: selected.contains(key))).controlSize(.large)
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct EditAppGroupPicker: View {
    let group: ScreenStreamer.AppGroup
    @Binding var selectedFilter: SCContentFilter?
    @Binding var selectedName: String
    @ObservedObject var streamer: ScreenStreamer
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                if let icon = group.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                }
                Text(group.displayName).font(.system(size: 16)).bold()
                Spacer()
                if let display = streamer.bestDisplay(for: [group.application]) {
                    let filter = SCContentFilter(display: display, including: [group.application], exceptingWindows: [])
                    Button("投屏整个应用") {
                        selectedFilter = filter; selectedName = group.displayName
                    }
                    .buttonStyle(AppGlassButtonStyle()).controlSize(.large)
                    .tint(selectedFilter === filter ? .blue : nil)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }

            if isExpanded {
                ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                    let trimmedTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = trimmedTitle.isEmpty ? "未命名窗口 · \(window.windowID)" : trimmedTitle
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    HStack {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                        Text("  \(title)").font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Button("选择") {
                            selectedFilter = filter; selectedName = title
                        }
                        .buttonStyle(AppGlassButtonStyle()).controlSize(.large)
                        .tint(selectedFilter === filter ? .blue : nil)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
    }
}

private struct pickerRow: View {
    var name: String
    var filter: SCContentFilter
    @Binding var selectedFilter: SCContentFilter?
    @Binding var selectedName: String

    var body: some View {
        Button("选择") {
            selectedFilter = filter; selectedName = name
        }
        .buttonStyle(AppGlassButtonStyle()).controlSize(.large)
        .tint(selectedFilter === filter ? .blue : nil)
    }
}


private struct SessionDiagnosticsView: View {
    @ObservedObject var session: StreamSession
    @ObservedObject var server: CastingServer
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ConnectionLegalNotice()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接设备").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(session.contentName).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text("\(session.clientCount) 台").font(.system(size: 18, weight: .semibold)).monospacedDigit()
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    PendingConnectionsView(requests: server.pendingConnections) { server.respondToRequest($0, accept: $1) }
                    if server.diagnostics.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "display.2").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                            Text(session.clientCount == 0 ? "等待设备连接" : "正在读取连接信息…").font(.system(size: 18, weight: .semibold))
                            Text("接收端连接这一路投屏后，会显示在这里。")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    ForEach(server.diagnostics) { peer in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                Image(systemName: peer.device.lowercased().contains("browser") ? "globe" : "display")
                                    .font(.system(size: 26, weight: .medium)).foregroundStyle(.blue)
                                    .frame(width: 48, height: 48)
                                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(peer.device).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                                    Text("\(peer.route) · \(peer.id.prefix(8))").font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("断开", role: .destructive) { server.disconnectPeer(peer.id) }
                            }
                            HStack {
                                Text("网络往返 RTT").foregroundStyle(.secondary)
                                Spacer()
                                Text(ReceiveTiming.text(peer.rttMS)).monospacedDigit()
                            }.font(.system(size: 14))
                            DisclosureGroup("网络详情") {
                                Text("本机：\(peer.localEndpoint)\n对方：\(peer.remoteEndpoint)")
                                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.system(size: 14)).foregroundStyle(.secondary)
                        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                    }
                    DisclosureGroup("本路投屏诊断") {
                        Text("局域网信令端口 \(server.listeningPort.map(String.init) ?? "未监听")\n公网 IP 信令端口 \(server.internetListeningPort.map(String.init) ?? "未监听")")
                            .font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
                    }.font(.system(size: 14)).foregroundStyle(.secondary)
                }.padding(.trailing, 6)
            }
            Text("RTT 是网络往返时间，不是端到端画面延迟。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 620, height: 500)
    }
}
