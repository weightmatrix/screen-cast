import SwiftUI
import AppKit
import MetalKit
import CoreImage

private let macDrawerWidth: CGFloat = 400

struct MacReceiverView: View {
    @StateObject private var client = MacReceiverClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @AppStorage("connectMode") private var connectMode = "code"
    @AppStorage("internetIP") private var internetHost = ""
    @AppStorage("internetPort") private var internetPortText = "9318"
    @AppStorage("matchCode") private var matchCode = ""
    @AppStorage("appMode") private var appMode = "cast"
    @State private var drawerOpen = true

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
                    .background(CastStyle.canvas)
                    .offset(x: drawerOpen ? 0 : -macDrawerWidth)
                Spacer()
            }
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            if !drawerOpen {
                Button("连接设置") { openDrawer() }
                    .padding(.top, 10)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if !drawerOpen, value.translation.width > 60, value.startLocation.x < 30 { openDrawer() }
                    else if drawerOpen, abs(value.startLocation.x - macDrawerWidth) < 24,
                            value.translation.width < -60 { closeDrawer() }
                }
        )
        .onAppear {
            MacDiscoveryListener.shared.start()
            client.discoveryLookup = { code in
                MacDiscoveryListener.shared.find(code: code)
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            client.checkStaleConnection()
            guard !isConnected else { return }
            let p = UInt16(portText) ?? 8318
            client.autoSearch(mode: connectMode, host: host, port: p, code: matchCode)
        }
    }

    private func openDrawer() { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = true } }
    private func closeDrawer() { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }

    private var isConnected: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var settingsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("接收设置").font(.system(size: 26, weight: .semibold))
                Spacer()
                Button {
                    client.disconnect()
                    appMode = "cast"
                } label: {
                    Label("投屏模式", systemImage: "arrow.up.circle")
                        .font(.system(size: 16))
                }
                .buttonStyle(CastButtonStyle())
                .controlSize(.large)
                Button { closeDrawer() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 23)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ConnectionMode.allCases) { mode in
                    Button { client.disconnect(); connectMode = mode.rawValue } label: {
                        Text(mode.label).font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).tint(connectMode == mode.rawValue ? .blue : .gray)
                }
            }
            if connectMode == "wanIP" {
                Text("需要发送端可达的公网地址和映射端口；不经过配对服务器。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else if connectMode == "wanCode" {
                Text("发送端需开启广域网直连。仅交换配对信息；无法穿透时会报错，不转发视频。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            if connectMode == "ip" || connectMode == "wanIP" {
                VStack(alignment: .leading, spacing: 6) {
                    Text(connectMode == "wanIP" ? "对方公网地址" : "对方局域网地址").font(.system(size: 16)).foregroundStyle(.secondary)
                    TextField(connectMode == "wanIP" ? "公网 IP 或域名" : "192.168.x.x", text: connectMode == "wanIP" ? $internetHost : $host)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("端口").font(.system(size: 16)).foregroundStyle(.secondary)
                    TextField(connectMode == "wanIP" ? "9318" : "8318", text: connectMode == "wanIP" ? $internetPortText : $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("匹配码").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("6–36 位数字", text: $matchCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Button(action: toggleConnection) {
                Text(isConnected || client.status == .connecting ? "断开" : "连接").frame(maxWidth: .infinity)
            }
            .buttonStyle(CastButtonStyle(primary: true))
            .tint(isConnected ? .red : .blue)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.subheadline)
                }
                if isConnected {
                    Label(client.decoder.diagText, systemImage: "info.circle").font(.system(size: 16)).foregroundStyle(.green)
                    Label("已接收 \(client.frameCount) 帧", systemImage: "arrow.down.circle").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(28)
        }
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
        if isConnected || client.status == .connecting {
            client.disconnect()
        } else if connectMode == "wanCode" {
            client.connectInternetCode(matchCode)
        } else if connectMode == "wanIP" {
            guard MatchingCode.isValid(matchCode), let port = UInt16(internetPortText), port > 0 else {
                client.setStatus("请输入有效公网端口和 6–36 位匹配码")
                return
            }
            client.connectInternetIP(host: internetHost.trimmingCharacters(in: .whitespacesAndNewlines), port: port, code: matchCode)
        } else if connectMode == "code" {
            guard MatchingCode.isValid(matchCode) else { return }
            tryMatchCode(attempt: 0)
        } else {
            guard MatchingCode.isValid(matchCode) else { return }
            client.connect(
                host: host.trimmingCharacters(in: .whitespaces),
                port: UInt16(portText) ?? 8318,
                code: matchCode
            )
        }
    }

    private func tryMatchCode(attempt: Int) {
        guard MatchingCode.isValid(matchCode) else { return }
        if MacDiscoveryListener.shared.find(code: matchCode) != nil {
            client.connectWithCode(matchCode)
        } else if attempt < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.tryMatchCode(attempt: attempt + 1)
            }
        } else {
            client.setStatus("未找到匹配码对应的投屏流")
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

struct MacStreamImageView: NSViewRepresentable {
    let decoder: MacReceiverDecoder

    func makeCoordinator() -> Coordinator { Coordinator(decoder: decoder) }

    func makeNSView(context: Context) -> MTKView { Self.makeView(coordinator: context.coordinator) }

    private static func makeView(coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        coordinator.configure(device: view.device)
        view.delegate = coordinator
        coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.detach()
        view.isPaused = true
        view.delegate = nil
    }

    #if DEBUG
    @MainActor static func verifyPacing() async {
        let decoder = MacReceiverDecoder()
        let coordinator = Coordinator(decoder: decoder)
        let view = makeView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "显示节奏验证"
        window.contentView = view
        window.orderFrontRegardless()
        var rendered = 0
        coordinator.onVerificationRender = { DispatchQueue.main.async { rendered += 1 } }
        let begin = ProcessInfo.processInfo.systemUptime
        for n in 0..<360 {
            let deadline = begin + Double(n) / 60
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let image = CIImage(color: n % 2 == 0 ? .red : .blue)
                .cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1440))
            decoder.publishVerificationFrame(image)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let passed = rendered >= 330
        DiagLog.log("PacingCheck", "\(passed ? "PASS" : "FAIL") 60fps input submitted=360 rendered=\(rendered) size=1920x1440")
        decoder.reset()
        try? await Task.sleep(nanoseconds: 100_000_000)
        coordinator.detach()
        view.delegate = nil
        window.orderOut(nil)
    }
    #endif

    final class Coordinator: NSObject, MTKViewDelegate {
        private let perf = StreamPerformance("mac.display")
        private let decoder: MacReceiverDecoder
        private var context: CIContext?
        private var queue: MTLCommandQueue?
        private var revision: UInt64?
        private weak var view: MTKView?
        private let schedulingLock = NSLock()
        private var drawScheduled = false
        private let slots = DispatchSemaphore(value: 2)
        #if DEBUG
        var onVerificationRender: (() -> Void)?
        #endif
        private var verifiedGPU = false
        private let colorSpace = CGColorSpaceCreateDeviceRGB()

        init(decoder: MacReceiverDecoder) { self.decoder = decoder }

        func configure(device: MTLDevice?) {
            guard let device else { return }
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            queue = device.makeCommandQueue()
        }

        func attach(_ view: MTKView) {
            self.view = view
            decoder.setFrameHandler { [weak self] in self?.requestDraw() }
        }

        func detach() {
            decoder.setFrameHandler(nil)
            view = nil
        }

        // Coalesce arrivals into one main-thread draw, without a second 60 Hz polling clock.
        private func requestDraw() {
            schedulingLock.lock()
            guard !drawScheduled else { schedulingLock.unlock(); return }
            drawScheduled = true
            let scheduledAt = ProcessInfo.processInfo.systemUptime
            schedulingLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.perf.record("mainQueueWait", milliseconds: (ProcessInfo.processInfo.systemUptime - scheduledAt) * 1000)
                self.schedulingLock.lock()
                self.drawScheduled = false
                self.schedulingLock.unlock()
                self.view?.draw()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            revision = nil
            requestDraw()
        }

        func draw(in view: MTKView) {
            let drawAt = ProcessInfo.processInfo.systemUptime
            guard let context, let frame = decoder.frameForDisplay(after: revision) else { return }
            perf.interval("drawInterval", at: drawAt)
            guard slots.wait(timeout: .now()) == .success else { perf.record("gpuBusy"); return }
            let acquireAt = ProcessInfo.processInfo.systemUptime
            guard let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer() else {
                slots.signal()
                perf.record("noDrawable")
                return
            }
            perf.record("drawableWait", milliseconds: (ProcessInfo.processInfo.systemUptime - acquireAt) * 1000)
            if frame.image != nil {
                perf.record("decodedToDraw", milliseconds: max(0, ProcessInfo.processInfo.systemUptime - frame.decodedAt) * 1000)
                if let previous = revision, frame.revision > previous + 1 {
                    perf.record("skipped", count: Int(frame.revision - previous - 1))
                }
            }
            let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
            var output = CIImage(color: .black).cropped(to: bounds)
            if let image = frame.image, !image.extent.isEmpty {
                let extent = image.extent
                let scale = min(bounds.width / extent.width, bounds.height / extent.height)
                let fitted = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (bounds.width - extent.width * scale) / 2,
                                                       y: (bounds.height - extent.height * scale) / 2))
                output = fitted.composited(over: output)
            }
            context.render(output, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
            command.present(drawable)
            let renderStart = ProcessInfo.processInfo.systemUptime
            let perf = self.perf
            command.addCompletedHandler { buffer in
                perf.interval("gpuCompletionInterval")
                perf.record(buffer.status == .completed ? "rendered" : "gpuError", milliseconds: (ProcessInfo.processInfo.systemUptime - renderStart) * 1000)
            }
            let slots = self.slots
            #if DEBUG
            if frame.image != nil, let onRender = onVerificationRender {
                command.addCompletedHandler { buffer in
                    if buffer.status == .completed { onRender() }
                }
            }
            if frame.image != nil, !verifiedGPU {
                verifiedGPU = true
                command.addCompletedHandler { buffer in
                    DiagLog.log("MetalCheck", buffer.status == .completed ? "PASS decoded frame rendered on GPU" : "FAIL GPU render")
                }
            }
            #endif
            command.addCompletedHandler { [weak self] _ in
                slots.signal()
                self?.requestDraw()
            }
            revision = frame.revision
            command.commit()
        }
    }
}
