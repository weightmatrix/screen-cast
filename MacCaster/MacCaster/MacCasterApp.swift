import SwiftUI
import AppKit

@main
struct MacCasterApp: App {
    @NSApplicationDelegateAdaptor(RecordingAppDelegate.self) private var appDelegate
    @StateObject private var streamer = ScreenStreamer()
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage("appearance.colorScheme") private var appearance = "system"
    @AppStorage("appMode") private var activeMode = "cast"
    @AppStorage(AppSkin.key) private var appSkin = "victorian"

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
                .background(NativeWindowCapabilities().frame(width: 0, height: 0))
                .environment(\.locale, AppLanguage.locale(language))
                .focusEffectDisabled()
                .preferredColorScheme(AppSkin.victorian(appSkin) ? .light : AppAppearance.scheme(appearance))
                .environmentObject(streamer)
                .overlay { if activeMode == "receive" { RoomChatOverlay() } }
                .task {
                    _ = BaiduDrive.shared
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Link("隐私政策", destination: AppPresentation.privacyURL)
                Link("技术支持", destination: AppPresentation.supportURL)
            }
        }
        Settings {
            AppearanceSettingsView()
                .background(NativeWindowCapabilities().frame(width: 0, height: 0))
                .environmentObject(streamer)
                .environment(\.locale, AppLanguage.locale(language))
                .focusEffectDisabled()
                .preferredColorScheme(AppSkin.victorian(appSkin) ? .light : AppAppearance.scheme(appearance))
        }
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    @AppStorage("appMode") private var activeMode = "cast"
    @State private var passwordDraft = ""
    @State private var passwordError = false
    @AppStorage("appearance.skin") private var skin = "victorian"
    @AppStorage("appearance.colorScheme") private var appearance = "system"

    var body: some View {
        ScrollView { Form {
            Section("皮肤") {
                AppSkinPicker()
                if AppSkin.victorian(skin) { VictorianHeading(title: "投屏自由") }

            }
            Section("录课存储") { RecordingFolderSettings() }
            Section("百度网盘录课") { BaiduDriveSettings() }
            Section("外观") {
                Picker("深浅色", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("固定浅色").tag("light")
                    Text("固定深色").tag("dark")
                }.pickerStyle(.segmented).disabled(AppSkin.victorian(skin))
                if AppSkin.victorian(skin) { Text("装饰主题使用各自的浅色配色；深浅色设置适用于极简皮肤。").font(.caption).foregroundStyle(.secondary) }
            }
            Section("语言") {
                AppLanguagePicker()
            }
            RoomPreferences()
            Section("声音设备与测试") { RoomAudioControls(receiver: activeMode == "receive") }
            Section("连接密码") {
                SecureField("连接密码（6–64位）", text: $passwordDraft)
                Button("设置连接密码") {
                    passwordError = !streamer.updateConnectionPassword(passwordDraft)
                    if !passwordError { passwordDraft = "" }
                }.disabled(!AdmissionCredentials.validPassword(passwordDraft))
                Text(passwordError ? "密码保存失败，请重试" : AdmissionCredentials.validPassword(streamer.connectionPassword) ? "已设置密码；修改密码会断开当前连接" : "请先设置密码，接收者还须填写申请文字")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .toggleStyle(OrnamentalToggleStyle())
        .scrollContentBackground(AppSkin.victorian(skin) ? .hidden : .visible)
        .background(AppPaperBackground())
        .preferredColorScheme(AppSkin.victorian(skin) ? .light : nil)
        .font(.system(size: 16))
        .controlSize(.large)
        }
        .background(AppPaperBackground())
        .overlay { if AppSkin.victorian(skin) { VictorianFrame() } }
        .frame(width: 620, height: 720)
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
    var selected = false
    @AppStorage(AppSkin.key) private var skin = "victorian"
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.bottom, AppSkin.victorian(skin) || selected ? 18 : 0)
            .frame(minWidth: 24, minHeight: 46)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        if AppSkin.victorian(skin) {
            label.foregroundStyle(selected ? Color(red: 0.17, green: 0.40, blue: 0.25) : Color.primary)
                .background(LinearGradient(colors: prominent ? [AppSkin.ivory, AppSkin.brass.opacity(0.16)] : [AppSkin.paper, AppSkin.ivory.opacity(0.5)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Color(red: 0.20, green: 0.48, blue: 0.30) : AppSkin.brass, lineWidth: 0.8))
                .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 3).strokeBorder(AppSkin.brass.opacity(0.35), lineWidth: 0.5))
                .overlay(alignment: .bottom) { StateOrnament(active: selected) }
        } else if #available(macOS 26.0, *) {
            if prominent || selected {
                label.glassEffect(.regular.tint((selected ? Color.green : Color.accentColor).opacity(0.18)).interactive(), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottom) { StateOrnament(active: selected) }
            } else {
                label.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            label.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.green.opacity(0.5) : Color.primary.opacity(configuration.isPressed ? 0.2 : 0.08)))
                .overlay(alignment: .bottom) { StateOrnament(active: selected) }
        }
    }
}

struct RootView: View {
    @AppStorage("appMode") private var appMode = "cast"
    @AppStorage("appearance.skin") private var skin = "victorian"
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var showAddSheet = false
    @State private var sessionsBeforeAdding = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            if AppSkin.victorian(skin) { VictorianHeading(title: "李知本·投屏自由").padding(.horizontal, 40).padding(.top, 14).background(AppPaperBackground()) }
            modeBar
            Group {
            if appMode == "receive" { MacReceiverView() }
            else { ContentView(onAdd: beginAdding) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPaperBackground().ignoresSafeArea())
        .toggleStyle(OrnamentalToggleStyle())
        .font(.system(size: 16))
        .buttonStyle(AppGlassButtonStyle())
        .controlSize(.large)
        .tint(AppSkin.victorian(skin) ? AppSkin.ink : CastStyle.accent)
        .preferredColorScheme(AppSkin.victorian(skin) ? .light : nil)
        .sheet(isPresented: $showAddSheet, onDismiss: {
            if streamer.sessions.contains(where: { !sessionsBeforeAdding.contains($0.id) }) { appMode = "cast" }
        }) {
            AddStreamSheet(streamer: streamer, isPresented: $showAddSheet)
                .focusEffectDisabled()
        }
    }

    private var modeBar: some View {
            HStack(spacing: 18) {
                HStack(spacing: 12) {
                    Button { appMode = "cast" } label: {
                        Label("投屏", systemImage: "arrow.up.right.video")
                    }
                        .buttonStyle(AppGlassButtonStyle(selected: appMode == "cast"))
                        .accessibilityAddTraits(appMode == "cast" ? .isSelected : [])
                    Button { appMode = "receive" } label: {
                        Label("接收", systemImage: "arrow.down.left.video")
                    }
                        .buttonStyle(AppGlassButtonStyle(selected: appMode == "receive"))
                        .accessibilityAddTraits(appMode == "receive" ? .isSelected : [])
                }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .trailing) {
                Button(action: beginAdding) { Label("添加投屏", systemImage: "plus") }
                    .labelStyle(.iconOnly).buttonStyle(AppGlassButtonStyle()).help("添加投屏").padding(.trailing, 24)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(AppPaperBackground())
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

// Keep the native green window control available even when content supplies minimum dimensions.
private struct NativeWindowCapabilities: NSViewRepresentable {
    @AppStorage(AppSkin.key) private var skin = "victorian"
    final class Probe: NSView {
        var paper = NSColor.windowBackgroundColor
        func configure() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = paper
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.paper = AppSkin.victorian(skin) ? NSColor(AppSkin.paper) : .windowBackgroundColor; return view }
    func updateNSView(_ view: Probe, context: Context) { view.paper = AppSkin.victorian(skin) ? NSColor(AppSkin.paper) : .windowBackgroundColor; view.configure() }
}
