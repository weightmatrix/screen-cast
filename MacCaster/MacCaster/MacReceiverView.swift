import SwiftUI
import AppKit

private let macDrawerWidth: CGFloat = 300

struct MacReceiverView: View {
    @StateObject private var client = MacReceiverClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @AppStorage("connectMode") private var connectMode = "code"
    @AppStorage("matchCode") private var matchCode = ""
    @AppStorage("appMode") private var appMode = "cast"
    @State private var drawerOpen = false

    var body: some View {
        ZStack {
            MacStreamImageView(decoder: client.decoder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if drawerOpen {
                Color.black.opacity(0.35)
                    .onTapGesture { closeDrawer() }
            }

            HStack(spacing: 0) {
                settingsPanel
                    .frame(width: macDrawerWidth)
                    .background(.ultraThinMaterial)
                    .offset(x: drawerOpen ? 0 : -macDrawerWidth)
                Spacer()
            }
        }
        .background(Color.black)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if value.startLocation.x < 40 || drawerOpen {
                        withAnimation(.interactiveSpring()) {
                            drawerOpen = value.translation.width > macDrawerWidth / 3
                        }
                    }
                }
                .onEnded { value in
                    if value.translation.width > 60 && value.startLocation.x < 40 { openDrawer() }
                    else if value.translation.width < -60 { closeDrawer() }
                }
        )
        .onAppear {
            MacDiscoveryListener.shared.start()
            if !host.isEmpty && connectMode == "ip" {
                client.connect(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(portText) ?? 8317)
            }
        }
    }

    private func openDrawer() { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = true } }
    private func closeDrawer() { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }

    private var isConnected: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("接收设置").font(.title3.bold())
                Spacer()
                Button {
                    client.disconnect()
                    appMode = "cast"
                } label: {
                    Label("投屏模式", systemImage: "arrow.up.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button { closeDrawer() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("连接方式", selection: $connectMode) {
                Text("IP 直连").tag("ip")
                Text("匹配码").tag("code")
            }
            .pickerStyle(.segmented)

            if connectMode == "ip" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("对方 IP").font(.caption).foregroundStyle(.secondary)
                    TextField("192.168.x.x", text: $host)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("端口").font(.caption).foregroundStyle(.secondary)
                    TextField("8318", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("匹配码").font(.caption).foregroundStyle(.secondary)
                    TextField("4 位数字", text: $matchCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: matchCode) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }.prefix(4)
                            if String(filtered) != newValue { matchCode = String(filtered) }
                        }
                }
            }

            Button(action: toggleConnection) {
                Text(isConnected ? "断开" : "连接").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isConnected ? .red : .blue)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.subheadline)
                }
                if isConnected {
                    Label(client.decoder.diagText, systemImage: "info.circle").font(.caption).foregroundStyle(.green)
                    Label("已接收 \(client.frameCount) 帧", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    private var statusColor: Color {
        switch client.status {
        case .idle: .gray; case .connecting: .orange; case .connected: .green; case .failed: .red
        }
    }

    private var statusText: String {
        switch client.status {
        case .idle: "未连接"; case .connecting: "连接中..."; case .connected: "已连接"; case .failed(let m): m
        }
    }

    private func toggleConnection() {
        if isConnected {
            client.disconnect()
        } else if connectMode == "code" {
            guard matchCode.count == 4 else { return }
            if let found = MacDiscoveryListener.shared.find(code: matchCode) {
                client.connect(host: found.ip, port: found.port)
            } else {
                client.setStatus("未找到匹配码对应的投屏流")
            }
        } else {
            client.connect(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(portText) ?? 8317)
        }
    }
}

private final class MacFitView: NSView {
    let imageView: NSImageView

    override init(frame: NSRect) {
        imageView = NSImageView(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private struct MacStreamImageView: NSViewRepresentable {
    @ObservedObject var decoder: MacReceiverDecoder

    func makeNSView(context: Context) -> MacFitView {
        let view = MacFitView(frame: .zero)
        decoder.onImageUpdate = { [weak view] img in
            DispatchQueue.main.async { view?.imageView.image = img }
        }
        return view
    }

    func updateNSView(_ nsView: MacFitView, context: Context) {}
}
