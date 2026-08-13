import SwiftUI

private let drawerWidth: CGFloat = 300

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @AppStorage("connectMode") private var connectMode = "ip"
    @AppStorage("matchCode") private var matchCode = ""
    @State private var drawerOpen = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                StreamingView(decoder: client.decoder)
                    .frame(width: geo.size.width, height: geo.size.height)

                if drawerOpen {
                    Color.black.opacity(0.35)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onTapGesture { closeDrawer() }
                }

                HStack(spacing: 0) {
                    settingsPanel
                        .frame(width: drawerWidth)
                        .background(.ultraThinMaterial)
                        .offset(x: drawerOpen ? 0 : -drawerWidth)
                    Spacer()
                }

                if !drawerOpen {
                    Color.clear
                        .frame(width: 30, height: geo.size.height)
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if value.startLocation.x < 40 || drawerOpen {
                        withAnimation(.interactiveSpring()) {
                            drawerOpen = value.translation.width > drawerWidth / 3
                        }
                    }
                }
                .onEnded { value in
                    if value.translation.width > 60 && value.startLocation.x < 40 { openDrawer() }
                    else if value.translation.width < -60 { closeDrawer() }
                }
        )
        .task {
            DiscoveryListener.shared.start()
            if !host.isEmpty {
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
                Text("设置").font(.title3.bold())
                Spacer()
                Button { closeDrawer() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
            }

            Picker("连接方式", selection: $connectMode) {
                Text("IP 直连").tag("ip")
                Text("匹配码").tag("code")
            }
            .pickerStyle(.segmented)

            if connectMode == "ip" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac IP").font(.caption).foregroundStyle(.secondary)
                    TextField("192.168.x.x", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("端口").font(.caption).foregroundStyle(.secondary)
                    TextField("8318", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .keyboardType(.numberPad)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("匹配码").font(.caption).foregroundStyle(.secondary)
                    TextField("4 位数字", text: $matchCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .keyboardType(.numberPad)
                        .onChange(of: matchCode) { newValue in
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
            if let found = DiscoveryListener.shared.find(code: matchCode) {
                client.connect(host: found.ip, port: found.port)
            } else {
                client.setStatus("未找到匹配码对应的投屏流")
            }
        } else {
            client.connect(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(portText) ?? 8317)
        }
    }
}

private final class FitView: UIView {
    let imageView: UIImageView

    override init(frame: CGRect) {
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        super.init(frame: frame)
        imageView.frame = bounds
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private struct StreamingView: UIViewRepresentable {
    let decoder: ImageDecoder

    func makeUIView(context: Context) -> FitView {
        let view = FitView(frame: .zero)
        view.backgroundColor = .black
        decoder.onImageUpdate = { [weak view] img in
            DispatchQueue.main.async { view?.imageView.image = img }
        }
        return view
    }

    func updateUIView(_ iv: FitView, context: Context) {}
}
