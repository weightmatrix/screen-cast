import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.vertical, 4)

            StreamListView(streamer: streamer, onAdd: { showAddSheet = true })

            Divider().padding(.vertical, 4)

            defaultSettingsPanel
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $showAddSheet) {
            AddStreamSheet(streamer: streamer, isPresented: $showAddSheet)
        }
        .task { streamer.loadShareableContent() }
    }

    private var header: some View {
        VStack(spacing: 2) {
            HStack {
                Image(systemName: "display.2").font(.title)
                Text("投屏控制台").font(.title2.bold())
                Spacer()
                Text("\(streamer.sessions.count) 个流运行中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("本机 IP：\(CastingServer.localIPs.joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.blue)
                Spacer()
            }
        }
    }
    private var defaultSettingsPanel: some View {
        HStack(spacing: 16) {
            Text("新建流默认设置").font(.caption).foregroundStyle(.secondary)
            Toggle("H264", isOn: $streamer.defaultUseH264)
                .toggleStyle(.switch).controlSize(.small)
            HStack(spacing: 4) {
                Text("码率").font(.caption)
                Slider(value: Binding(get: { Double(streamer.defaultBitrate)/1_000_000 }, set: { streamer.defaultBitrate = Int($0 * 1_000_000) }), in: 8...100, step: 2)
                    .frame(width: 100)
                Text("\(Int(Double(streamer.defaultBitrate)/1_000_000))M").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("FPS").font(.caption)
                Picker("", selection: $streamer.defaultFPS) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }.pickerStyle(.segmented).frame(width: 80)
            }
            Spacer()
            Text("端口范围 \(streamer.sessions.first?.port ?? 8318)–\(streamer.sessions.isEmpty ? 8318 : streamer.sessions.first!.port + UInt16(streamer.sessions.count - 1))")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct StreamListView: View {
    @ObservedObject var streamer: ScreenStreamer
    let onAdd: () -> Void
    @State private var editSession: StreamSession? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(streamer.sessions) { session in
                    SessionRow(session: session, streamer: streamer, onStop: { streamer.removeSession(session) }, onEdit: { editSession = session })
                }
                Button(action: onAdd) {
                    Label("添加投屏流", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 4)
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
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(session.contentName).font(.callout.bold()).lineLimit(1)
                HStack(spacing: 8) {
                    Label("\(session.port)", systemImage: "antenna.radiowaves.left.and.right").font(.caption2)
                    Label(session.useH264 ? "H264" : "JPEG", systemImage: session.useH264 ? "play.rectangle" : "photo").font(.caption2)
                    Label("\(Int(Double(session.bitrate)/1_000_000))M", systemImage: "speedometer").font(.caption2)
                    if session.useH264 {
                        Label("\(session.encWidth)×\(session.encHeight)", systemImage: "rectangle.on.rectangle").font(.caption2)
                    }
                }
                HStack(spacing: 12) {
                    Label("\(Int(session.currentFPS)) fps", systemImage: "gauge.with.dots.needle.33percent").font(.caption2)
                    Label("\(session.clientCount) 设备", systemImage: "ipad").font(.caption2)
                    Toggle("光标", isOn: $session.showsCursor).toggleStyle(.switch).controlSize(.mini)

                    if editingCode {
                        TextField("", text: $codeDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .onChange(of: codeDraft) { _, newValue in
                                let filtered = newValue.filter { $0.isNumber }.prefix(4)
                                if String(filtered) != newValue { codeDraft = String(filtered) }
                                codeError = !streamer.canChangeCode(session, to: codeDraft) && codeDraft != session.code
                            }
                            .onSubmit { commitCode() }
                        Button("OK") { commitCode() }
                            .buttonStyle(.bordered).controlSize(.mini)
                    } else {
                        Button(action: {
                            codeDraft = session.code
                            editingCode = true
                        }) {
                            Label("\(session.code)", systemImage: "number.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(codeError ? .red : .blue)
                        }
                        .buttonStyle(.plain)
                        .help("点击修改匹配码")
                    }
                }
            }
            Spacer()
            Button(action: { session.toggleAnnotation() }) {
                Image(systemName: session.annotationEngine.isActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    .font(.title2).foregroundStyle(session.annotationEngine.isActive ? .orange : .secondary)
            }
            .buttonStyle(.plain).help("批注")
            Button(action: { session.refresh() }) {
                Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(.blue)
            }
            .buttonStyle(.plain).help("刷新")
            Button(action: onEdit) {
                Image(systemName: "pencil.circle").font(.title2).foregroundStyle(.orange)
            }
            .buttonStyle(.plain).help("编辑")
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
            }
            .buttonStyle(.plain).help("停止")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private func commitCode() {
        guard codeDraft.count == 4 else { return }
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
    @State private var useH264: Bool
    @State private var bitrate: Int
    @State private var fps: Int
    @State private var showsCursor: Bool = true
    @State private var code: String = ""

    init(streamer: ScreenStreamer, isPresented: Binding<Bool>) {
        self.streamer = streamer
        self._isPresented = isPresented
        self._useH264 = State(initialValue: streamer.defaultUseH264)
        self._bitrate = State(initialValue: streamer.defaultBitrate)
        self._fps = State(initialValue: streamer.defaultFPS)
        self._code = State(initialValue: streamer.lastCode)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("添加投屏流").font(.title2.bold())
                Spacer()
                Text("已选 \(selected.count) 个").font(.callout).foregroundStyle(.blue)
                Button("取消") { isPresented = false }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示器").font(.caption).foregroundStyle(.secondary)
                    ForEach(streamer.displays, id: \.displayID) { display in
                        let key = "display-\(display.displayID)"
                        HStack(spacing: 8) {
                            Image(systemName: "display").frame(width: 20)
                            Text("显示器 \(Int(display.width))×\(Int(display.height))").font(.callout)
                            Spacer()
                            Button(selected.contains(key) ? "已选" : "选择") {
                                toggleDisplay(key: key, name: "显示器 \(Int(display.width))×\(Int(display.height))", display: display)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(selected.contains(key) ? .blue : nil)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected.contains(key) ? Color.blue.opacity(0.12) : Color.clear))
                    }

                    Text("应用与窗口").font(.caption).foregroundStyle(.secondary).padding(.top, 8)

                    ForEach(streamer.appGroups) { group in
                        AppGroupPicker(group: group, selected: $selected, selectedApps: $selectedApps, selectedWindows: $selectedWindows, streamer: streamer)
                    }
                }
            }

            if !selected.isEmpty {
                Divider()

                let allNames = selectedApps.map(\.0) + selectedWindows.map(\.0) + selectedDisplays.map(\.0)
                Text("已选：\(allNames.joined(separator: "、"))").font(.callout).lineLimit(2)

                HStack(spacing: 16) {
                    Toggle("H264", isOn: $useH264).toggleStyle(.switch)
                    HStack(spacing: 4) {
                        Text("码率").font(.caption)
                        Slider(value: Binding(get: { Double(bitrate)/1_000_000 }, set: { bitrate = Int($0 * 1_000_000) }), in: 8...100, step: 2).frame(width: 100)
                        Text("\(Int(Double(bitrate)/1_000_000))M").font(.caption)
                    }
                    Picker("FPS", selection: $fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }.pickerStyle(.segmented).frame(width: 80)
                    Toggle("光标", isOn: $showsCursor).toggleStyle(.switch)
                    HStack(spacing: 4) {
                        Text("匹配码").font(.caption)
                        TextField("1234", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .onChange(of: code) { _, newValue in
                                let filtered = newValue.filter { $0.isNumber }.prefix(4)
                                if String(filtered) != newValue { code = String(filtered) }
                            }
                    }
                }

                HStack {
                    Spacer()
                    Button("开始投屏 (\(selected.count)个)") {
                        let useCode = code.isEmpty ? "1234" : code
                        streamer.lastCode = useCode
                        if !selectedApps.isEmpty, let display = streamer.displays.first {
                            let apps = selectedApps.map(\.1)
                            let name = selectedApps.map(\.0).joined(separator: " + ")
                            for app in apps { streamer.recordUsage(bundleIdentifier: app.bundleIdentifier) }
                            streamer.addSession(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []), name: name, useH264: useH264, bitrate: bitrate, fps: fps, showsCursor: showsCursor, code: useCode)
                        }
                        for (name, window) in selectedWindows {
                            let origin = window.frame.origin
                            if let app = window.owningApplication { streamer.recordUsage(bundleIdentifier: app.bundleIdentifier) }
                            streamer.addSession(filter: SCContentFilter(desktopIndependentWindow: window), name: name, useH264: useH264, bitrate: bitrate, fps: fps, showsCursor: showsCursor, screenOrigin: origin, code: useCode)
                        }
                        for (name, display) in selectedDisplays {
                            streamer.addSession(filter: SCContentFilter(display: display, excludingWindows: []), name: name, useH264: useH264, bitrate: bitrate, fps: fps, showsCursor: showsCursor, code: useCode)
                        }
                        selected.removeAll()
                        selectedApps.removeAll()
                        selectedWindows.removeAll()
                        selectedDisplays.removeAll()
                        isPresented = false
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
        .padding(20)
        .frame(minWidth: 560, minHeight: 500)
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
    @State private var selectedName: String = ""
    @State private var selectedFilter: SCContentFilter?
    @State private var expandedApps: Set<String> = []

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("更改投屏内容").font(.title2.bold())
                Spacer()
                Text("当前：\(session.contentName)").font(.caption).foregroundStyle(.secondary)
                Button("取消") { dismiss() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("显示器").font(.caption).foregroundStyle(.secondary)
                    ForEach(streamer.displays, id: \.displayID) { display in
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let name = "显示器 \(Int(display.width))×\(Int(display.height))"
                        pickerRow(name: name, filter: filter)
                    }

                    Text("应用与窗口").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    ForEach(streamer.appGroups) { group in
                        EditAppGroupPicker(group: group, selectedFilter: $selectedFilter, selectedName: $selectedName, streamer: streamer)
                    }
                }
            }

            if let filter = selectedFilter {
                Divider()
                HStack {
                    Spacer()
                    Button("确认切换") {
                        session.changeFilter(filter, name: selectedName)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
    }

    private func pickerRow(name: String, filter: SCContentFilter) -> some View {
        Button("选择") {
            selectedFilter = filter
            selectedName = name
        }
        .buttonStyle(.bordered).controlSize(.small)
        .tint(selectedFilter === filter ? .blue : nil)
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
                    .font(.caption).foregroundStyle(.secondary)
                if let icon = group.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(group.application.applicationName).font(.callout).bold()
                Spacer()
                if group.windows.count > 1, let display = streamer.displays.first {
                    let key = "app-\(group.application.bundleIdentifier)-\(display.displayID)"
                    Button(selected.contains(key) ? "已选" : "投屏整个应用") {
                        if selected.contains(key) { selected.remove(key); selectedApps.removeAll { $0.1 === group.application } }
                        else { selected.insert(key); selectedApps.append((group.application.applicationName, group.application)) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
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
                        Text(title).font(.caption).lineLimit(1)
                        Spacer()
                        Button(selected.contains(key) ? "已选" : "选择") {
                            if selected.contains(key) { selected.remove(key); selectedWindows.removeAll { $0.1 === window } }
                            else { selected.insert(key); selectedWindows.append((title, window)) }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(selected.contains(key) ? .blue : nil)
                    }
                    .padding(.leading, 28)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
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
                    .font(.caption).foregroundStyle(.secondary)
                if let icon = group.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(group.application.applicationName).font(.callout).bold()
                Spacer()
                if let display = streamer.displays.first {
                    let filter = SCContentFilter(display: display, including: [group.application], exceptingWindows: [])
                    Button("投屏整个应用") {
                        selectedFilter = filter; selectedName = group.application.applicationName
                    }
                    .buttonStyle(.bordered).controlSize(.small)
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
                        Text("  \(title)").font(.caption).lineLimit(1)
                        Spacer()
                        Button("选择") {
                            selectedFilter = filter; selectedName = title
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(selectedFilter === filter ? .blue : nil)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
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
        .buttonStyle(.bordered).controlSize(.small)
        .tint(selectedFilter === filter ? .blue : nil)
    }
}

