import SwiftUI
import Combine
import MetalKit
import CoreImage

private let drawerWidth: CGFloat = 400

struct ContentView: View {
    @AppStorage("appMode") private var appMode = "receive"
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var client = StreamClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @AppStorage("connectMode") private var connectMode = "ip"
    @AppStorage("internetIP") private var internetHost = ""
    @AppStorage("internetPort") private var internetPortText = "9318"
    @AppStorage("matchCode") private var matchCode = ""
    @State private var connectionPassword = ""
    @State private var applicationText = ""
    @State private var drawerOpen = true
    @State private var autoSearchTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    @ObservedObject private var diag = ConnectionDiag.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if client.frameCount > 0 {
                    StreamingView(decoder: client.decoder)
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if client.status == .connecting {
                    ProgressView("等待首帧画面…").padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                if drawerOpen {
                    Color.black.opacity(0.35)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onTapGesture { closeDrawer() }
                }

                HStack(spacing: 0) {
                    settingsPanel
                        .frame(width: drawerWidth)
                        .background(Color(red: 0.045, green: 0.065, blue: 0.095))
                        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
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
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.34, green: 0.70, blue: 1))
        .ignoresSafeArea()
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if !drawerOpen, value.translation.width > 60, value.startLocation.x < 30 { openDrawer() }
                    else if drawerOpen, abs(value.startLocation.x - drawerWidth) < 24,
                            value.translation.width < -60 { closeDrawer() }
                }
        )
        .task {
            DiscoveryListener.shared.start()
            client.discoveryLookup = { code in
                DiscoveryListener.shared.find(code: code)
            }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            let verificationCode: String = {
                if let index = args.firstIndex(of: "--verify-match-code"), index + 1 < args.count { return args[index + 1] }
                return "67890123"
            }()
            if let index = args.firstIndex(of: "--verify-host"), index + 1 < args.count {
                host = args[index + 1]
                let verifyPort: UInt16 = {
                    if let i = args.firstIndex(of: "--verify-port"), i + 1 < args.count { return UInt16(args[i + 1]) ?? 8318 }
                    return 8318
                }()
                portText = String(verifyPort)
                matchCode = verificationCode
                connectMode = "ip"
                client.connect(host: host, port: verifyPort, code: matchCode)
            }
            if args.contains("--verify-internet-code") {
                matchCode = verificationCode
                connectMode = "wanCode"
                client.connectInternetCode(verificationCode)
            }
            if args.contains("--verify-code") {
                matchCode = verificationCode
                connectMode = "code"
            }
            #endif
        }
        .onReceive(autoSearchTimer) { _ in
            client.checkStaleConnection()
            guard !isConnected else { return }
            let p = UInt16(portText) ?? 8318
            client.autoSearch(mode: connectMode, host: host, port: p, code: matchCode)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                client.prepareForSuspension()
                DiscoveryListener.shared.stop()
            case .active:
                client.resumeAfterSuspension()
                // Recreate discovery after the Wi-Fi route has returned. The
                // regular auto-search tick will reconnect using current input.
                DiscoveryListener.shared.start()
            default:
                break
            }
        }
        .onChange(of: isConnected) { connected in if !connected { openDrawer() } }
        .onDisappear { client.disconnect(); DiscoveryListener.shared.stop() }
    }

    private func openDrawer() { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = true } }
    private func closeDrawer() { guard isConnected, client.frameCount > 0 else { return }; withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }

    private var isConnected: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(AppPresentation.title).font(.system(size: 20, weight: .semibold))
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(AppPresentation.receiveWorkbench)).font(.system(size: 30, weight: .semibold))
                    }
                    Spacer()
                    Button { closeDrawer() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7)).frame(width: 48, height: 48)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
                    }.accessibilityLabel("关闭设置")
                }
                Button { client.disconnect(); appMode = "cast" } label: {
                    Label("切换到投屏", systemImage: "arrow.up.right")
                        .font(.system(size: 18, weight: .medium)).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.bordered)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ConnectionMode.allCases) { mode in
                    Button { client.disconnect(); connectMode = mode.rawValue } label: {
                        Text(LocalizedStringKey(mode.label)).font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).tint(connectMode == mode.rawValue ? .blue : .gray)
                }
            }
            if connectMode == "wanIP" {
                Text("需要发送端可达的公网地址和映射端口；不经过配对服务器。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)

            }
                if connectMode == "ip" || connectMode == "wanIP" {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(connectMode == "wanIP" ? "对方公网地址" : "对方局域网地址").foregroundStyle(.secondary)
                        TextField(connectMode == "wanIP" ? "公网 IP 或域名" : "192.168.x.x", text: connectMode == "wanIP" ? $internetHost : $host)
                            .font(.system(size: 22, design: .monospaced))
                            .keyboardType(.default)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    }
                    HStack {
                        Text("端口").foregroundStyle(.secondary)
                        Spacer()
                        TextField(connectMode == "wanIP" ? "9318" : "8318", text: connectMode == "wanIP" ? $internetPortText : $portText)
                            .font(.system(size: 22, design: .monospaced)).multilineTextAlignment(.trailing)
                            .keyboardType(.default).frame(width: 130)
                    }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                }
            if connectMode == "code" || connectMode == "wanCode" {
                VStack(alignment: .leading, spacing: 12) {
                    Text("邀请链接或编号").foregroundStyle(.secondary)
                    TextField("邀请链接或编号", text: $matchCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 38, weight: .medium, design: .monospaced))
                        .keyboardType(.default)
                        .padding(18).frame(maxWidth: .infinity)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SecureField("连接密码", text: $connectionPassword).textFieldStyle(.roundedBorder)
                Text("申请文字（必填，最多200字）").font(.caption)
                TextEditor(text: $applicationText).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
            }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("接收页面声音", isOn: $client.receivesPageAudio)
                    Toggle("接收话筒声音", isOn: $client.receivesMicrophone)
                }.toggleStyle(.switch)
                ConnectionPrivacyNotice()
                Button(action: toggleConnection) {
                    Label(isConnected || client.status == .connecting || !client.recoveryMessage.isEmpty ? "断开连接" : "连接画面", systemImage: isConnected ? "stop.fill" : "arrow.up.right")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .foregroundStyle(isConnected ? Color.white : Color.black)
                        .background(isConnected ? Color.red.opacity(0.8) : Color(red: 0.34, green: 0.70, blue: 1), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(LocalizedStringKey(statusText)).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                DisclosureGroup("连接诊断") {
                    VStack(alignment: .leading, spacing: 16) {
                        if isConnected {
                            ReceiveTimingView(timing: client.receiveTiming).foregroundStyle(.secondary)
                            Text(client.decoder.diagText).foregroundStyle(.secondary)
                            Text("已接收 \(client.frameCount) 帧").foregroundStyle(.secondary)
                        }
                        Button("清空日志") { diag.clear() }.frame(minHeight: 44)
                        ScrollView {
                            Text(diag.text).font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 180)
                    }.padding(.top, 16)
                }.font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .font(.system(size: 17))
            .padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 32)
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

private struct StreamingView: UIViewRepresentable {
    let decoder: ImageDecoder

    func makeCoordinator() -> Coordinator {
        Coordinator(decoder: decoder)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let decoder: ImageDecoder
        weak var view: MTKView?
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?
        private var renderedFrames = 0
        private var displayedRevision: UInt64?
        private let schedulingLock = NSLock()
        private var drawScheduled = false
        private let perf = StreamPerformance("ipad.display")
        private let colorSpace = CGColorSpaceCreateDeviceRGB()
        private let gpuSlots = DispatchSemaphore(value: 2)

        init(decoder: ImageDecoder) {
            self.decoder = decoder
        }

        func attach(_ view: MTKView) {
            self.view = view
            decoder.onFrameAvailable = { [weak self] in self?.requestDraw() }
            requestDraw()
        }
        func detach() { decoder.onFrameAvailable = nil; view = nil }
        private func requestDraw() {
            schedulingLock.lock()
            guard !drawScheduled else { schedulingLock.unlock(); return }
            drawScheduled = true; schedulingLock.unlock()
            let at = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.schedulingLock.lock(); self.drawScheduled = false; self.schedulingLock.unlock()
                self.perf.record("mainQueueWait", milliseconds: (ProcessInfo.processInfo.systemUptime - at) * 1000)
                self.view?.draw()
            }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if ciContext == nil {
                ciContext = CIContext(mtlDevice: view.device!, options: [.cacheIntermediates: false])
            }
            displayedRevision = nil
            requestDraw()
        }

        func draw(in view: MTKView) {
            guard let device = view.device,
                  let displayFrame = decoder.frameForDisplay(after: displayedRevision),
                  gpuSlots.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer { if !submitted { gpuSlots.signal() } }
            if commandQueue == nil { commandQueue = device.makeCommandQueue() }
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
            let ci = ciContext ?? CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            ciContext = ci

            let width = CGFloat(drawable.texture.width)
            let height = CGFloat(drawable.texture.height)
            let drawableRect = CGRect(x: 0, y: 0, width: width, height: height)

            if let image = displayFrame.image, !image.extent.isEmpty {
                let src = image.extent
                let scale = min(width / src.width, height / src.height)
                let targetW = src.width * scale
                let targetH = src.height * scale
                let tx = (width - targetW) / 2
                let ty = (height - targetH) / 2
                let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                 tx: tx - src.minX * scale, ty: ty - src.minY * scale)
                let fitted = image.transformed(by: transform)
                let background = CIImage(color: CIColor.black).cropped(to: drawableRect)
                let output = fitted.composited(over: background)
                ci.render(ScreenDisplay.imageForDrawable(output, bounds: drawableRect), to: drawable.texture,
                          commandBuffer: commandBuffer, bounds: drawableRect, colorSpace: colorSpace)
            } else {
                let black = CIImage(color: CIColor.black).cropped(to: drawableRect)
                ci.render(black, to: drawable.texture, commandBuffer: commandBuffer, bounds: drawableRect, colorSpace: colorSpace)
            }

            commandBuffer.present(drawable)
            let slots = gpuSlots
            let perf = self.perf
            let submittedAt = ProcessInfo.processInfo.systemUptime
            perf.interval("drawInterval")
            commandBuffer.addCompletedHandler { [weak self] buffer in
                slots.signal()
                perf.record(buffer.status == .completed ? "rendered" : "gpuError", milliseconds: (ProcessInfo.processInfo.systemUptime - submittedAt) * 1000)
                self?.requestDraw()
            }
            displayedRevision = displayFrame.revision
            submitted = true
            renderedFrames += 1
            let frame = renderedFrames
            if frame <= 3 || frame % 120 == 0 {
                commandBuffer.addCompletedHandler { buffer in
                    if buffer.status == .completed {
                        ConnectionDiag.shared.log("display rendered#\(frame) GPU completed")
                    } else {
                        ConnectionDiag.shared.log("display GPU error: \(buffer.error?.localizedDescription ?? "unknown")")
                    }
                }
            }
            commandBuffer.commit()
        }
    }
}
