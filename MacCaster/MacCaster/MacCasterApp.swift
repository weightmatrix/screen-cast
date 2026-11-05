import SwiftUI
import AppKit

@main
struct MacCasterApp: App {
    @NSApplicationDelegateAdaptor(RecordingAppDelegate.self) private var appDelegate
    @StateObject private var streamer = ScreenStreamer()
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
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
                .environment(\.locale, AppLanguage.locale(language))
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
                .environmentObject(streamer)
                .environment(\.locale, AppLanguage.locale(language))
                .focusEffectDisabled()
                .preferredColorScheme(AppAppearance.scheme(appearance))
        }
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var passwordDraft = ""
    @State private var passwordError = false
    @AppStorage("appearance.skin") private var skin = "minimal"
    @AppStorage("appearance.colorScheme") private var appearance = "system"

    var body: some View {
        Form {
            Section("皮肤") {
                Picker("当前皮肤", selection: $skin) {
                    Text("极简皮肤").tag("minimal")
                    Text("3D图标").tag("icons3d")
                }
                if skin == "icons3d" {
                    HStack(spacing: 32) {
                        SkinModeLabel(title: "投屏", symbol: "arrow.up.right.video", artwork: SkinArtwork.cast, iconSize: 80)
                        SkinModeLabel(title: "接收", symbol: "arrow.down.left.video", artwork: SkinArtwork.receive, iconSize: 80)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            Section("外观") {
                Picker("深浅色", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("固定浅色").tag("light")
                    Text("固定深色").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("语言") {
                AppLanguagePicker()
            }
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
        .formStyle(.grouped)
        .font(.system(size: 16))
        .controlSize(.large)
        .frame(width: 520, height: skin == "icons3d" ? 610 : 520)
        .navigationTitle("设置")
    }
}

enum AppAppearance {
    static func scheme(_ value: String) -> ColorScheme? {
        switch value { case "light": return .light; case "dark": return .dark; default: return nil }
    }
}

enum SkinArtwork {
    static let cast = load("Skin3DCast")
    static let receive = load("Skin3DReceive")
    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

struct SkinModeLabel: View {
    let title: String
    let symbol: String
    let artwork: NSImage?
    var iconSize: CGFloat = 52
    var body: some View {
        HStack(spacing: 6) {
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFit().frame(width: iconSize, height: iconSize).accessibilityHidden(true)
            } else {
                Image(systemName: symbol).font(.system(size: 24))
            }
            Text(LocalizedStringKey(title)).font(.system(size: 17, weight: .semibold))
        }
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
    @AppStorage("appearance.skin") private var skin = "minimal"
    @EnvironmentObject private var streamer: ScreenStreamer
    @State private var showAddSheet = false
    @State private var sessionsBeforeAdding = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Group {
            if appMode == "receive" { MacReceiverView() }
            else { ContentView(onAdd: beginAdding) }
            }
        }
        .font(.system(size: 16))
        .buttonStyle(AppGlassButtonStyle())
        .controlSize(.large)
        .tint(CastStyle.accent)
        .sheet(isPresented: $showAddSheet, onDismiss: {
            if streamer.sessions.contains(where: { !sessionsBeforeAdding.contains($0.id) }) { appMode = "cast" }
        }) {
            AddStreamSheet(streamer: streamer, isPresented: $showAddSheet)
                .focusEffectDisabled()
        }
    }

    private var modeBar: some View {
            HStack(spacing: 18) {
                Spacer()
                HStack(spacing: 12) {
                    Button { appMode = "cast" } label: {
                        if skin == "icons3d" {
                            SkinModeLabel(title: "投屏", symbol: "arrow.up.right.video", artwork: SkinArtwork.cast)
                        } else { Label("投屏", systemImage: "arrow.up.right.video") }
                    }
                        .buttonStyle(AppGlassButtonStyle(prominent: appMode == "cast"))
                        .accessibilityAddTraits(appMode == "cast" ? .isSelected : [])
                    Button { appMode = "receive" } label: {
                        if skin == "icons3d" {
                            SkinModeLabel(title: "接收", symbol: "arrow.down.left.video", artwork: SkinArtwork.receive)
                        } else { Label("接收", systemImage: "arrow.down.left.video") }
                    }
                        .buttonStyle(AppGlassButtonStyle(prominent: appMode == "receive"))
                        .accessibilityAddTraits(appMode == "receive" ? .isSelected : [])
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button(action: beginAdding) { Label("添加投屏", systemImage: "plus") }
                    .labelStyle(.iconOnly).buttonStyle(AppGlassButtonStyle()).help("添加投屏")
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(CastStyle.canvas)
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
