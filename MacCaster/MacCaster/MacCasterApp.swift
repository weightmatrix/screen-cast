import SwiftUI

@main
struct MacCasterApp: App {
    @NSApplicationDelegateAdaptor(RecordingAppDelegate.self) private var appDelegate
    @StateObject private var streamer = ScreenStreamer()
    @AppStorage("appearance.colorScheme") private var appearance = "system"

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--verify-native-scenario"), let index = arguments.firstIndex(of: "--scenario-control"), index + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[index + 1])
            Task { @MainActor in await NativeBenchmark.run(controlURL: url) }
        }
        if arguments.contains("--verify-native-audio") { Task { @MainActor in await NativeAudioVerification.run() } }
        if arguments.contains("--verify-native-routes") {
            Task { @MainActor in await NativeRoutesVerification.run() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("投屏") {
            RootView()
                .focusEffectDisabled()
                .preferredColorScheme(AppAppearance.scheme(appearance))
                .environmentObject(streamer)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-motion") { await NativeRoutesVerification.motion() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-receive") { await NativeRoutesVerification.receive() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-capture") || ProcessInfo.processInfo.arguments.contains("--verify-native-publish") { await streamer.verifyNativeCapture() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-display-pacing") {
                        await MacStreamImageView.verifyPacing()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-internet-publish") || ProcessInfo.processInfo.arguments.contains("--verify-internet-casting") || ProcessInfo.processInfo.arguments.contains("--verify-internet-ip") || ProcessInfo.processInfo.arguments.contains("--verify-casting") || ProcessInfo.processInfo.arguments.contains("--verify-live-quality") {
                        await streamer.verifyCasting()
                    }
                    #endif
                }
        }
        .defaultSize(width: 820, height: 600)
        .commands {
            CommandGroup(replacing: .help) {
                Link("隐私政策", destination: AppPresentation.privacyURL)
                Link("技术支持", destination: AppPresentation.supportURL)
            }
        }
        Settings {
            AppearanceSettingsView()
                .focusEffectDisabled()
                .preferredColorScheme(AppAppearance.scheme(appearance))
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appearance.skin") private var skin = "minimal"
    @AppStorage("appearance.colorScheme") private var appearance = "system"

    var body: some View {
        Form {
            Section("皮肤") {
                Picker("当前皮肤", selection: $skin) {
                    Text("极简皮肤").tag("minimal")
                }
            }
            Section("外观") {
                Picker("深浅色", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("固定浅色").tag("light")
                    Text("固定深色").tag("dark")
                }.pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 16))
        .controlSize(.large)
        .frame(width: 520, height: 300)
        .navigationTitle("设置")
    }
}

enum AppAppearance {
    static func scheme(_ value: String) -> ColorScheme? {
        switch value { case "light": return .light; case "dark": return .dark; default: return nil }
    }
}

struct AppGlassButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 18)
            .frame(minWidth: 24, minHeight: 46)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        if #available(macOS 26.0, *) {
            if prominent {
                label.glassEffect(.regular.tint(.accentColor.opacity(0.18)).interactive(), in: RoundedRectangle(cornerRadius: 14))
            } else {
                label.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            label.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(configuration.isPressed ? 0.2 : 0.08)))
        }
    }
}

struct RootView: View {
    @AppStorage("appMode") private var appMode = "cast"
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var showAddSheet = false
    @State private var sessionsBeforeAdding = Set<UUID>()

    var body: some View {
        Group {
            if appMode == "receive" { MacReceiverView() }
            else { ContentView(onAdd: beginAdding) }
        }
        .font(.system(size: 16))
        .buttonStyle(AppGlassButtonStyle())
        .controlSize(.large)
        .tint(CastStyle.accent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 12) {
                    Button { appMode = "cast" } label: { Label("投屏", systemImage: "arrow.up.right.video") }
                        .buttonStyle(AppGlassButtonStyle(prominent: appMode == "cast"))
                    Button { appMode = "receive" } label: { Label("接收", systemImage: "arrow.down.left.video") }
                        .buttonStyle(AppGlassButtonStyle(prominent: appMode == "receive"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: beginAdding) { Label("添加投屏", systemImage: "plus") }
                    .labelStyle(.iconOnly).buttonStyle(AppGlassButtonStyle()).help("添加投屏")
            }
            ToolbarItem(placement: .automatic) {
                SettingsLink { Label("设置", systemImage: "gearshape") }
                    .labelStyle(.iconOnly).buttonStyle(AppGlassButtonStyle()).help("设置")
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            if streamer.sessions.contains(where: { !sessionsBeforeAdding.contains($0.id) }) { appMode = "cast" }
        }) {
            AddStreamSheet(streamer: streamer, isPresented: $showAddSheet)
                .focusEffectDisabled()
        }
    }

    private func beginAdding() {
        sessionsBeforeAdding = Set(streamer.sessions.map(\.id))
        streamer.loadShareableContent()
        showAddSheet = true
    }
}

struct MacModePicker: View {
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "display.2")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("投屏").font(.largeTitle.bold())

            HStack(spacing: 24) {
                Button {
                    select("cast")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                        Text("投屏").font(.title3.bold())
                    }
                    .frame(width: 140, height: 90)
                }
                .buttonStyle(AppGlassButtonStyle(prominent: true))
                .tint(.blue)

                Button {
                    select("receive")
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.title)
                        Text("接收").font(.title3.bold())
                    }
                    .frame(width: 140, height: 90)
                }
                .buttonStyle(AppGlassButtonStyle(prominent: true))
                .tint(.green)
            }
        }
        .padding(40)
        .frame(width: 420, height: 320)
    }
}
