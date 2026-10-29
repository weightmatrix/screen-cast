import SwiftUI

@main
struct MacCasterApp: App {
    @StateObject private var streamer = ScreenStreamer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(streamer)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-motion") { await NativeRoutesVerification.motion() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-receive") { await NativeRoutesVerification.receive() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-capture") || ProcessInfo.processInfo.arguments.contains("--verify-native-publish") { await streamer.verifyNativeCapture() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-native-routes") { await NativeRoutesVerification.run() }
                    if ProcessInfo.processInfo.arguments.contains("--verify-display-pacing") {
                        await MacStreamImageView.verifyPacing()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-internet-publish") || ProcessInfo.processInfo.arguments.contains("--verify-internet-casting") || ProcessInfo.processInfo.arguments.contains("--verify-internet-ip") || ProcessInfo.processInfo.arguments.contains("--verify-casting") || ProcessInfo.processInfo.arguments.contains("--verify-live-quality") {
                        await streamer.verifyCasting()
                    }
                    #endif
                }
        }
        .defaultSize(width: 960, height: 740)
    }
}

struct RootView: View {
    @AppStorage("appMode") private var appMode = "cast"

    var body: some View {
        Group {
            if appMode == "receive" { MacReceiverView() }
            else { ContentView() }
        }
        .font(.system(size: 16))
        .buttonStyle(CastButtonStyle())
        .controlSize(.large)
        .tint(CastStyle.accent)
        .preferredColorScheme(.dark)
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
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(40)
        .frame(width: 420, height: 320)
    }
}
