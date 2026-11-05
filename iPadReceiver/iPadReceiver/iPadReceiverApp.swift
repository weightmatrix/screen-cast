import SwiftUI

@main
struct iPadReceiverApp: App {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    init() { StartupTiming.entered = ProcessInfo.processInfo.systemUptime }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.locale, AppLanguage.locale(language))
        }
    }
}

struct RootView: View {
    @AppStorage("appMode") private var appMode = ""
    @State private var showSettings = false
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--inspect-broadcast-resolution") {
                Text("分辨率诊断").task {
                    let store = BroadcastSettings.store
                    ConnectionDiag.shared.log("ResolutionInspect stored=\(store.string(forKey: "broadcastResolution") ?? "missing") active=\(BroadcastSettings.isActive) actual=\(store.string(forKey: "broadcastResolutionStatus") ?? "missing") screen=\(UIScreen.main.nativeBounds) nativeScale=\(UIScreen.main.nativeScale)")
                }
            } else {
                content
            }
            #else
            content
            #endif
        }.preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").padding(12)
            }
            .accessibilityLabel("设置")
            .background(.regularMaterial, in: Circle()).padding(12)
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                Form { Section("语言") { AppLanguagePicker() }; RoomPreferences(); Section("声音设备与测试") { RoomAudioControls(receiver: appMode == "receive") } }
                    .navigationTitle("设置")
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showSettings = false }
                    } }
            }.navigationViewStyle(.stack)
                .environment(\.locale, AppLanguage.locale(language))
        }
        .overlay { RoomChatOverlay() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in RoomSession.shared.pollBroadcast() }
        .onAppear { StartupTiming.rootVisible() }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-native-audio") { await NativeAudioVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-native-routes") { await NativeRoutesVerification.run() }
            if ProcessInfo.processInfo.arguments.contains("--verify-broadcast-encoder") {
                await BroadcastVerification.run()
            }
            #endif
        }
    }

    @ViewBuilder private var content: some View {
            switch appMode {
            case "cast": iPadSenderView()
            case "receive": ContentView()
            default: ModePicker(select: { appMode = $0 })
            }
    }
}

private enum StartupTiming {
    static var entered = ProcessInfo.processInfo.systemUptime
    private static var reported = false
    static func rootVisible() {
        guard !reported else { return }; reported = true
        let milliseconds = (ProcessInfo.processInfo.systemUptime - entered) * 1000
        NSLog("[Startup] nativeEntryToRootMS=%.1f system=%@", milliseconds, UIDevice.current.systemVersion)
    }
}

struct ModePicker: View {
    let select: (String) -> Void

    var body: some View {
        ZStack {
            Color(UIColor.secondarySystemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "display.2")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                Text(AppPresentation.title).font(.largeTitle.bold())

                VStack(spacing: 16) {
                    Button {
                        select("receive")
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                            Text("接收")
                                .font(.title3.bold())
                        }
                        .frame(width: 220, height: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button {
                        select("cast")
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                            Text("投屏")
                                .font(.title3.bold())
                        }
                        .frame(width: 220, height: 64)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }

                Text("整屏投屏，或接收另一台设备的画面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
