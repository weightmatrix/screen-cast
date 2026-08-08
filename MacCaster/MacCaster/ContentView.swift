import SwiftUI
import ScreenCaptureKit
import AppKit

struct ContentView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    @EnvironmentObject private var server: CastingServer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            switch streamer.phase {
            case .failed(let message):
                errorPanel(message)
            case .streaming(let name):
                streamingPanel(name: name)
            default:
                sourcePanel()
            }

            Divider()

            serverPanel
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 460)
        .task {
            server.start()
            streamer.bind(server: server)
            streamer.loadShareableContent()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "display.2")
                .font(.title)
                .foregroundStyle(.blue)
            Text("Mac 投屏到 iPad")
                .font(.title2)
                .bold()
            Spacer()
            if case .streaming = streamer.phase {
                Label("正在投屏", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func sourcePanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择要投屏的应用或窗口")
                    .font(.headline)
                Spacer()
                Button {
                    streamer.loadShareableContent()
                } label: {
                    Label("刷新列表", systemImage: "arrow.clockwise")
                }
            }
            if case .preparing = streamer.phase {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取屏幕内容…")
                        .foregroundStyle(.secondary)
                }
            } else if streamer.appGroups.isEmpty {
                Text("没有找到可投屏的窗口。请先打开一个应用窗口，或在 系统设置 → 隐私与安全性 → 屏幕录制 中允许本 App 后点击刷新。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(streamer.appGroups) { group in
                            AppGroupRow(group: group, display: streamer.displays.first) { filter, name in
                                streamer.start(filter: filter, name: name)
                            }
                        }
                    }
                }
            }
        }
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出错：\(message)")
                .foregroundStyle(.red)
            Text("提示：如果提示屏幕录制权限，请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许本 App，然后重新打开窗口。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新加载") {
                streamer.loadShareableContent()
            }
        }
    }

    private func streamingPanel(name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在投屏：\(name)")
                        .bold()
                    if server.clientCount > 0 {
                        Text("已连接 \(server.clientCount) 台设备 · 帧率 \(Int(streamer.currentFPS)) fps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("等待 iPad 连接…（在 iPad 上输入本机 IP 并连接）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("停止投屏") {
                    streamer.stop()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            HStack(spacing: 8) {
                Text("FPS: \(Int(streamer.currentFPS))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("H264 编码", isOn: $streamer.useH264)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .font(.caption)
            if streamer.useH264 {
                HStack(spacing: 8) {
                    Text("码率")
                        .font(.caption)
                    Slider(value: Binding(
                        get: { Double(streamer.h264Bitrate) / 1_000_000 },
                        set: { streamer.h264Bitrate = Int($0 * 1_000_000) }
                    ), in: 8...50, step: 2)
                    Text("\(Int(Double(streamer.h264Bitrate) / 1_000_000)) Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    private var serverPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(server.isRunning ? "投屏服务运行中（端口 \(server.port)，TCP）" : "投屏服务已停止")
                    .font(.callout)
                Spacer()
                Button(server.isRunning ? "停止服务" : "启动服务") {
                    server.isRunning ? server.stop() : server.start()
                }
                .controlSize(.small)
            }
            Text("iPad 连接地址：\(server.localIPs.joined(separator: "、")) : \(server.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = server.lastError {
                Text("服务错误：\(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct AppGroupRow: View {
    let group: ScreenStreamer.AppGroup
    let display: SCDisplay?
    let onStart: (SCContentFilter, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = group.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                }
                Text(group.application.applicationName)
                    .font(.callout)
                    .bold()
                Spacer()
                if group.windows.count > 1, let display {
                    Button("投屏整个应用") {
                        onStart(
                            SCContentFilter(display: display, including: [group.application], exceptingWindows: []),
                            group.application.applicationName
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle")
                        .foregroundStyle(.secondary)
                    Text((window.title ?? "").isEmpty ? "未命名窗口" : window.title ?? "")
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("投屏") {
                        let title = (window.title ?? "").isEmpty ? group.application.applicationName : window.title ?? ""
                        onStart(SCContentFilter(desktopIndependentWindow: window), title)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.leading, 28)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }
}
