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
        HStack {
            Image(systemName: "display.2").font(.title)
            Text("投屏控制台").font(.title2.bold())
            Spacer()
            Text("\(streamer.sessions.count) 个流运行中")
                .font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(streamer.sessions) { session in
                    SessionRow(session: session, onStop: { streamer.removeSession(session) })
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
    }
}

private struct SessionRow: View {
    @ObservedObject var session: StreamSession
    let onStop: () -> Void

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
                }
            }
            Spacer()
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private var statusDot: some View {
        Circle().fill(session.phase == .streaming ? Color.green : Color.red).frame(width: 10, height: 10)
    }
}

private struct AddStreamSheet: View {
    @ObservedObject var streamer: ScreenStreamer
    @Binding var isPresented: Bool

    @State private var selectedFilter: SCContentFilter?
    @State private var selectedName: String = ""
    @State private var useH264: Bool
    @State private var bitrate: Int
    @State private var fps: Int
    @State private var showsCursor: Bool = true

    init(streamer: ScreenStreamer, isPresented: Binding<Bool>) {
        self.streamer = streamer
        self._isPresented = isPresented
        self._useH264 = State(initialValue: streamer.defaultUseH264)
        self._bitrate = State(initialValue: streamer.defaultBitrate)
        self._fps = State(initialValue: streamer.defaultFPS)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("添加投屏流").font(.title2.bold())
                Spacer()
                Button("完成") { isPresented = false }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示器").font(.caption).foregroundStyle(.secondary)
                    ForEach(streamer.displays, id: \.displayID) { display in
                        contentCard(
                            title: "显示器 \(Int(display.width))×\(Int(display.height))",
                            subtitle: nil,
                            filter: SCContentFilter(display: display, excludingWindows: []),
                            icon: "display"
                        )
                    }

                    Text("应用与窗口").font(.caption).foregroundStyle(.secondary).padding(.top, 8)

                    ForEach(streamer.appGroups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                if let icon = group.icon {
                                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "app").foregroundStyle(.secondary)
                                }
                                Text(group.application.applicationName).font(.callout).bold()
                                Spacer()
                                if group.windows.count > 1, let display = streamer.displays.first {
                                    Button("投屏整个应用") {
                                        selectedFilter = SCContentFilter(display: display, including: [group.application], exceptingWindows: [])
                                        selectedName = group.application.applicationName
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .tint(selectedFilterIdentity(selectedFilter) == appGroupIdentity(display: display, app: group.application) ? .blue : nil)
                                }
                            }
                            ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                                let title = (window.title ?? "").isEmpty ? "未命名窗口" : window.title ?? ""
                                HStack(spacing: 8) {
                                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                                    Text(title).font(.caption).lineLimit(1)
                                    Spacer()
                                    Button("选择") {
                                        selectedFilter = SCContentFilter(desktopIndependentWindow: window)
                                        selectedName = title
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .tint(selectedFilterIdentity(selectedFilter) == windowIdentity(window) ? .blue : nil)
                                }
                                .padding(.leading, 28)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
                    }
                }
            }

            if selectedFilter != nil {
                Divider()

                Text("已选择：\(selectedName)").font(.callout).lineLimit(1)

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
                }

                HStack {
                    Spacer()
                    Button("开始投屏") {
                        streamer.addSession(filter: selectedFilter!, name: selectedName, useH264: useH264, bitrate: bitrate, fps: fps, showsCursor: showsCursor)
                        selectedFilter = nil
                        selectedName = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 500)
    }

    private func contentCard(title: String, subtitle: String?, filter: SCContentFilter, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 20)
            VStack(alignment: .leading) {
                Text(title).font(.callout)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("选择") {
                selectedFilter = filter
                selectedName = title
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(selectedFilterIdentity(selectedFilter) == displayIdentity(filter) ? .blue : nil)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selectedFilterIdentity(selectedFilter) == displayIdentity(filter) ? Color.blue.opacity(0.1) : Color.clear))
    }

    private func selectedFilterIdentity(_ f: SCContentFilter?) -> String {
        guard let f else { return "" }
        return "\(Unmanaged.passUnretained(f).toOpaque())"
    }

    private func displayIdentity(_ f: SCContentFilter) -> String {
        "\(Unmanaged.passUnretained(f).toOpaque())"
    }

    private func windowIdentity(_ w: SCWindow) -> String { "\(w.windowID)" }

    private func appGroupIdentity(display: SCDisplay, app: SCRunningApplication) -> String {
        "app-\(app.bundleIdentifier)-\(display.displayID)"
    }
}
