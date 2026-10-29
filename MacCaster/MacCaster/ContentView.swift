import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var showAddSheet = false
    @AppStorage("appMode") private var appMode = "cast"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let error = streamer.contentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            StreamListView(streamer: streamer, onAdd: { showAddSheet = true })
            defaultSettingsPanel
        }
        .padding(28)
        .frame(minWidth: 860, minHeight: 640)
        .background(CastStyle.canvas)
        .sheet(isPresented: $showAddSheet) {
            AddStreamSheet(streamer: streamer, isPresented: $showAddSheet)
        }
        .task { streamer.loadShareableContent() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "display.2")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(CastStyle.accent)
                .frame(width: 60, height: 60)
                .background(CastStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 6) {
                Text("投屏工作台").font(.system(size: 30, weight: .semibold))
                Text("李知本 · 让画面自由连接").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { streamer.loadShareableContent() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
            }.help("刷新应用列表")
            Button { appMode = "receive" } label: { Label("接收画面", systemImage: "arrow.down.left") }
        }
    }

    private var defaultSettingsPanel: some View {
        HStack {
            Label(CastingServer.localIPs.first ?? "等待网络", systemImage: "network")
                .font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
                .help(CastingServer.localIPs.joined(separator: "、"))
            Spacer()
            Text("画质可在每个投屏卡片内单独调整").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

}

// Shared native styling; no changes to capture or transport behavior.
enum CastStyle {
    static let canvas = Color(red: 0.035, green: 0.05, blue: 0.075)
    static let panel = Color(red: 0.07, green: 0.09, blue: 0.125)
    static let accent = Color(red: 0.34, green: 0.70, blue: 1)
}

struct CastButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 18).frame(minHeight: 46)
            .foregroundStyle(primary ? Color.black : Color.white.opacity(0.9))
            .background(primary ? CastStyle.accent : Color.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(primary ? 0 : 0.08)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}

private struct StreamListView: View {
    @ObservedObject var streamer: ScreenStreamer
    let onAdd: () -> Void
    @State private var editSession: StreamSession? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("正在投屏").font(.system(size: 18, weight: .semibold))
                    Text("\(streamer.sessions.count)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(CastStyle.accent).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(CastStyle.accent.opacity(0.1), in: Capsule())
                    Spacer()
                }
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
                Button(action: onAdd) {
                    Label("添加投屏", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(CastButtonStyle(primary: true))
            }
        }
        .sheet(item: $editSession) { session in
            EditStreamSheet(session: session, streamer: streamer)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.contentName).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                    if case .failed(let message) = session.phase {
                        Text(message).foregroundStyle(.red).lineLimit(2)
                    } else if session.phase == .starting {
                        Text("正在连接画面…").foregroundStyle(.orange)
                    } else {
                        HStack(spacing: 14) {
                            Text("\(session.encWidth) × \(session.encHeight)")
                            Text("\(Int(session.currentFPS)) fps")
                            Text("\(session.bitrate / 1_000_000) Mbps")
                        }.font(.system(size: 15, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    statusDot
                    Text("\(session.clientCount) 台已连接").font(.system(size: 15))
                }.padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.white.opacity(0.04), in: Capsule())
            }
            Toggle("允许广域网直连", isOn: $session.internetEnabled).toggleStyle(.switch)
            if session.internetEnabled {
                Toggle("允许广域网匹配码", isOn: $session.internetMatchingEnabled).toggleStyle(.switch)
                Text(session.internetStatus).font(.system(size: 14)).foregroundStyle(.secondary)
                Text("公网 IP 使用端口 \(session.port + 1000)；需可达公网地址。匹配码通过轻量服务配对，视频仅在设备间直传。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
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
                                }.onSubmit { commitCode() }
                            Button("保存") { commitCode() }
                            Button("取消") { editingCode = false; codeError = false }
                        }
                    } else {
                        Button { codeDraft = session.code; editingCode = true } label: {
                            Text(session.code).font(.system(size: 30, weight: .medium, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.35)
                                .tracking(4).foregroundStyle(CastStyle.accent)
                        }.buttonStyle(.plain).help("修改匹配码")
                    }
                    if codeError { Text("匹配码已占用或格式有误").font(.system(size: 13)).foregroundStyle(.red) }
                }
                Spacer()
                Toggle("显示光标", isOn: $session.showsCursor).toggleStyle(.switch).fixedSize()
            }
            HStack(spacing: 18) {
                Text("码率").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(session.bitrate) / 1_000_000 },
                                      set: { session.updateQuality(bitrate: Int($0 * 1_000_000)) }),
                       in: 8...100, step: 2).frame(maxWidth: 240)
                Text("\(session.bitrate / 1_000_000) Mbps")
                    .font(.system(size: 17, design: .monospaced)).frame(width: 110, alignment: .leading)
                Spacer(minLength: 0)
                Picker("帧率", selection: Binding(get: { session.fps }, set: { session.updateQuality(fps: $0) })) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
            }
            HStack(spacing: 12) {
                Text("端口 \(session.port)").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { session.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                Button(action: onEdit) { Label("换源", systemImage: "rectangle.2.swap") }
                Button(action: onStop) { Label("停止", systemImage: "stop.fill").foregroundStyle(.red.opacity(0.85)) }
            }
        }
        .padding(24)
        .background(CastStyle.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.07)))
    }

    private func commitCode() {
        guard MatchingCode.isValid(codeDraft) else { return }
        if streamer.canChangeCode(session, to: codeDraft) {
            session.code = codeDraft
            codeError = false
            editingCode = false
            streamer.refreshBroadcast()
        } else {
            codeError = true
        }
    }

    private var statusDot: some View {
        Circle().fill(session.phase == .streaming ? Color.green : Color.red).frame(width: 10, height: 10)
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
                .buttonStyle(CastButtonStyle())
                .controlSize(.large)
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
                            .buttonStyle(CastButtonStyle()).controlSize(.large)
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
                    .buttonStyle(CastButtonStyle(primary: true))
                    .disabled(!code.isEmpty && !MatchingCode.isValid(code))
                    Button("清除选择") {
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                    }
                    .buttonStyle(CastButtonStyle())
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
                            .buttonStyle(CastButtonStyle()).controlSize(.large)
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
                    .buttonStyle(CastButtonStyle(primary: true))
                    Button("清除选择") {
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                    }
                    .buttonStyle(CastButtonStyle())
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
                if group.windows.count > 1, let display = streamer.bestDisplay(for: [group.application]) {
                    let key = "app-\(group.application.bundleIdentifier)-\(display.displayID)"
                    Button(selected.contains(key) ? "已选" : "投屏整个应用") {
                        if selected.contains(key) { selected.remove(key); selectedApps.removeAll { $0.1 === group.application } }
                        else { selected.insert(key); selectedApps.append((group.application.applicationName, group.application)) }
                    }
                    .buttonStyle(CastButtonStyle()).controlSize(.large)
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
                        .buttonStyle(CastButtonStyle()).controlSize(.large)
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
                    .buttonStyle(CastButtonStyle()).controlSize(.large)
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
                        .buttonStyle(CastButtonStyle()).controlSize(.large)
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
        .buttonStyle(CastButtonStyle()).controlSize(.large)
        .tint(selectedFilter === filter ? .blue : nil)
    }
}
