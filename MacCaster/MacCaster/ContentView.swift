import SwiftUI
import AppKit
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var showAddSheet = false
    @State private var showDiagnostics = false
    @AppStorage("appMode") private var appMode = "cast"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = streamer.contentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            StreamListView(streamer: streamer, onAdd: { showAddSheet = true })
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500)
        .background(CastStyle.canvas.onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) })
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("工作模式", selection: $appMode) {
                    Text("投屏").tag("cast")
                    Text("接收").tag("receive")
                }.pickerStyle(.segmented).frame(width: 160)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Label("添加投屏", systemImage: "plus") }
                    .help("选择要共享的屏幕或窗口")
            }
            ToolbarItem(placement: .automatic) {
                Button { showDiagnostics.toggle() } label: { Label("连接详情", systemImage: "info.circle") }
                    .popover(isPresented: $showDiagnostics) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("连接详情").font(.headline)
                                ForEach(streamer.sessions) { session in SessionDiagnosticsView(session: session, server: session.server) }
                            }.padding(20)
                        }.frame(width: 560, height: 380)
                    }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddStreamSheet(streamer: streamer, isPresented: $showAddSheet)
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

private struct StreamListView: View {
    @ObservedObject var streamer: ScreenStreamer
    let onAdd: () -> Void
    @State private var editSession: StreamSession? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if streamer.sessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 42, weight: .light)).foregroundStyle(CastStyle.accent)
                        Text("准备好开始投屏").font(.system(size: 25, weight: .semibold))
                        Text("选择屏幕、应用或窗口，连接你的另一块屏幕。")
                            .font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 42)
                    .background(CastStyle.panel, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.06)))
                }
                ForEach(streamer.sessions) { session in
                    SessionRow(session: session, streamer: streamer, onStop: { streamer.removeSession(session) }, onEdit: { editSession = session })
                }
                if streamer.sessions.isEmpty { Button(action: onAdd) {
                    Label("添加投屏", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent) }
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
            if let port = server.browserListeningPort {
                if let ip = CastingServer.localIPs.first(where: BrowserReceiverServer.isLocalAddress) {
                    address("局域网", InternetSettings.localBrowserAddress(ip: ip, port: port, code: code))
                }
            } else { Text("局域网准备中…").font(.caption).foregroundStyle(.secondary) }
            if internet { address("公网", InternetSettings.browserAddress(code: code)) }
        }
    }
    private func address(_ title: String, _ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            copied = value
        } label: {
            Label(copied == value ? "已复制\(title)地址" : "复制\(title)地址", systemImage: copied == value ? "checkmark" : "link")
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.contentName).font(.headline).lineLimit(2)
                    if case .failed(let message) = session.phase {
                        Text(message).foregroundStyle(.red).lineLimit(2)
                    } else if session.phase == .starting {
                        Text("正在连接画面…").foregroundStyle(.orange)
                    } else {
                        Text("正在共享").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    statusDot
                    Text(session.clientCount == 0 ? "等待接收" : "\(session.clientCount) 台已连接").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if session.internetEnabled && session.internetCodeConflict {
                Text(session.internetStatus).font(.system(size: 14))
                    .foregroundStyle(session.internetCodeConflict ? Color.red : Color.secondary)
                if session.internetCodeConflict {
                    Text("另一台发送设备正在使用这个匹配码。请停止那台设备的广播，或为本机换码后让接收端输入新码。")
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
                    Text("匹配码").font(.system(size: 13)).foregroundStyle(.secondary)
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
                            Text(session.code).font(.system(size: 30, weight: .medium, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.35)
                                .tracking(4).foregroundStyle(CastStyle.accent)
                        }.buttonStyle(.plain).help("修改匹配码")
                    }
                    if codeError {
                        Text("匹配码已占用或格式有误").font(.system(size: 13)).foregroundStyle(.red)
                        if let candidate = localCodeSuggestion {
                            Button("采用本机未使用的新码 \(candidate)") { codeDraft = candidate; commitCode() }
                                .font(.system(size: 13))
                        }
                    }
                }
                Spacer()
            }
            BrowserSenderAddresses(server: session.server, code: session.code, internet: session.internetEnabled && session.internetMatchingEnabled)
            Divider()
            HStack(spacing: 12) {
                Button { showSettings.toggle() } label: { Label("投屏设置", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $showSettings) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("投屏设置").font(.headline)
                            Toggle("显示光标", isOn: $session.showsCursor)
                            Toggle("页面声音", isOn: $session.sendsPageAudio)
                            Toggle("话筒声音", isOn: $session.sendsMicrophone)
                            Divider()
                            Toggle("允许公网直连", isOn: $session.internetEnabled)
                            Toggle("允许公网匹配码", isOn: $session.internetMatchingEnabled).disabled(!session.internetEnabled)
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
                        }.toggleStyle(.switch).padding(20).frame(width: 480)
                    }
                Spacer()
                Button { session.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                Button(action: onEdit) { Label("换源", systemImage: "rectangle.2.swap") }
                Button(action: onStop) { Label("停止", systemImage: "stop.fill").foregroundStyle(.red.opacity(0.85)) }
            }
        }
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
        .padding(24)
        .background(CastStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
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

private struct AddStreamSheet: View {
    @ObservedObject var streamer: ScreenStreamer
    @Binding var isPresented: Bool

    @State private var selected: Set<String> = []
    @State private var selectedApps: [(String, SCRunningApplication)] = []
    @State private var selectedWindows: [(String, SCWindow)] = []
    @State private var selectedDisplays: [(String, SCDisplay)] = []
    @State private var expandedApps: Set<String> = []
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
                Text("添加投屏流").font(.title2.bold())
                Spacer()
                Button(action: { streamer.loadShareableContent() }) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("刷新应用列表")
                Text("已选 \(selected.count) 个").font(.system(size: 16)).foregroundStyle(.blue)
                Button("取消") { isPresented = false }
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
                            .buttonStyle(.bordered).controlSize(.regular)
                            .tint(selected.contains(key) ? .blue : nil)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected.contains(key) ? Color.blue.opacity(0.12) : Color.clear))
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
                        Text("匹配码").font(.system(size: 15))
                        TextField("6–36 位数字", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                    }
                }

                HStack {
                    Spacer()
                    Button("开始投屏 (\(selected.count)个)") {
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
                    .buttonStyle(.borderedProminent)
                    .disabled(!code.isEmpty && !MatchingCode.isValid(code))
                    Button("清除选择") {
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(width: 860, height: 720)
        .background(CastStyle.canvas)
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
                            .buttonStyle(.bordered).controlSize(.regular)
                            .tint(selected.contains(key) ? .blue : nil)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected.contains(key) ? Color.blue.opacity(0.12) : Color.clear))
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
                    .buttonStyle(.borderedProminent)
                    Button("清除选择") {
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(width: 860, height: 720)
        .background(CastStyle.canvas)
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
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                if let icon = group.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(group.application.applicationName).font(.system(size: 16)).bold()
                Spacer()
                if let display = streamer.bestDisplay(for: [group.application]) {
                    let key = "app-\(group.application.bundleIdentifier)-\(display.displayID)"
                    Button(selected.contains(key) ? "已选" : "投屏整个应用") {
                        if selected.contains(key) { selected.remove(key); selectedApps.removeAll { $0.1 === group.application } }
                        else { selected.insert(key); selectedApps.append((group.application.applicationName, group.application)) }
                    }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .tint(selected.contains(key) ? .blue : nil)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }

            if isExpanded {
                ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                    let title = (window.title ?? "").isEmpty ? "未命名窗口" : window.title ?? ""
                    let key = "window-\(window.windowID)"
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                        Text(title).font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Button(selected.contains(key) ? "已选" : "选择") {
                            if selected.contains(key) { selected.remove(key); selectedWindows.removeAll { $0.1 === window } }
                            else { selected.insert(key); selectedWindows.append((title, window)) }
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .tint(selected.contains(key) ? .blue : nil)
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
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
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(group.application.applicationName).font(.system(size: 16)).bold()
                Spacer()
                if let display = streamer.bestDisplay(for: [group.application]) {
                    let filter = SCContentFilter(display: display, including: [group.application], exceptingWindows: [])
                    Button("投屏整个应用") {
                        selectedFilter = filter; selectedName = group.application.applicationName
                    }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .tint(selectedFilter === filter ? .blue : nil)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.toggle() } }

            if isExpanded {
                ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                    let title = (window.title ?? "").isEmpty ? "未命名" : window.title ?? ""
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    HStack {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                        Text("  \(title)").font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Button("选择") {
                            selectedFilter = filter; selectedName = title
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
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
        .buttonStyle(.bordered).controlSize(.regular)
        .tint(selectedFilter === filter ? .blue : nil)
    }
}


private struct SessionDiagnosticsView: View {
    @ObservedObject var session: StreamSession
    @ObservedObject var server: CastingServer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.contentName).font(.headline)
            Text("局域网信令端口 \(server.listeningPort.map(String.init) ?? "未监听") · 广域网 IP 信令端口 \(server.internetListeningPort.map(String.init) ?? "未监听")")
                .font(.system(size: 14, design: .monospaced))
            PeerDiagnosticsView(peers: server.diagnostics, disconnect: server.disconnectPeer)
        }
    }
}
