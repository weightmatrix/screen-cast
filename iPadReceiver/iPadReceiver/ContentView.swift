import SwiftUI

private let drawerWidth: CGFloat = 300

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @State private var drawerOpen = false
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StreamingView(decoder: client.decoder)
                .ignoresSafeArea()

            Color.black.opacity(drawerOpen ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }

            HStack(spacing: 0) {
                settingsPanel
                    .frame(width: drawerWidth)
                    .background(.ultraThinMaterial)
                    .offset(x: drawerOpen ? 0 : -drawerWidth)
                Spacer()
            }

            if !drawerOpen {
                HStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 24)
                        .contentShape(Rectangle())
                    Spacer()
                }
                .allowsHitTesting(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: drawerOpen)
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    if drawerOpen || value.startLocation.x < 40 {
                        state = value.translation.width
                    }
                }
                .onEnded { value in
                    if value.translation.width > 60 {
                        withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = true }
                    } else if value.translation.width < -60 {
                        withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false }
                    }
                }
        )
        .task {
            if !host.isEmpty {
                client.connect(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(portText) ?? 8317)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                Text("设置")
                    .font(.title3.bold())
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mac 地址").font(.caption).foregroundStyle(.secondary)
                TextField("IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("端口").font(.caption).foregroundStyle(.secondary)
                TextField("8318", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .keyboardType(.numberPad)
            }

            HStack(spacing: 12) {
                Button(action: toggleConnection) {
                    Text(isConnected ? "断开" : "连接")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isConnected ? .red : .blue)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.subheadline)
                }
                if isConnected {
                    Label(client.decoder.diagText, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Label("已接收 \(client.frameCount) 帧", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(20)
    }

    private var statusColor: Color {
        switch client.status {
        case .idle: .gray
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    private var statusText: String {
        switch client.status {
        case .idle: "未连接"
        case .connecting: "连接中..."
        case .connected: "已连接"
        case .failed(let m): m
        }
    }

    private func toggleConnection() {
        if isConnected { client.disconnect() }
        else { client.connect(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(portText) ?? 8317) }
    }
}

private final class ImageBridge {
    weak var imageView: UIImageView?
}

private final class FitView: UIView {
    let imageView: UIImageView

    init() {
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.clipsToBounds = true
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }
}

private struct StreamingView: UIViewRepresentable {
    let decoder: ImageDecoder

    func makeCoordinator() -> ImageBridge { ImageBridge() }

    func makeUIView(context: Context) -> FitView {
        let view = FitView()
        context.coordinator.imageView = view.imageView
        decoder.onImageUpdate = { [weak view] img in
            DispatchQueue.main.async { view?.imageView.image = img }
        }
        return view
    }

    func updateUIView(_ iv: FitView, context: Context) {}
}
