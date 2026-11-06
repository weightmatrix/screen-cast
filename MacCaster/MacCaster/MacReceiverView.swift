import SwiftUI
import AppKit
import MetalKit
import CoreImage

private let macDrawerWidth: CGFloat = 400

struct MacReceiverView: View {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    @StateObject private var client = MacReceiverClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @AppStorage("connectMode") private var connectMode = "code"
    @AppStorage("internetIP") private var internetHost = ""
    @AppStorage("internetPort") private var internetPortText = "9318"
    @AppStorage("matchCode") private var matchCode = ""
    @AppStorage("appMode") private var appMode = "cast"
    @AppStorage("room.nickname") private var nickname = ""
    @State private var connectionPassword = ""
    @State private var applicationText = ""
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
                    .padding(.vertical, AppSkin.victorian(skin) ? 34 : 0)
                    .frame(width: macDrawerWidth)
                    .background(AppPaperBackground()).overlay { if AppSkin.victorian(skin) { VictorianFrame() } }
                    .offset(x: drawerOpen ? 0 : -macDrawerWidth)
                Spacer()
            }
        }
        .background(Color.black)
        .overlay {
            if client.status == .connecting {
                ProgressView("等待首帧画面…").padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
        .onChange(of: isConnected) { connected in if !connected { openDrawer() } }
        .onDisappear { RoomAudioSettings.shared.setMicrophone(false); client.disconnect(); client.recorder.stop() }
    }

    private func openDrawer() { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = true } }
    private func closeDrawer() { guard isConnected, client.frameCount > 0 else { return }; withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }

    private var isConnected: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(LocalizedStringKey(AppPresentation.receiveWorkbench)).font(.system(size: 22, weight: .medium, design: .serif))
                    Spacer()
                    Button { closeDrawer() } label: { Image(systemName: "xmark").frame(width: 28,height: 28) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("收起接收设置")
                }
                Text(AppPresentation.title).font(.caption).foregroundStyle(.secondary)
                Button { client.disconnect(); appMode = "cast" } label: { Label("投屏模式", systemImage: "arrow.up.right.video") }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Button { client.disconnect(); connectMode = mode.rawValue } label: {
                            Text(LocalizedStringKey(mode.label)).font(.system(size: 13)).frame(maxWidth: .infinity)
                        }.buttonStyle(AppGlassButtonStyle(prominent: connectMode == mode.rawValue))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("昵称·选填").font(.caption)
                    TextField("你的名字", text: $nickname).textFieldStyle(.roundedBorder).onChange(of: nickname) { _ in RoomSession.shared.refreshNickname() }
                    if connectMode == "ip" || connectMode == "wanIP" {
                        Text(connectMode == "wanIP" ? "公网地址" : "局域网地址").font(.caption)
                        TextField("对方地址", text: connectMode == "wanIP" ? $internetHost : $host).textFieldStyle(.roundedBorder)
                        Text("端口").font(.caption)
                        TextField("端口", text: connectMode == "wanIP" ? $internetPortText : $portText).textFieldStyle(.roundedBorder)
                    } else {
                        Text("编号").font(.caption)
                        TextField("邀请链接或编号", text: $matchCode).textFieldStyle(.roundedBorder)
                    }
                    Text("密码·必填").font(.caption)
                    SecureField("填写连接密码", text: $connectionPassword).textFieldStyle(.roundedBorder)
                    Text("申请·必填").font(.caption)
                    TextField("告诉投送者你是谁（最多200字）", text: $applicationText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                    HStack {
                        Button("连接", action: toggleConnection).disabled(isConnected || client.status == .connecting || !client.recoveryMessage.isEmpty)
                        Button("断开") { client.disconnect() }.disabled(!isConnected && client.status != .connecting && client.recoveryMessage.isEmpty)
                    }
                }.padding(16).appPanelStyle()
                LocalRecordingControls(recorder: client.recorder)
                ReceiverAudioControls(sound: Binding(get: { client.receivesPageAudio || client.receivesMicrophone }, set: { client.receivesPageAudio = $0; client.receivesMicrophone = $0 }))
                VStack(alignment: .leading, spacing: 10) {
                    Text("诊断").font(.headline)
                    HStack { Circle().fill(statusColor).frame(width: 8,height: 8); Text(LocalizedStringKey(statusText)).font(.caption) }
                    if !client.recoveryMessage.isEmpty { Text(client.recoveryMessage).font(.caption).foregroundStyle(.secondary) }
                    if isConnected { ReceiveTimingView(timing: client.receiveTiming); Text(client.decoder.diagText).font(.caption); Text("已接收 \(client.frameCount) 帧").font(.caption) }
                }.padding(16).appPanelStyle()
                ConnectionPrivacyNotice()
            }.font(.system(size: 15)).padding(.horizontal, 22).padding(.vertical, 18)
        }
    }

    private var statusColor: Color {
        switch client.status {
        case .idle: .gray; case .connecting: .orange; case .connected: .green; case .failed: .red
        }
    }

    private var statusText: String {
        switch client.status {
        case .idle: client.recoveryMessage.isEmpty ? "未连接" : client.recoveryMessage
        case .connecting: client.recoveryMessage.isEmpty ? "连接中..." : client.recoveryMessage
        case .connected: "已连接"
        case .failed(let m): client.recoveryMessage.isEmpty ? m : client.recoveryMessage
        }
    }

    private func toggleConnection() {
        if isConnected || client.status == .connecting || !client.recoveryMessage.isEmpty {
            client.disconnect(); return
        }
        guard AdmissionCredentials.validPassword(connectionPassword), let text = AdmissionCredentials.application(applicationText) else {
            client.setStatus("请填写连接密码和1至200字申请文字"); return
        }
        client.connectionPassword = connectionPassword; client.applicationText = text
        let invitation = AdmissionCredentials.invitation(matchCode)
        if connectMode == "wanCode" || connectMode == "code" {
            guard MatchingCode.isValid(invitation) else { client.setStatus("请输入有效邀请链接或编号"); return }
            if connectMode == "wanCode" { client.connectInternetCode(invitation) }
            else { client.connectWithCode(invitation) }
        } else {
            guard let port = UInt16(connectMode == "wanIP" ? internetPortText : portText), port > 0 else { client.setStatus("请输入有效端口"); return }
            let address = (connectMode == "wanIP" ? internetHost : host).trimmingCharacters(in: .whitespacesAndNewlines)
            if connectMode == "wanIP" { client.connectInternetIP(host: address, port: port, code: "") }
            else { client.connect(host: address, port: port, code: "") }
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
            context.render(ScreenDisplay.imageForDrawable(output, bounds: bounds), to: drawable.texture,
                           commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
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
