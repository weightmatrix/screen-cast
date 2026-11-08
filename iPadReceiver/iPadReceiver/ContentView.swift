import SwiftUI
import Combine
import MetalKit
import CoreImage

private var drawerWidth: CGFloat { min(400, UIScreen.main.bounds.width) }

struct ContentView: View {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    @AppStorage("appMode") private var appMode = "receive"
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var client = StreamClient()
    @AppStorage("macIP") private var host = ""
    @AppStorage("macPort") private var portText = "8318"
    @AppStorage("connectMode") private var connectMode = "ip"
    @AppStorage("internetIP") private var internetHost = ""
    @AppStorage("internetPort") private var internetPortText = "9318"
    @AppStorage("matchCode") private var matchCode = ""
    @AppStorage("room.nickname") private var nickname = ""
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
                        .padding(.vertical, AppSkin.victorian(skin) ? 34 : 0)
                        .frame(width: drawerWidth)
                        .background { if AppSkin.victorian(skin) { AppPaperBackground() } else { Color(red: 0.045, green: 0.065, blue: 0.095) } }
                        .overlay { if AppSkin.victorian(skin) { VictorianFrame() } }
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
        .preferredColorScheme(AppSkin.victorian(skin) ? .light : .dark)
        .tint(AppSkin.victorian(skin) ? AppSkin.ink : Color(red: 0.34, green: 0.70, blue: 1))
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
        .onDisappear { RoomAudioSettings.shared.setMicrophone(false); client.disconnect(); DiscoveryListener.shared.stop() }
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
                    Button { closeDrawer() } label: { Image(systemName: "xmark").frame(width:28,height:28) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("收起接收设置")
                }
                Text(AppPresentation.title).font(.caption).foregroundStyle(.secondary)
                Button { client.disconnect(); appMode = "cast" } label: { Label("投屏模式", systemImage: "arrow.up.right.video") }.buttonStyle(.bordered)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(ConnectionMode.allCases) { mode in
                        AudioActionButton(title: mode.label, active: connectMode == mode.rawValue) { client.disconnect(); connectMode = mode.rawValue }
                            .frame(maxWidth: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("昵称·选填").font(.caption)
                    TextField("你的名字", text: $nickname).textFieldStyle(.roundedBorder).onChange(of:nickname) { _ in RoomSession.shared.refreshNickname() }
                    if connectMode == "ip" || connectMode == "wanIP" {
                        Text(connectMode == "wanIP" ? "公网地址" : "局域网地址").font(.caption)
                        TextField("对方地址", text: connectMode == "wanIP" ? $internetHost : $host).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("端口").font(.caption)
                        TextField("端口", text: connectMode == "wanIP" ? $internetPortText : $portText).textFieldStyle(.roundedBorder)
                    } else {
                        Text("编号").font(.caption)
                        TextField("邀请链接或编号", text: $matchCode).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Text("密码·必填").font(.caption)
                    SecureField("填写连接密码", text: $connectionPassword).textFieldStyle(.roundedBorder)
                    Text("申请·必填").font(.caption)
                    TextEditor(text: $applicationText).frame(height:76).overlay(RoundedRectangle(cornerRadius:5).stroke(.secondary.opacity(0.35)))
                    HStack {
                        Button("连接", action: toggleConnection).disabled(isConnected || client.status == .connecting || !client.recoveryMessage.isEmpty)
                        Button("断开") { client.disconnect() }.disabled(!isConnected && client.status != .connecting && client.recoveryMessage.isEmpty)
                    }.buttonStyle(.bordered)
                }.padding(16).appPanelStyle()
                ReceiverAudioControls(sound: Binding(get: { client.receivesPageAudio || client.receivesMicrophone }, set: { client.receivesPageAudio = $0; client.receivesMicrophone = $0 }))
                VStack(alignment: .leading, spacing:10) {
                    Text("连接信息与诊断").font(.headline)
                    ConnectionPathView(info: client.connectionInfo)
                    Text(MediaPath.preference).font(.caption).foregroundStyle(.secondary)
                    HStack { Circle().fill(statusColor).frame(width:8,height:8); Text(LocalizedStringKey(statusText)).font(.caption) }
                    if !client.recoveryMessage.isEmpty { Text(client.recoveryMessage).font(.caption) }
                    if isConnected { ReceiveTimingView(timing:client.receiveTiming); Text(client.decoder.diagText).font(.caption); Text("已接收 \(client.frameCount) 帧").font(.caption) }
                    ScrollView { Text(diag.text).font(.system(size:11,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:145)
                }.padding(16).appPanelStyle()
                ConnectionPrivacyNotice()
            }.font(.system(size:15)).padding(.horizontal,22).padding(.top,48).padding(.bottom,24)
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
